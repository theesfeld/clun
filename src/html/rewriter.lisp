;;;; rewriter.lisp — pure-CL streaming HTML rewriter (Bun HTMLRewriter / lol-html shape).
;;;; Selector matching + element/text/comment/document handlers with mutations.

(in-package :clun.html)

(defconstant +max-source-length+ (* 16 1024 1024))
(defconstant +max-tokens+ 2000000)
(defconstant +max-handlers+ 10000)
(defconstant +max-selector-length+ 4096)

(define-condition html-rewriter-error (error)
  ((code :initarg :code :reader html-rewriter-error-code)
   (reason :initarg :reason :reader html-rewriter-error-reason))
  (:report (lambda (c s)
             (format s "~a" (html-rewriter-error-reason c)))))

(defun %fail (code reason)
  (error 'html-rewriter-error :code code :reason reason))

;;; --- CSS selectors (subset) ------------------------------------------------

(defstruct (sel-simple (:conc-name ss-))
  tag                                   ; string or nil (*)
  id                                    ; string or nil
  classes                               ; list of strings
  attrs                                 ; list of (name op value case-insensitive)
  pseudos)                              ; list of (name arg)

(defstruct (selector (:conc-name sel-))
  parts                                 ; list of (combinator . simple)
  raw)

(defun %ascii-downcase (string)
  (map 'string
       (lambda (c)
         (if (and (char>= c #\A) (char<= c #\Z))
             (code-char (+ (char-code c) 32))
             c))
       string))

(defun %css-ws-p (c)
  (or (char= c #\Space) (char= c #\Tab) (char= c #\Newline)
      (char= c #\Return) (char= c #\Page)))

(defun %parse-ident (s i)
  (let ((start i) (n (length s)))
    (when (and (< i n) (or (alpha-char-p (char s i))
                           (char= (char s i) #\_)
                           (char= (char s i) #\-)))
      (incf i)
      (loop while (and (< i n)
                       (or (alphanumericp (char s i))
                           (char= (char s i) #\_)
                           (char= (char s i) #\-)))
            do (incf i))
      (values (subseq s start i) i))))

(defun %parse-string (s i)
  (let ((q (char s i)) (n (length s)))
    (incf i)
    (let ((start i))
      (loop while (and (< i n) (char/= (char s i) q))
            do (when (char= (char s i) #\\) (incf i))
               (incf i))
      (unless (and (< i n) (char= (char s i) q))
        (%fail :selector "unterminated attribute string"))
      (values (subseq s start i) (1+ i)))))

(defun %skip-ws (s i)
  (loop while (and (< i (length s)) (%css-ws-p (char s i))) do (incf i))
  i)

(defun %parse-simple (s i)
  (let ((n (length s))
        (tag nil)
        (id nil)
        (classes '())
        (attrs '())
        (pseudos '()))
    (setf i (%skip-ws s i))
    (when (>= i n) (return-from %parse-simple (values nil i)))
    (cond
      ((char= (char s i) #\*)
       (setf tag "*") (incf i))
      ((or (alpha-char-p (char s i)) (char= (char s i) #\_))
       (multiple-value-bind (ident j) (%parse-ident s i)
         (setf tag (%ascii-downcase ident) i j))))
    (loop
      (when (>= i n) (return))
      (let ((c (char s i)))
        (cond
          ((char= c #\.)
           (incf i)
           (multiple-value-bind (ident j) (%parse-ident s i)
             (unless ident (%fail :selector "expected class name"))
             (push (%ascii-downcase ident) classes)
             (setf i j)))
          ((char= c #\#)
           (incf i)
           (multiple-value-bind (ident j) (%parse-ident s i)
             (unless ident (%fail :selector "expected id"))
             (setf id ident i j)))
          ((char= c #\[)
           (incf i)
           (setf i (%skip-ws s i))
           (multiple-value-bind (name j) (%parse-ident s i)
             (unless name (%fail :selector "expected attribute name"))
             (setf i (%skip-ws s j))
             (let ((op :has) (val nil) (ci nil))
               (when (and (< i n) (char/= (char s i) #\]))
                 (cond
                   ((char= (char s i) #\=) (setf op :eq) (incf i))
                   ((and (< (1+ i) n) (char= (char s (1+ i)) #\=))
                    (setf op (case (char s i)
                               (#\~ :word) (#\^ :prefix) (#\$ :suffix)
                               (#\* :contains) (#\| :dash)
                               (t (%fail :selector "bad attribute operator"))))
                    (incf i 2))
                   (t (%fail :selector "expected attribute operator")))
                 (setf i (%skip-ws s i))
                 (cond
                   ((and (< i n) (or (char= (char s i) #\") (char= (char s i) #\')))
                    (multiple-value-bind (v j) (%parse-string s i)
                      (setf val v i j)))
                   (t
                    (multiple-value-bind (ident j) (%parse-ident s i)
                      (unless ident (%fail :selector "expected attribute value"))
                      (setf val ident i j))))
                 (setf i (%skip-ws s i))
                 (when (and (< i n) (or (char= (char s i) #\i)
                                        (char= (char s i) #\I)
                                        (char= (char s i) #\s)
                                        (char= (char s i) #\S)))
                   (setf ci (or (char= (char s i) #\i) (char= (char s i) #\I)))
                   (incf i)
                   (setf i (%skip-ws s i))))
               (unless (and (< i n) (char= (char s i) #\]))
                 (%fail :selector "expected ]"))
               (incf i)
               (push (list (%ascii-downcase name) op val ci) attrs))))
          ((char= c #\:)
           (incf i)
           (multiple-value-bind (name j) (%parse-ident s i)
             (unless name (%fail :selector "expected pseudo-class"))
             (setf i j)
             (let ((arg nil))
               (when (and (< i n) (char= (char s i) #\())
                 (incf i)
                 (let ((start i) (depth 1))
                   (loop while (and (< i n) (plusp depth))
                         do (let ((ch (char s i)))
                              (cond ((char= ch #\() (incf depth))
                                    ((char= ch #\)) (decf depth)))
                              (incf i)))
                   (setf arg (%trim (subseq s start (1- i))))))
               (push (list (%ascii-downcase name) arg) pseudos))))
          (t (return)))))
    (values (make-sel-simple :tag tag :id id
                             :classes (nreverse classes)
                             :attrs (nreverse attrs)
                             :pseudos (nreverse pseudos))
            i)))

(defun %trim (s)
  (string-trim '(#\Space #\Tab #\Newline #\Return #\Page) s))

(defun parse-selector (raw)
  (when (> (length raw) +max-selector-length+)
    (%fail :selector "selector too long"))
  (when (zerop (length (%trim raw)))
    (%fail :selector "empty selector"))
  (let ((parts '())
        (i 0)
        (n (length raw))
        (combinator :descendant))
    (loop
      (setf i (%skip-ws raw i))
      (when (>= i n) (return))
      (when (member (char raw i) '(#\> #\+ #\~))
        (setf combinator (case (char raw i)
                           (#\> :child) (#\+ :adjacent) (#\~ :sibling))
              i (1+ i))
        (setf i (%skip-ws raw i)))
      (multiple-value-bind (simple j) (%parse-simple raw i)
        (unless simple
          (if (zerop (length parts))
              (%fail :selector "invalid selector")
              (return)))
        (push (cons combinator simple) parts)
        (setf combinator :descendant
              i j)
        (when (and (< i n) (not (%css-ws-p (char raw i)))
                   (not (member (char raw i) '(#\> #\+ #\~))))
          ;; attached next simple without combinator — treat as descendant
          nil)))
    (when (null parts)
      (%fail :selector "invalid selector"))
    (make-selector :parts (nreverse parts) :raw raw)))

;;; --- element model ---------------------------------------------------------

(defstruct (html-element (:conc-name he-))
  tag
  (attrs (make-hash-table :test 'equal)) ; name -> value
  (self-closing nil)
  (removed nil)
  (keep-content nil)
  (before '())                          ; list of (html-p . text) reverse order
  (after '())
  (prepend '())
  (append '())
  (inner nil)                           ; replacement string or nil
  (inner-html-p nil)
  (end-tag-index nil)
  (start-tag-end nil)                   ; char index after '>' of open tag
  (open-index 0)
  (child-index 0)                       ; nth among siblings of same parent
  (type-index 0)                        ; nth among same-tag siblings
  parent)

(defstruct (html-text (:conc-name ht-))
  text
  (last-in-text-node t)
  (removed nil)
  (replacement nil)
  (before '())
  (after '()))

(defstruct (html-comment (:conc-name hc-))
  text
  (removed nil)
  (replacement nil)
  (before '())
  (after '()))

(defstruct (rewriter-handlers (:conc-name rh-))
  element
  text
  comments)

(defstruct (document-handlers (:conc-name dh-))
  doctype
  comments
  text
  end)

(defstruct (html-rewriter (:conc-name hr-))
  (element-handlers '())                ; list of (selector . rewriter-handlers)
  (document-handlers nil)
  (token-count 0))

(defun make-empty-rewriter ()
  (make-html-rewriter))

(defun rewriter-on (rewriter selector-string handlers-plist)
  (when (>= (length (hr-element-handlers rewriter)) +max-handlers+)
    (%fail :handlers "handler limit exceeded"))
  (let ((sel (parse-selector selector-string))
        (h (make-rewriter-handlers
            :element (getf handlers-plist :element)
            :text (getf handlers-plist :text)
            :comments (getf handlers-plist :comments))))
    (setf (hr-element-handlers rewriter)
          (append (hr-element-handlers rewriter) (list (cons sel h))))
    rewriter))

(defun rewriter-on-document (rewriter handlers-plist)
  (setf (hr-document-handlers rewriter)
        (make-document-handlers
         :doctype (getf handlers-plist :doctype)
         :comments (getf handlers-plist :comments)
         :text (getf handlers-plist :text)
         :end (getf handlers-plist :end)))
  rewriter)

;;; --- matching --------------------------------------------------------------

(defun %attr-get (el name)
  (gethash (%ascii-downcase name) (he-attrs el)))

(defun %class-list (el)
  (let ((c (%attr-get el "class")))
    (if c
        (mapcar #'%ascii-downcase
                (remove "" (split-on-ws c) :test #'string=))
        '())))

(defun split-on-ws (s)
  (let ((parts '()) (start nil))
    (loop for i from 0 below (length s)
          for c = (char s i)
          do (if (%css-ws-p c)
                 (when start
                   (push (subseq s start i) parts)
                   (setf start nil))
                 (unless start (setf start i))))
    (when start (push (subseq s start) parts))
    (nreverse parts)))

(defun %attr-match (el name op value ci)
  (let ((actual (%attr-get el name)))
    (ecase op
      (:has (not (null actual)))
      (:eq (and actual
                (if ci
                    (string-equal actual value)
                    (string= actual value))))
      (:prefix (and actual
                    (>= (length actual) (length value))
                    (if ci
                        (string-equal actual value :end1 (length value))
                        (string= actual value :end1 (length value)))))
      (:suffix (and actual
                    (>= (length actual) (length value))
                    (if ci
                        (string-equal actual value
                                      :start1 (- (length actual) (length value)))
                        (string= actual value
                                 :start1 (- (length actual) (length value))))))
      (:contains (and actual
                      (if ci
                          (search (string-downcase value)
                                  (string-downcase actual))
                          (search value actual))))
      (:word (and actual
                  (member value (split-on-ws actual)
                          :test (if ci #'string-equal #'string=))))
      (:dash (and actual
                  (or (if ci (string-equal actual value) (string= actual value))
                      (and (> (length actual) (length value))
                           (char= (char actual (length value)) #\-)
                           (if ci
                               (string-equal actual value :end1 (length value))
                               (string= actual value :end1 (length value))))))))))

(defun %simple-match (simple el)
  (let ((tag (ss-tag simple)))
    (when (and tag (not (string= tag "*"))
               (not (string= tag (he-tag el))))
      (return-from %simple-match nil))
    (when (ss-id simple)
      (let ((id (%attr-get el "id")))
        (unless (and id (string= id (ss-id simple)))
          (return-from %simple-match nil))))
    (when (ss-classes simple)
      (let ((have (%class-list el)))
        (unless (every (lambda (c) (member c have :test #'string=))
                       (ss-classes simple))
          (return-from %simple-match nil))))
    (dolist (a (ss-attrs simple))
      (destructuring-bind (name op val ci) a
        (unless (%attr-match el name op val ci)
          (return-from %simple-match nil))))
    (dolist (p (ss-pseudos simple))
      (destructuring-bind (name arg) p
        (cond
          ((string= name "first-child")
           (unless (= (he-child-index el) 0)
             (return-from %simple-match nil)))
          ((string= name "first-of-type")
           (unless (= (he-type-index el) 0)
             (return-from %simple-match nil)))
          ((string= name "nth-child")
           (let ((n (ignore-errors (parse-integer (or arg "") :junk-allowed t))))
             (unless (and n (= (1+ (he-child-index el)) n))
               (return-from %simple-match nil))))
          ((string= name "nth-of-type")
           (let ((n (ignore-errors (parse-integer (or arg "") :junk-allowed t))))
             (unless (and n (= (1+ (he-type-index el)) n))
               (return-from %simple-match nil))))
          ((string= name "not")
           ;; limited: only simple :not(tag) / :not(.class) etc.
           (when arg
             (handler-case
                 (let ((sel (parse-selector arg)))
                   (when (and (= (length (sel-parts sel)) 1)
                              (%simple-match (cdr (first (sel-parts sel))) el))
                     (return-from %simple-match nil)))
               (html-rewriter-error ()))))
          (t nil))))
    t))

(defun %selector-match (selector el ancestors)
  "ANCESTORS is list of parent elements from nearest to root."
  (let ((parts (reverse (sel-parts selector)))
        (current el)
        (anc ancestors))
    ;; last part must match current
    (let ((last (car parts)))
      (unless (%simple-match (cdr last) current)
        (return-from %selector-match nil)))
    (dolist (part (cdr parts))
      (let ((comb (car part))
            (simple (cdr part)))
        (ecase comb
          (:descendant
           (let ((found nil))
             (dolist (a anc)
               (when (%simple-match simple a)
                 (setf current a
                       anc (cdr (member a anc :test #'eq))
                       found t)
                 (return)))
             (unless found (return-from %selector-match nil))))
          (:child
           (let ((parent (car anc)))
             (unless (and parent (%simple-match simple parent))
               (return-from %selector-match nil))
             (setf current parent
                   anc (cdr anc))))
          ((:adjacent :sibling)
           ;; sibling combinators need previous-sibling chain; treat as fail-soft
           (return-from %selector-match nil)))))
    t))

;;; --- tokenizer / transform -------------------------------------------------

(defun %void-tag-p (tag)
  (member tag '("area" "base" "br" "col" "embed" "hr" "img" "input"
                "link" "meta" "param" "source" "track" "wbr")
          :test #'string=))

(defun %parse-attrs (s)
  (let ((attrs (make-hash-table :test 'equal))
        (i 0)
        (n (length s)))
    (loop
      (setf i (%skip-ws s i))
      (when (>= i n) (return))
      (when (char= (char s i) #\/) (return))
      (multiple-value-bind (name j) (%parse-ident s i)
        (unless name (return))
        (setf i (%skip-ws s j))
        (let ((value ""))
          (when (and (< i n) (char= (char s i) #\=))
            (incf i)
            (setf i (%skip-ws s i))
            (cond
              ((and (< i n) (or (char= (char s i) #\") (char= (char s i) #\')))
               (multiple-value-bind (v k) (%parse-string s i)
                 (setf value v i k)))
              (t
               (let ((start i))
                 (loop while (and (< i n)
                                  (not (%css-ws-p (char s i)))
                                  (char/= (char s i) #\>))
                       do (incf i))
                 (setf value (subseq s start i))))))
          (setf (gethash (%ascii-downcase name) attrs) value))))
    attrs))

(defun %escape-attr (v)
  (with-output-to-string (o)
    (loop for c across v
          do (case c
               (#\& (write-string "&amp;" o))
               (#\" (write-string "&quot;" o))
               (#\< (write-string "&lt;" o))
               (t (write-char c o))))))

(defun %emit-open-tag (el)
  (with-output-to-string (o)
    (write-char #\< o)
    (write-string (he-tag el) o)
    (maphash (lambda (k v)
               (write-char #\Space o)
               (write-string k o)
               (write-string "=\"" o)
               (write-string (%escape-attr v) o)
               (write-char #\" o))
             (he-attrs el))
    (when (he-self-closing el)
      (write-string " /" o))
    (write-char #\> o)))

(defun %emit-close-tag (tag)
  (format nil "</~a>" tag))

(defun %pieces-to-string (pieces)
  "PIECES is list of (html-p . text) in reverse insertion order for before/after."
  (with-output-to-string (o)
    (dolist (p (reverse pieces))
      (destructuring-bind (html-p . text) p
        (if html-p
            (write-string text o)
            (write-string (escape-text text) o))))))

(defun escape-text (text)
  (with-output-to-string (o)
    (loop for c across text
          do (case c
               (#\& (write-string "&amp;" o))
               (#\< (write-string "&lt;" o))
               (#\> (write-string "&gt;" o))
               (t (write-char c o))))))

(defun %call-handler (fn arg)
  (when fn (funcall fn arg)))

(defun transform-html (rewriter source)
  (when (> (length source) +max-source-length+)
    (%fail :source-limit "HTML source exceeds size limit"))
  (let ((out (make-array (max 16 (length source))
                         :element-type 'character
                         :adjustable t :fill-pointer 0)))
    (transform-html-pass rewriter source out)
    (coerce out 'string)))

(defun transform-html-pass (rewriter source out)
  (let ((i 0)
        (n (length source))
        (stack '())
        (child-counters (list 0))
        (type-counters (list (make-hash-table :test 'equal)))
        (token-count 0)
        (doc (hr-document-handlers rewriter)))
    (labels
        ((emit (s)
           (loop for c across s do (vector-push-extend c out)))
         (bump ()
           (incf token-count)
           (when (> token-count +max-tokens+)
             (%fail :token-limit "HTML token limit exceeded"))
           (setf (hr-token-count rewriter) token-count))
         (ancestors ()
           (mapcar #'car stack))
         (active-text-handlers ()
           (loop for (el . hs) in stack
                 append (loop for h in hs
                              when (rh-text h) collect (rh-text h))))
         (active-comment-handlers ()
           (append
            (loop for (el . hs) in stack
                  append (loop for h in hs
                               when (rh-comments h) collect (rh-comments h)))
            (when (and doc (dh-comments doc))
              (list (dh-comments doc)))))
         (match-handlers (el)
           (let ((matched '()))
             (dolist (pair (hr-element-handlers rewriter))
               (when (%selector-match (car pair) el (ancestors))
                 (push (cdr pair) matched)))
             (nreverse matched)))
         (push-el (el handlers)
           (push (cons el handlers) stack)
           (push 0 child-counters)
           (push (make-hash-table :test 'equal) type-counters))
         (pop-el ()
           (pop child-counters)
           (pop type-counters)
           (pop stack))
         (handle-text (text lastp)
           (bump)
           (let ((node (make-html-text :text text :last-in-text-node lastp)))
             (dolist (fn (active-text-handlers))
               (%call-handler fn node))
             (when (and doc (dh-text doc))
               (%call-handler (dh-text doc) node))
             (unless (ht-removed node)
               (emit (%pieces-to-string (ht-before node)))
               (emit (or (ht-replacement node) (escape-text (ht-text node))))
               (emit (%pieces-to-string (ht-after node))))))
         (handle-comment (text)
           (bump)
           (let ((node (make-html-comment :text text)))
             (dolist (fn (active-comment-handlers))
               (%call-handler fn node))
             (unless (hc-removed node)
               (emit (%pieces-to-string (hc-before node)))
               (emit (or (hc-replacement node)
                         (format nil "<!--~a-->" (hc-text node))))
               (emit (%pieces-to-string (hc-after node))))))
         (close-current (tag)
           (loop while stack
                 for (el . hs) = (car stack)
                 do (let ((tag-match (string= (he-tag el) tag)))
                      (unless (he-removed el)
                        (emit (%pieces-to-string (he-append el)))
                        (unless (or (he-keep-content el) (he-self-closing el))
                          (emit (%emit-close-tag (he-tag el))))
                        (emit (%pieces-to-string (he-after el))))
                      (pop-el)
                      (when tag-match (return)))))
         (skip-element-content (tag)
           (let ((depth 1))
             (loop while (and (< i n) (plusp depth)) do
               (let ((c (char source i)))
                 (cond
                   ((char/= c #\<)
                    (incf i))
                   ((and (< (+ i 1) n) (char= (char source (1+ i)) #\/))
                    (let ((j (+ i 2))
                          (start (+ i 2)))
                      (loop while (and (< j n)
                                       (or (alphanumericp (char source j))
                                           (char= (char source j) #\-)))
                            do (incf j))
                      (let ((ct (%ascii-downcase (subseq source start j))))
                        (loop while (and (< j n) (char/= (char source j) #\>))
                              do (incf j))
                        (when (< j n) (incf j))
                        (setf i j)
                        (when (string= ct tag) (decf depth)))))
                   ((and (< (+ i 3) n)
                         (string= source "<!--" :start1 i :end1 (+ i 4)))
                    (let ((end (search "-->" source :start2 i)))
                      (setf i (if end (+ end 3) n))))
                   (t
                    (let ((j (1+ i))
                          (start (1+ i))
                          (self nil))
                      (loop while (and (< j n)
                                       (or (alphanumericp (char source j))
                                           (char= (char source j) #\-)))
                            do (incf j))
                      (let ((ot (%ascii-downcase (subseq source start j))))
                        (loop while (and (< j n) (char/= (char source j) #\>))
                              do (when (char= (char source j) #\/)
                                   (setf self t))
                                 (incf j))
                        (when (< j n) (incf j))
                        (setf i j)
                        (unless (or self (%void-tag-p ot) (string= ot ""))
                          (when (string= ot tag) (incf depth)))))))))))
         (open-tag (tag attrs self-closing)
           (bump)
           (let* ((el (make-html-element :tag tag :attrs attrs
                                         :self-closing self-closing))
                  (parent (car (ancestors)))
                  (ci (car child-counters))
                  (tc (car type-counters))
                  (ti (gethash tag tc 0))
                  (handlers nil))
             (setf (he-parent el) parent
                   (he-child-index el) ci
                   (he-type-index el) ti)
             (setf (car child-counters) (1+ ci)
                   (gethash tag tc) (1+ ti))
             (setf handlers (match-handlers el))
             (dolist (h handlers)
               (%call-handler (rh-element h) el))
             (cond
               ((he-removed el)
                (emit (%pieces-to-string (he-before el)))
                (when (and (he-keep-content el)
                           (not self-closing)
                           (not (%void-tag-p tag)))
                  (push-el el handlers))
                (unless (he-keep-content el)
                  (when (and (not self-closing) (not (%void-tag-p tag)))
                    (skip-element-content tag)))
                (emit (%pieces-to-string (he-after el))))
               (t
                (emit (%pieces-to-string (he-before el)))
                (emit (%emit-open-tag el))
                (emit (%pieces-to-string (he-prepend el)))
                (cond
                  ((he-inner el)
                   (if (he-inner-html-p el)
                       (emit (he-inner el))
                       (emit (escape-text (he-inner el))))
                   (when (and (not self-closing) (not (%void-tag-p tag)))
                     (skip-element-content tag)
                     (emit (%pieces-to-string (he-append el)))
                     (emit (%emit-close-tag tag))
                     (emit (%pieces-to-string (he-after el)))))
                  ((or self-closing (%void-tag-p tag))
                   (emit (%pieces-to-string (he-append el)))
                   (emit (%pieces-to-string (he-after el))))
                  (t
                   (push-el el handlers))))))))
      ;; main scan
      (loop while (< i n) do
        (let ((c (char source i)))
          (if (char/= c #\<)
              (let ((start i))
                (loop while (and (< i n) (char/= (char source i) #\<))
                      do (incf i))
                (handle-text (subseq source start i) t))
              (cond
                ((and (< (+ i 3) n)
                      (string= source "<!--" :start1 i :end1 (+ i 4)))
                 (let* ((start (+ i 4))
                        (end (or (search "-->" source :start2 start) n))
                        (text (subseq source start end)))
                   (setf i (if (< end n) (+ end 3) n))
                   (handle-comment text)))
                ((and (< (+ i 8) n)
                      (string-equal source "<!doctype" :start1 i :end1 (+ i 9)))
                 (let ((end (or (position #\> source :start i) (1- n))))
                   (let ((text (subseq source i (1+ end))))
                     (setf i (1+ end))
                     (bump)
                     (when (and doc (dh-doctype doc))
                       (%call-handler (dh-doctype doc) text))
                     (emit text))))
                ((and (< (1+ i) n) (char= (char source (1+ i)) #\/))
                 (let ((j (+ i 2))
                       (start (+ i 2)))
                   (loop while (and (< j n)
                                    (or (alphanumericp (char source j))
                                        (char= (char source j) #\-)))
                         do (incf j))
                   (let ((tag (%ascii-downcase (subseq source start j))))
                     (loop while (and (< j n) (char/= (char source j) #\>))
                           do (incf j))
                     (when (< j n) (incf j))
                     (setf i j)
                     (close-current tag))))
                (t
                 (let ((j (1+ i))
                       (start (1+ i)))
                   (loop while (and (< j n)
                                    (or (alphanumericp (char source j))
                                        (char= (char source j) #\-)))
                         do (incf j))
                   (if (= j start)
                       (progn (emit "<") (incf i))
                       (let ((tag (%ascii-downcase (subseq source start j)))
                             (attr-start j)
                             (self nil)
                             (gt j))
                         (loop while (and (< gt n) (char/= (char source gt) #\>))
                               do (incf gt))
                         ;; Only a solidus immediately before '>' is self-closing.
                         (when (and (> gt attr-start)
                                    (char= (char source (1- gt)) #\/))
                           (setf self t))
                         (let ((attrs (%parse-attrs
                                       (subseq source attr-start
                                               (if self (1- gt) gt)))))
                           (setf j (if (< gt n) (1+ gt) gt)
                                 i j)
                           (open-tag tag attrs self))))))))))
      (loop while stack do
        (close-current (he-tag (car (car stack)))))
      (when (and doc (dh-end doc))
        (%call-handler (dh-end doc) nil))
      out)))

(defun element-tag-name (el)
  (he-tag el))

(defun element-set-tag-name (el name)
  (setf (he-tag el) (%ascii-downcase name)))

(defun element-get-attribute (el name)
  (%attr-get el name))

(defun element-has-attribute (el name)
  (nth-value 1 (gethash (%ascii-downcase name) (he-attrs el))))

(defun element-set-attribute (el name value)
  (setf (gethash (%ascii-downcase name) (he-attrs el)) value)
  el)

(defun element-remove-attribute (el name)
  (remhash (%ascii-downcase name) (he-attrs el))
  el)

(defun element-before (el content &key html)
  (push (cons html content) (he-before el))
  el)

(defun element-after (el content &key html)
  (push (cons html content) (he-after el))
  el)

(defun element-prepend (el content &key html)
  (push (cons html content) (he-prepend el))
  el)

(defun element-append (el content &key html)
  (push (cons html content) (he-append el))
  el)

(defun element-set-inner-content (el content &key html)
  (setf (he-inner el) content
        (he-inner-html-p el) html)
  el)

(defun element-remove (el)
  (setf (he-removed el) t
        (he-keep-content el) nil)
  el)

(defun element-remove-and-keep-content (el)
  (setf (he-removed el) t
        (he-keep-content el) t)
  el)

(defun text-replace (node content &key html)
  (setf (ht-replacement node)
        (if html content (escape-text content)))
  node)

(defun text-remove (node)
  (setf (ht-removed node) t)
  node)

(defun comment-replace (node content &key html)
  (setf (hc-replacement node)
        (if html content (escape-text content)))
  node)

(defun comment-remove (node)
  (setf (hc-removed node) t)
  node)
