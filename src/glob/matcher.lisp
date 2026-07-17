;;;; matcher.lisp -- immutable, engine-free Phase 30 Glob compiler and matcher.

(in-package :clun.glob)

(defconstant +slash+ #x2f)
(defconstant +max-active-braces+ 10)
(defconstant +max-branch-transitions+ 10000)

(defstruct (instruction (:constructor %instruction (op &optional value x y)))
  (op :fail :type keyword :read-only t)
  value
  x
  y)

(defstruct (character-class
            (:constructor %character-class (negated-p singles ranges)))
  (negated-p nil :type boolean :read-only t)
  (singles #() :type simple-vector :read-only t)
  (ranges #() :type simple-vector :read-only t))

(defstruct (pattern-node (:constructor %pattern-node (kind &optional value)))
  (kind :fail :type keyword :read-only t)
  value)

(defstruct (compiled-glob
            (:constructor %compiled-glob (source program start negated-p)))
  (source "" :read-only t)
  (program #() :type simple-vector :read-only t)
  (start 0 :type fixnum :read-only t)
  (negated-p nil :type boolean :read-only t))

(defun %high-surrogate-p (value)
  (<= #xd800 value #xdbff))

(defun %low-surrogate-p (value)
  (<= #xdc00 value #xdfff))

(defun %input-units (value)
  (cond
    ((stringp value)
     (let ((units (make-array (length value) :element-type 'integer)))
       (dotimes (index (length value) units)
         (setf (aref units index) (char-code (char value index))))))
    ((and (vectorp value)
          (loop for unit across value always (integerp unit)))
     (let ((units (make-array (length value) :element-type 'integer)))
       (replace units value)
       units))
    (t
     (error 'type-error :datum value :expected-type '(or string vector)))))

(defun %decode-scalars (value)
  ;; Clun stores JS strings as UTF-16 code units. Pair only valid adjacent
  ;; surrogates; every lone surrogate remains one deterministic matcher value.
  (let* ((units (%input-units value))
         (result (make-array (length units)
                             :element-type 'integer
                             :adjustable t
                             :fill-pointer 0))
         (index 0))
    (loop while (< index (length units))
          for first = (aref units index)
          do (if (and (%high-surrogate-p first)
                      (< (1+ index) (length units))
                      (%low-surrogate-p (aref units (1+ index))))
                 (progn
                   (vector-push-extend
                    (+ #x10000
                       (ash (- first #xd800) 10)
                       (- (aref units (1+ index)) #xdc00))
                    result)
                   (incf index 2))
                 (progn
                   (vector-push-extend first result)
                   (incf index))))
    (coerce result 'simple-vector)))

(defun %escape-value (value)
  (case value
    (#x61 #x61)                         ; \a is Bun's literal a
    (#x62 #x08)
    (#x6e #x0a)
    (#x72 #x0d)
    (#x74 #x09)
    (otherwise value)))

(defun %class-close (pattern open end)
  (let ((index (1+ open))
        (first-p t))
    (when (and (< index end)
               (member (aref pattern index) '(#x21 #x5e)))
      (incf index))
    (loop while (< index end)
          for value = (aref pattern index)
          do (cond
               ((= value #x5c)
                (if (< (1+ index) end)
                    (progn
                      (setf first-p nil)
                      (incf index 2))
                    (return nil)))
               ((and (= value #x5d) (not first-p))
                (return index))
               (t
                (setf first-p nil)
                (incf index))))))

(defun %brace-class-close (pattern open end)
  "Locate the scanner-level end of a class while discovering brace branches.

This deliberately differs from `%class-close`: Bun's brace scanner uses the
first unescaped `]` to leave bracket state, while the matcher later treats an
initial `]` as a class member.  Keeping the scanners distinct preserves suffix
validation and the engineering comma-in-class correction at the same time."
  (let ((index (1+ open)))
    (loop while (< index end)
          for value = (aref pattern index)
          do (cond
               ((= value #x5c)
                (if (< (1+ index) end)
                    (incf index 2)
                    (return nil)))
               ((= value #x5d)
                (return index))
               (t
                (incf index))))))

(defun %parse-character-class (pattern open end)
  (let ((close (%class-close pattern open end)))
    (unless close
      (return-from %parse-character-class (values nil end nil)))
    (let ((index (1+ open))
          (negated-p nil)
          (items (make-array 8 :adjustable t :fill-pointer 0)))
      (when (and (< index close)
                 (member (aref pattern index) '(#x21 #x5e)))
        (setf negated-p t)
        (incf index))
      (loop while (< index close)
            for value = (aref pattern index)
            do (if (= value #x5c)
                   (progn
                     (incf index)
                     (when (>= index close)
                       (return-from %parse-character-class
                         (values nil (1+ close) nil)))
                     (vector-push-extend
                      (cons (%escape-value (aref pattern index)) t) items)
                     (incf index))
                   (progn
                     (vector-push-extend (cons value nil) items)
                     (incf index))))
      (let ((singles (make-array (length items)
                                 :adjustable t :fill-pointer 0))
            (ranges (make-array (length items)
                                :adjustable t :fill-pointer 0))
            (item-index 0))
        (loop while (< item-index (length items))
              do (if (and (< (+ item-index 2) (length items))
                          (= (car (aref items (1+ item-index))) #x2d)
                          (not (cdr (aref items (1+ item-index)))))
                     (progn
                       (vector-push-extend
                        (cons (car (aref items item-index))
                              (car (aref items (+ item-index 2))))
                        ranges)
                       (incf item-index 3))
                     (progn
                       (vector-push-extend (car (aref items item-index)) singles)
                       (incf item-index))))
        (values (%pattern-node
                 :class
                 (%character-class negated-p
                                   (coerce singles 'simple-vector)
                                   (coerce ranges 'simple-vector)))
                (1+ close)
                t)))))

(defun %brace-layout (pattern open end)
  ;; This scanner deliberately uses an unbounded integer nesting counter. It
  ;; locates branch boundaries without recursively parsing skipped brace text.
  (let ((index (1+ open))
        (depth 0)
        (commas '()))
    (loop while (< index end)
          for value = (aref pattern index)
          do (cond
               ((= value #x5c)
                (if (< (1+ index) end)
                    (incf index 2)
                    (setf index end)))
               ((= value #x5b)
                (let ((close (%brace-class-close pattern index end)))
                  (if close
                      (setf index (1+ close))
                      (setf index end))))
               ((= value #x7b)
                (incf depth)
                (incf index))
               ((= value #x7d)
                (if (zerop depth)
                    (return (values index (nreverse commas)))
                    (progn (decf depth) (incf index))))
               ((and (= value #x2c) (zerop depth))
                (push index commas)
                (incf index))
               (t
                (incf index)))
          finally (return (values nil (nreverse commas))))))

(defun %invalid-branch ()
  (list (%pattern-node :fail)))

(defun %leading-negated-repeated-globstar-p (pattern index run-end)
  "Return true for the first ** in a raw leading !**/** sequence.

Bun does not generally let removal of leading whole-pattern negation create a
globstar boundary: !** remains a segment wildcard.  It does, however, collapse
adjacent complete ** components, so the first component in !**/** is a globstar.
Keep that measured exception narrow and based on the unmodified source text."
  (and (plusp index)
       (loop for prefix-index below index
             always (= (aref pattern prefix-index) #x21))
       (< run-end (length pattern))
       (= (aref pattern run-end) +slash+)
       (< (+ run-end 2) (length pattern))
       (= (aref pattern (1+ run-end)) #x2a)
       (= (aref pattern (+ run-end 2)) #x2a)
       (or (= (+ run-end 3) (length pattern))
           (= (aref pattern (+ run-end 3)) +slash+))))

(defun %brace-branch-start-p (pattern start index)
  "Return true when INDEX is the start of a recursively parsed brace branch.

Branch starts are left globstar boundaries in Bun.  The top-level parse after
leading whole-pattern negation is deliberately excluded: removing `!` does not
normally create a boundary."
  (and (= index start)
       (plusp index)
       (not (loop for prefix-index below index
                  always (= (aref pattern prefix-index) #x21)))))

(defun %parse-sequence (pattern start end depth)
  (let ((nodes '())
        (index start)
        (valid-p t))
    (loop while (< index end)
          for value = (aref pattern index)
          do (case value
               (#x5c
                (if (< (1+ index) end)
                    (progn
                      (push (%pattern-node
                             :literal
                             (%escape-value (aref pattern (1+ index))))
                            nodes)
                      (incf index 2))
                    (progn
                      (setf valid-p nil)
                      (push (%pattern-node :fail) nodes)
                      (setf index end))))
               (#x3f
                (push (%pattern-node :any) nodes)
                (incf index))
               (#x2a
                (let ((run-end index))
                  (loop while (and (< run-end end)
                                   (= (aref pattern run-end) #x2a))
                        do (incf run-end))
                  (let* ((run-length (- run-end index))
                         ;; Component globstar classification is based on the
                         ;; original pattern, not the recursive parse slice.
                         ;; A brace delimiter or stripped leading negation is
                         ;; therefore not a path-component boundary.
                         (left-boundary-p
                           (or (zerop index)
                               (= (aref pattern (1- index)) +slash+)
                               (%brace-branch-start-p pattern start index)))
                         (right-boundary-p
                           (or (= run-end (length pattern))
                               (= (aref pattern run-end) +slash+)))
                         (globstar-p
                           (and (= run-length 2)
                                (or left-boundary-p
                                    (%leading-negated-repeated-globstar-p
                                     pattern index run-end))
                                right-boundary-p)))
                    (cond
                      ((and globstar-p (< run-end end))
                       (push (%pattern-node :globstar-slash) nodes)
                       (setf index (1+ run-end)))
                      (globstar-p
                       (push (%pattern-node :star-any) nodes)
                       (setf index run-end))
                      (t
                       ;; Adjacent segment stars are language-equivalent, so a
                       ;; 100,000-star adversary compiles to one bounded state.
                       ;; Stable Bun requires the final single-star component
                       ;; in a direct **/* sequence to consume at least one
                       ;; character.  Brace-local stars and longer star runs
                       ;; retain ordinary zero-length segment-star behavior.
                       (push (%pattern-node
                              (if (and (= run-length 1)
                                       (= run-end (length pattern))
                                       nodes
                                       (eq (pattern-node-kind (car nodes))
                                           :globstar-slash))
                                  :star-segment-nonempty
                                  :star-segment))
                             nodes)
                       (setf index run-end))))))
               (#x5b
                (multiple-value-bind (node next ok-p)
                    (%parse-character-class pattern index end)
                  (if ok-p
                      (push node nodes)
                      (progn
                        (setf valid-p nil)
                        (push (%pattern-node :fail) nodes)))
                  (setf index next)))
               (#x7b
                (multiple-value-bind (close commas)
                    (%brace-layout pattern index end)
                  (cond
                    ((>= depth +max-active-braces+)
                     (push (%pattern-node :fail) nodes)
                     (setf index (if close (1+ close) end)))
                    (close
                     (let ((branches '())
                           (branch-start (1+ index)))
                       (dolist (boundary (append commas (list close)))
                         (multiple-value-bind (branch branch-valid-p)
                             (%parse-sequence pattern branch-start boundary (1+ depth))
                           (push (if branch-valid-p branch (%invalid-branch)) branches))
                         (setf branch-start (1+ boundary)))
                       (push (%pattern-node :brace (nreverse branches)) nodes)
                       (setf index (1+ close))))
                    (commas
                     ;; Every comma completes a branch. Stable Bun retains all
                     ;; such branches and ignores only the unfinished tail.
                     (let ((branches '())
                           (branch-start (1+ index)))
                       (dolist (boundary commas)
                         (multiple-value-bind (branch branch-valid-p)
                             (%parse-sequence pattern branch-start boundary (1+ depth))
                           (push (if branch-valid-p branch (%invalid-branch))
                                 branches))
                         (setf branch-start (1+ boundary)))
                       (push (%pattern-node :brace (nreverse branches)) nodes))
                     (setf index end))
                    (t
                     (setf valid-p nil)
                     (push (%pattern-node :fail) nodes)
                     (setf index end)))))
               (otherwise
                (push (%pattern-node :literal value) nodes)
                (incf index))))
    (values (nreverse nodes) valid-p)))

(defun %emit (builder op &optional value x y)
  (prog1 (length builder)
    (vector-push-extend (%instruction op value x y) builder)))

(defun %compile-alternatives (branches next builder)
  (let ((starts '()))
    (dolist (branch branches)
      (let ((branch-start (%compile-sequence branch next builder)))
        (push (%emit builder :branch nil branch-start) starts)))
    (setf starts (nreverse starts))
    (let ((start (car (last starts))))
      (dolist (choice (reverse (butlast starts)) start)
        (setf start (%emit builder :split nil choice start))))))

(defun %compile-sequence (nodes next builder)
  (dolist (node (reverse nodes) next)
    (setf next
          (case (pattern-node-kind node)
            (:literal (%emit builder :literal (pattern-node-value node) next))
            (:any (%emit builder :any nil next))
            (:star-segment (%emit builder :star-segment nil next))
            (:star-segment-nonempty
             (let ((star (%emit builder :star-segment nil next)))
               (%emit builder :any nil star)))
            (:star-any (%emit builder :star-any nil next))
            (:globstar-slash
             (let* ((slash (%emit builder :literal +slash+ next))
                    (star (%emit builder :star-any nil slash)))
               (%emit builder :split nil next star)))
            (:class (%emit builder :class (pattern-node-value node) next))
            (:brace (%compile-alternatives (pattern-node-value node) next builder))
            (otherwise (%emit builder :fail))))))

(defun compile-glob (pattern)
  "Compile PATTERN into an immutable engine-free matcher program.

PATTERN is either a Common Lisp string or a vector of UTF-16 code units."
  (let* ((scalars (%decode-scalars pattern))
         (start 0)
         (negated-p nil))
    (loop while (and (< start (length scalars))
                     (= (aref scalars start) #x21))
          do (setf negated-p (not negated-p))
             (incf start))
    (multiple-value-bind (nodes valid-p)
        (%parse-sequence scalars start (length scalars) 0)
      (let* ((builder (make-array (max 16 (1+ (length scalars)))
                                  :adjustable t :fill-pointer 0))
             (accept (%emit builder :accept))
             (program-start (if valid-p
                                (%compile-sequence nodes accept builder)
                                (%emit builder :fail))))
        (%compiled-glob (copy-seq pattern)
                        (coerce builder 'simple-vector)
                        program-start negated-p)))))

(defun %class-match-p (class value)
  (let ((member-p
          (or (loop for single across (character-class-singles class)
                    thereis (= single value))
              (loop for range across (character-class-ranges class)
                    thereis (<= (car range) value (cdr range))))))
    (if (character-class-negated-p class) (not member-p) member-p)))

(defun %push-state (queue state)
  (vector-push-extend state queue))

(defun %epsilon-closure (program seeds active queue marks generation branch-count)
  (setf (fill-pointer active) 0
        (fill-pointer queue) 0)
  (loop for state across seeds do (%push-state queue state))
  (loop with head = 0
        while (< head (length queue))
        for state = (aref queue head)
        do (incf head)
           (unless (= (aref marks state) generation)
             (setf (aref marks state) generation)
             (let ((instruction (aref program state)))
               (case (instruction-op instruction)
                 (:split
                  (%push-state queue (instruction-x instruction))
                  (%push-state queue (instruction-y instruction)))
                 (:branch
                  (when (< branch-count +max-branch-transitions+)
                    (incf branch-count)
                    (%push-state queue (instruction-x instruction))))
                 ((:star-segment :star-any)
                  (vector-push-extend state active)
                  (%push-state queue (instruction-x instruction)))
                 ((:literal :any :class :accept)
                  (vector-push-extend state active))
                 (:jump
                  (%push-state queue (instruction-x instruction)))
                 (:fail nil)))))
  (values active branch-count))

(defun %base-match-p (compiled candidate)
  (let* ((program (compiled-glob-program compiled))
         (program-length (length program))
         (candidate (%decode-scalars candidate))
         (seeds (make-array 16 :element-type 'fixnum
                              :adjustable t :fill-pointer 0))
         (current (make-array 16 :element-type 'fixnum
                                :adjustable t :fill-pointer 0))
         (next (make-array 16 :element-type 'fixnum
                             :adjustable t :fill-pointer 0))
         (queue (make-array 16 :element-type 'fixnum
                              :adjustable t :fill-pointer 0))
         (marks (make-array program-length :element-type '(unsigned-byte 32)
                                           :initial-element 0))
         (generation 1)
         (branch-count 0))
    (vector-push-extend (compiled-glob-start compiled) seeds)
    (multiple-value-setq (current branch-count)
      (%epsilon-closure program seeds current queue marks generation branch-count))
    (loop for value across candidate
          do (setf (fill-pointer seeds) 0)
             (loop for state across current
                   for instruction = (aref program state)
                   do (case (instruction-op instruction)
                        (:literal
                         (when (= value (instruction-value instruction))
                           (vector-push-extend (instruction-x instruction) seeds)))
                        (:any
                         (unless (= value +slash+)
                           (vector-push-extend (instruction-x instruction) seeds)))
                        (:class
                         (when (%class-match-p (instruction-value instruction) value)
                           (vector-push-extend (instruction-x instruction) seeds)))
                        (:star-segment
                         (unless (= value +slash+)
                           (vector-push-extend state seeds)))
                        (:star-any
                         (vector-push-extend state seeds))))
             (when (zerop (length seeds))
               (return-from %base-match-p nil))
             (incf generation)
             (when (zerop generation)
               (fill marks 0)
               (setf generation 1))
             (multiple-value-setq (next branch-count)
               (%epsilon-closure program seeds next queue marks generation branch-count))
             (rotatef current next))
    (loop for state across current
          thereis (eq (instruction-op (aref program state)) :accept))))

(defun glob-match-p (glob candidate)
  "Return whether CANDIDATE is matched by compiled GLOB or a pattern value."
  (let* ((compiled (if (compiled-glob-p glob) glob (compile-glob glob)))
         (matched-p (%base-match-p compiled candidate)))
    (if (compiled-glob-negated-p compiled) (not matched-p) matched-p)))
