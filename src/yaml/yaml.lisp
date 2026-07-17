;;;; yaml.lisp -- bounded YAML 1.2 core-schema parser.

(in-package :clun.yaml)

;;; Limits are checked before allocation or recursive descent. Aliases retain graph
;;; identity, so their cost is one edge rather than the size of the target.

(defconstant +max-source-length+ (* 16 1024 1024))
(defconstant +max-depth+ 256)
(defconstant +max-documents+ 1024)
(defconstant +max-nodes+ 1000000)
(defconstant +max-edges+ 1000000)
(defconstant +max-anchors+ 100000)
(defconstant +max-aliases+ 1000000)
(defconstant +max-scalar-length+ (* 16 1024 1024))

(define-condition yaml-error (error)
  ((code :initarg :code :reader yaml-error-code)
   (reason :initarg :reason :reader yaml-error-reason)
   (line :initarg :line :reader yaml-error-line)
   (column :initarg :column :reader yaml-error-column)
   (offset :initarg :offset :reader yaml-error-offset)
   (document :initarg :document :reader yaml-error-document))
  (:report (lambda (condition stream)
             (format stream "~a at ~d:~d"
                     (yaml-error-reason condition)
                     (yaml-error-line condition)
                     (yaml-error-column condition)))))

(defstruct (yaml-stream (:conc-name yaml-stream-))
  (documents #() :type vector))

(defstruct (yaml-node (:conc-name yaml-node-))
  kind
  value
  anchor
  tag
  (line 1 :type fixnum)
  (column 1 :type fixnum)
  (offset 0 :type fixnum)
  style)

(defstruct (yaml-pair (:conc-name yaml-pair-))
  key
  value
  merge-p
  (line 1 :type fixnum)
  (column 1 :type fixnum)
  (offset 0 :type fixnum))

(defstruct (source-line (:conc-name sl-))
  (text "" :type string)
  (number 1 :type fixnum)
  (offset 0 :type fixnum)
  newline-p)

(defstruct (yaml-parser (:conc-name yp-))
  (source "" :type string)
  (lines #() :type vector)
  (index 0 :type fixnum)
  (document 0 :type fixnum)
  (anchors (make-hash-table :test 'equal))
  (tag-handles (make-hash-table :test 'equal))
  (declared-tag-handles (make-hash-table :test 'equal))
  (nodes 0 :type fixnum)
  (edges 0 :type fixnum)
  (aliases 0 :type fixnum))

(defstruct (flow-reader (:conc-name fr-))
  parser
  (text "" :type string)
  (position 0 :type fixnum)
  (length 0 :type fixnum)
  (line 1 :type fixnum)
  (column 1 :type fixnum)
  (offset 0 :type fixnum))

(defun yaml-fail (parser code reason &key line column offset)
  (let* ((current (and (< (yp-index parser) (length (yp-lines parser)))
                       (aref (yp-lines parser) (yp-index parser))))
         (actual-line (or line (and current (sl-number current)) 1))
         (actual-column (or column 1))
         (actual-offset (or offset
                            (and current (+ (sl-offset current) (1- actual-column)))
                            0)))
    (error 'yaml-error
           :code code :reason reason :line actual-line :column actual-column
           :offset actual-offset :document (yp-document parser))))

(defun split-source-lines (source)
  "Split SOURCE while normalizing CRLF/CR logically and retaining original offsets."
  (let* ((lines (make-array 16 :adjustable t :fill-pointer 0))
         (starts-with-bom (and (plusp (length source))
                               (= (char-code (char source 0)) #xfeff)))
         (start (if starts-with-bom 1 0))
        (line-number 1)
        (length (length source))
        (position (if starts-with-bom 1 0)))
    (labels ((emit (end newline-p)
               (vector-push-extend
                (make-source-line :text (subseq source start end)
                                  :number line-number :offset start
                                  :newline-p newline-p)
                lines)
               (incf line-number)))
      (loop while (< position length) do
        (let ((character (char source position)))
          (cond
            ((char= character #\Newline)
             (emit position t)
             (incf position)
             (setf start position))
            ((char= character #\Return)
             (emit position t)
             (incf position)
             (when (and (< position length)
                        (char= (char source position) #\Newline))
               (incf position))
             (setf start position))
            (t (incf position)))))
      (when (or (< start length) (zerop length))
        (emit length nil)))
    (coerce lines 'vector)))

(defun ascii-space-p (character)
  (or (char= character #\Space) (char= character #\Tab)))

(defun trim-left-index (string &optional (start 0))
  (loop for index from start below (length string)
        unless (ascii-space-p (char string index)) return index
        finally (return (length string))))

(defun trim-right-index (string &optional (end (length string)))
  (loop for index downfrom (1- end) to 0
        unless (ascii-space-p (char string index)) return (1+ index)
        finally (return 0)))

(defun trim-ascii-space (string)
  (let* ((start (trim-left-index string))
         (end (trim-right-index string)))
    (if (<= end start) "" (subseq string start end))))

(defun line-indentation (parser line)
  (let ((text (sl-text line)))
    (loop for index below (length text)
          for character = (char text index)
          do (cond
               ((char= character #\Space))
               ((char= character #\Tab)
                (yaml-fail parser :tab-indentation
                           "tab characters are not allowed in indentation"
                           :line (sl-number line) :column (1+ index)
                           :offset (+ (sl-offset line) index)))
               (t (return index)))
          finally (return (length text)))))

(defun comment-start (string &optional (start 0))
  "Return a separated comment marker, respecting quotes and flow nesting."
  (let ((single nil) (double nil) (escape nil) (depth 0))
    (loop for index from start below (length string)
          for character = (char string index) do
      (cond
        (double
         (cond (escape (setf escape nil))
               ((char= character #\\) (setf escape t))
               ((char= character #\") (setf double nil))))
        (single
         (when (char= character #\')
           (if (and (< (1+ index) (length string))
                    (char= (char string (1+ index)) #\'))
               (incf index)
               (setf single nil))))
        ((char= character #\") (setf double t))
        ((char= character #\') (setf single t))
        ((member character '(#\[ #\{)) (incf depth))
        ((member character '(#\] #\})) (when (plusp depth) (decf depth)))
        ((and (char= character #\#)
              (or (= index start) (ascii-space-p (char string (1- index)))))
         (return index))))))

(defun line-content (line indentation)
  (let* ((text (sl-text line))
         (comment (comment-start text indentation))
         (end (trim-right-index text (or comment (length text)))))
    (if (<= end indentation) "" (subseq text indentation end))))

(defun ignorable-line-p (parser line)
  (zerop (length (line-content line (line-indentation parser line)))))

(defun marker-line-p (parser line marker)
  (let* ((indent (line-indentation parser line))
         (content (line-content line indent)))
    (and (zerop indent)
         (>= (length content) (length marker))
         (string= marker content :end2 (length marker))
         (or (= (length content) (length marker))
             (ascii-space-p (char content (length marker)))))))

(defun document-boundary-p (parser)
  (and (< (yp-index parser) (length (yp-lines parser)))
       (let ((line (aref (yp-lines parser) (yp-index parser))))
         (or (marker-line-p parser line "---")
             (marker-line-p parser line "...")))))

(defun skip-ignorable-lines (parser)
  (loop while (< (yp-index parser) (length (yp-lines parser)))
        for line = (aref (yp-lines parser) (yp-index parser))
        while (ignorable-line-p parser line)
        do (incf (yp-index parser))))

(defun checked-node (parser kind value line column offset &key anchor tag style)
  (when (>= (yp-nodes parser) +max-nodes+)
    (yaml-fail parser :node-limit "YAML node limit exceeded"
               :line line :column column :offset offset))
  (incf (yp-nodes parser))
  (make-yaml-node :kind kind :value value :line line :column column :offset offset
                  :anchor anchor :tag tag :style style))

(defun checked-edge (parser line column offset)
  (when (>= (yp-edges parser) +max-edges+)
    (yaml-fail parser :edge-limit "YAML collection edge limit exceeded"
               :line line :column column :offset offset))
  (incf (yp-edges parser)))

(defun make-node-vector ()
  (make-array 4 :adjustable t :fill-pointer 0))

(defun register-anchor (parser name node line column offset)
  (when name
    ;; A repeated name shadows the lookup for subsequent aliases; aliases
    ;; already resolved to the earlier node retain that identity.
    (when (and (not (gethash name (yp-anchors parser)))
               (>= (hash-table-count (yp-anchors parser)) +max-anchors+))
      (yaml-fail parser :anchor-limit "YAML anchor limit exceeded"
                 :line line :column column :offset offset))
    (setf (gethash name (yp-anchors parser)) node
          (yaml-node-anchor node) name))
  node)

(defun resolve-alias (parser name line column offset)
  (when (>= (yp-aliases parser) +max-aliases+)
    (yaml-fail parser :alias-limit "YAML alias limit exceeded"
               :line line :column column :offset offset))
  (incf (yp-aliases parser))
  (or (gethash name (yp-anchors parser))
      (yaml-fail parser :unresolved-alias
                 (format nil "unresolved alias '*~a'" name)
                 :line line :column column :offset offset)))

(defun token-delimiter-p (character)
  (or (ascii-space-p character)
      (member character '(#\[ #\] #\{ #\} #\, #\#))))

(defun property-token-end (string start)
  (loop for index from start below (length string)
        when (token-delimiter-p (char string index)) return index
        finally (return (length string))))

(defun parse-node-properties (parser text start line column offset)
  "Return REST-INDEX, ANCHOR, TAG for leading node properties."
  (let ((position (trim-left-index text start))
        (anchor nil)
        (tag nil))
    (loop while (< position (length text)) do
      (case (char text position)
        (#\&
         (when anchor
           (yaml-fail parser :multiple-anchors "multiple anchors on one node"
                      :line line :column (+ column position)
                      :offset (+ offset position)))
         (let ((end (property-token-end text (1+ position))))
           (when (= end (1+ position))
             (yaml-fail parser :invalid-anchor "anchor name is empty"
                        :line line :column (+ column position)
                        :offset (+ offset position)))
           (setf anchor (subseq text (1+ position) end)
                 position (trim-left-index text end))))
        (#\!
         (when tag
           (yaml-fail parser :multiple-tags "multiple tags on one node"
                      :line line :column (+ column position)
                      :offset (+ offset position)))
         (let ((end (if (and (< (1+ position) (length text))
                             (char= (char text (1+ position)) #\<))
                        (or (position #\> text :start (+ position 2))
                            (yaml-fail parser :invalid-tag "unterminated verbatim tag"
                                       :line line :column (+ column position)
                                       :offset (+ offset position)))
                        (property-token-end text (1+ position)))))
           (when (and (< (1+ position) (length text))
                      (char= (char text (1+ position)) #\<))
             (incf end))
           (setf tag (subseq text position end)
                 position (trim-left-index text end))))
        (otherwise (return))))
    (values position anchor tag)))

(defun expand-tag (parser tag line column offset)
  "Expand TAG through active %TAG handles; custom tags stay inert metadata."
  (cond
    ((null tag) nil)
    ((string= tag "!") "tag:yaml.org,2002:str")
    ((and (> (length tag) 3)
          (string= tag "!<" :end1 2)
          (char= (char tag (1- (length tag))) #\>))
     (subseq tag 2 (1- (length tag))))
    (t
     (let* ((secondary (and (> (length tag) 1)
                            (position #\! tag :start 1)))
            (handle (if secondary (subseq tag 0 (1+ secondary)) "!"))
            (suffix (subseq tag (length handle)))
            (prefix (gethash handle (yp-tag-handles parser))))
       (unless prefix
         (yaml-fail parser :undefined-tag-handle
                    (format nil "undefined YAML tag handle '~a'" handle)
                    :line line :column column :offset offset))
       (concatenate 'string prefix suffix)))))

(defun canonical-tag (parser tag line column offset)
  (let ((expanded (expand-tag parser tag line column offset)))
    (if (and expanded
             (>= (length expanded) 18)
             (string= expanded "tag:yaml.org,2002:" :end1 18 :end2 18))
        (concatenate 'string "!!" (subseq expanded 18))
        expanded)))

(defun decimal-digit-p (character)
  (and character (char<= #\0 character #\9)))

(defun all-digits-p (string start &optional (end (length string)) (base 10))
  (and (< start end)
       (loop for index from start below end
             for digit = (digit-char-p (char string index) base)
             always digit)))

(defun signed-zero (negative)
  (if negative (- 0d0) 0d0))

(defun bounded-decimal-exponent (text start end)
  "Parse an already-validated exponent without constructing an unbounded integer."
  (let ((negative nil)
        (value 0))
    (when (and (< start end) (member (char text start) '(#\+ #\-)))
      (setf negative (char= (char text start) #\-))
      (incf start))
    (loop for index from start below end
          for digit = (digit-char-p (char text index))
          do (setf value (min 100000 (+ (* value 10) digit))))
    (if negative (- value) value)))

(defun decimal-float-value (text start negative)
  "Convert a validated decimal token without invoking the Common Lisp reader."
  (let* ((length (length text))
         (exponent-index (or (position-if (lambda (character)
                                            (member character '(#\e #\E)))
                                          text :start start)
                             length))
         (dot-index (position #\. text :start start :end exponent-index))
         (fraction-digits (if dot-index (- exponent-index dot-index 1) 0))
         (explicit-exponent (if (< exponent-index length)
                                (bounded-decimal-exponent text (1+ exponent-index) length)
                                0))
         (mantissa 0)
         (significant-digits 0)
         (kept-digits 0)
         (seen-nonzero nil))
    ;; 768 retained decimal digits are enough to preserve the complete IEEE-754
    ;; conversion boundary while preventing giant input from creating giant bignums.
    (loop for index from start below exponent-index
          for character = (char text index)
          unless (char= character #\.) do
            (let ((digit (digit-char-p character)))
              (when (or seen-nonzero (plusp digit))
                (setf seen-nonzero t)
                (incf significant-digits)
                (when (< kept-digits 768)
                  (setf mantissa (+ (* mantissa 10) digit))
                  (incf kept-digits)))))
    (when (zerop mantissa)
      (return-from decimal-float-value (signed-zero negative)))
    (let* ((dropped (- significant-digits kept-digits))
           (power (+ explicit-exponent (- fraction-digits) dropped))
           (magnitude (+ kept-digits power)))
      (cond
        ((> magnitude 310)
         (if negative :negative-infinity :positive-infinity))
        ((< magnitude -400) (signed-zero negative))
        (t
         (handler-case
             (let* ((exact (if (minusp power)
                               (/ mantissa (expt 10 (- power)))
                               (* mantissa (expt 10 power))))
                    (value (coerce exact 'double-float)))
               (if negative (- value) value))
           (floating-point-overflow ()
             (if negative :negative-infinity :positive-infinity))
           (floating-point-underflow () (signed-zero negative))))))))

(defun bounded-radix-integer-value (text start end radix negative)
  "Parse a validated integer while keeping host bignums below a fixed ceiling."
  (let ((value 0))
    (loop for index from start below end
          for digit = (digit-char-p (char text index) radix)
          do (setf value (+ (* value radix) digit))
             ;; IEEE-754 overflows below this ceiling. Stop before an attacker can
             ;; turn a long scalar into a proportionally large host bignum.
             (when (> (integer-length value) 1100)
               (return-from bounded-radix-integer-value
                 (if negative :negative-infinity :positive-infinity))))
    (cond
      ((zerop value) (if negative (signed-zero t) 0))
      (negative (- value))
      (t value))))

(defun parse-core-number (text)
  "Return VALUE, PRESENT-P for one complete YAML 1.2 core number token."
  (let* ((length (length text))
         (position 0)
         (negative nil))
    (when (zerop length) (return-from parse-core-number (values nil nil)))
    (when (member (char text 0) '(#\+ #\-))
      (setf negative (char= (char text 0) #\-))
      (incf position)
      (when (= position length) (return-from parse-core-number (values nil nil))))
    (let ((rest (subseq text position)))
      (cond
        ((member rest '(".inf" ".Inf" ".INF") :test #'string=)
         (values nil :infinity))
        ((and (zerop position) (member rest '(".nan" ".NaN" ".NAN") :test #'string=))
         (values :nan t))
        ((and (>= (- length position) 3)
              (char= (char text position) #\0)
              (member (char text (1+ position)) '(#\x #\X)))
         (if (all-digits-p text (+ position 2) length 16)
             (values (bounded-radix-integer-value
                      text (+ position 2) length 16 negative)
                     t)
             (values nil nil)))
        ((and (>= (- length position) 3)
              (char= (char text position) #\0)
              (member (char text (1+ position)) '(#\o #\O)))
         (if (all-digits-p text (+ position 2) length 8)
             (values (bounded-radix-integer-value
                      text (+ position 2) length 8 negative)
                     t)
             (values nil nil)))
        (t
         (let ((index position) (digits-before 0) (digits-after 0)
               (dot nil) (exponent nil) (exponent-digits 0))
           (loop while (and (< index length) (decimal-digit-p (char text index)))
                 do (incf digits-before) (incf index))
           (when (and (< index length) (char= (char text index) #\.))
             (setf dot t)
             (incf index)
             (loop while (and (< index length) (decimal-digit-p (char text index)))
                   do (incf digits-after) (incf index)))
           (when (and (< index length) (member (char text index) '(#\e #\E)))
             (setf exponent t)
             (incf index)
             (when (and (< index length) (member (char text index) '(#\+ #\-)))
               (incf index))
             (loop while (and (< index length) (decimal-digit-p (char text index)))
                   do (incf exponent-digits) (incf index)))
           (if (and (= index length)
                    (plusp (+ digits-before digits-after))
                    (or (not exponent) (plusp exponent-digits)))
               (handler-case
                   (if (or dot exponent)
                       (values (decimal-float-value text position negative) t)
                       (values (bounded-radix-integer-value
                                text position length 10 negative)
                               t))
                 (error () (values nil nil)))
               (values nil nil))))))))

(defun scalar-node (parser text line column offset &key tag (style :plain))
  (when (> (length text) +max-scalar-length+)
    (yaml-fail parser :scalar-limit "YAML scalar length limit exceeded"
               :line line :column column :offset offset))
  (let ((canonical (canonical-tag parser tag line column offset)))
    (labels ((node (kind value)
               (checked-node parser kind value line column offset
                             :tag canonical :style style)))
      (cond
        ;; Bun treats core tags as weak hints. Quoted values stay strings and a
        ;; tag that cannot resolve its requested scalar kind also stays a string.
        ((not (eq style :plain)) (node :string text))
        ((string= canonical "!!str") (node :string text))
        ((string= canonical "!!null")
         (if (or (zerop (length text))
                 (member text '("~" "null" "Null" "NULL") :test #'string=))
             (node :null nil)
             (node :string text)))
        ((string= canonical "!!bool")
         (cond ((member text '("true" "True" "TRUE") :test #'string=)
                (node :boolean t))
               ((member text '("false" "False" "FALSE") :test #'string=)
                (node :boolean nil))
               (t (node :string text))))
        ((member canonical '("!!int" "!!float") :test #'string=)
         (multiple-value-bind (number present) (parse-core-number text)
           (if present
               (node :number
                     (case present
                       (:infinity (if (and (plusp (length text))
                                           (char= (char text 0) #\-))
                                      :negative-infinity :positive-infinity))
                       (otherwise number)))
               (node :string text))))
        ((member canonical '("!!seq" "!!map") :test #'string=)
         (node :string text))
        ((or (zerop (length text))
             (member text '("~" "null" "Null" "NULL") :test #'string=))
         (node :null nil))
        ((member text '("true" "True" "TRUE") :test #'string=)
         (node :boolean t))
        ((member text '("false" "False" "FALSE") :test #'string=)
         (node :boolean nil))
        (t
         (multiple-value-bind (number present) (parse-core-number text)
           (if present
               (node :number
                     (case present
                       (:infinity (if (and (plusp (length text))
                                           (char= (char text 0) #\-))
                                      :negative-infinity :positive-infinity))
                       (otherwise number)))
               (node :string text))))))))

(defun apply-collection-tag (parser node tag line column offset)
  (let ((canonical (canonical-tag parser tag line column offset)))
    (when canonical
      (setf (yaml-node-tag node) canonical))
    node))

;;; Flow collections and quoted scalars.

(defun fr-peek (reader)
  (when (< (fr-position reader) (fr-length reader))
    (char (fr-text reader) (fr-position reader))))

(defun fr-next (reader)
  (or (prog1 (fr-peek reader) (incf (fr-position reader)))
      (yaml-fail (fr-parser reader) :unexpected-eof "unexpected end of YAML flow value"
                 :line (fr-line reader) :column (+ (fr-column reader) (fr-position reader))
                 :offset (+ (fr-offset reader) (fr-position reader)))))

(defun fr-skip-separation (reader)
  (loop for character = (fr-peek reader)
        while (and character (member character '(#\Space #\Tab #\Newline #\Return)))
        do (incf (fr-position reader))))

(defun fr-location (reader)
  (values (fr-line reader)
          (+ (fr-column reader) (fr-position reader))
          (+ (fr-offset reader) (fr-position reader))))

(defun hex-value (parser text start count line column offset)
  (when (> (+ start count) (length text))
    (yaml-fail parser :invalid-escape "truncated hexadecimal escape"
               :line line :column column :offset offset))
  (let ((value 0))
    (dotimes (index count value)
      (let ((digit (digit-char-p (char text (+ start index)) 16)))
        (unless digit
          (yaml-fail parser :invalid-escape "invalid hexadecimal escape"
                     :line line :column (+ column index) :offset (+ offset index)))
        (setf value (+ (* value 16) digit))))))

(defun push-codepoint (parser output code line column offset)
  (when (or (> code #x10ffff) (<= #xd800 code #xdfff))
    (yaml-fail parser :invalid-codepoint "invalid Unicode scalar value in escape"
               :line line :column column :offset offset))
  (if (> code #xffff)
      (let* ((value (- code #x10000))
             (high (code-char (+ #xd800 (ash value -10))))
             (low (code-char (+ #xdc00 (logand value #x3ff)))))
        (unless (and high low)
          (yaml-fail parser :invalid-codepoint "unsupported Unicode scalar value in escape"
                     :line line :column column :offset offset))
        (vector-push-extend high output)
        (vector-push-extend low output))
      (let ((character (code-char code)))
        (unless character
          (yaml-fail parser :invalid-codepoint "unsupported Unicode scalar value in escape"
                     :line line :column column :offset offset))
        (vector-push-extend character output))))

(defun push-hex-escape (reader output escape line column offset)
  (let* ((count (case escape (#\x 2) (#\u 4) (#\U 8)))
         (position (fr-position reader))
         (code (hex-value (fr-parser reader) (fr-text reader)
                          position count line column offset)))
    (incf (fr-position reader) count)
    (if (and (char= escape #\u) (<= #xd800 code #xdbff))
        (let ((next (fr-position reader)))
          (unless (and (<= (+ next 6) (fr-length reader))
                       (char= (char (fr-text reader) next) #\\)
                       (char= (char (fr-text reader) (1+ next)) #\u))
            (yaml-fail (fr-parser reader) :invalid-codepoint
                       "high surrogate escape must be followed by a low surrogate escape"
                       :line line :column column :offset offset))
          (let ((low (hex-value (fr-parser reader) (fr-text reader)
                                (+ next 2) 4 line (+ column count 2)
                                (+ offset count 2))))
            (unless (<= #xdc00 low #xdfff)
              (yaml-fail (fr-parser reader) :invalid-codepoint
                         "high surrogate escape must be followed by a low surrogate escape"
                         :line line :column column :offset offset))
            (incf (fr-position reader) 6)
            (vector-push-extend (code-char code) output)
            (vector-push-extend (code-char low) output)))
        (push-codepoint (fr-parser reader) output code line column offset))))

(defun parse-double-quoted (reader)
  (multiple-value-bind (line column offset) (fr-location reader)
    (declare (ignore column offset))
    (fr-next reader)
    (let ((output (make-array 16 :element-type 'character :adjustable t :fill-pointer 0)))
      (loop
        (let ((character (fr-next reader)))
          (cond
            ((char= character #\")
             (return (coerce output 'string)))
            ((char= character #\\)
             (multiple-value-bind (escape-line escape-column escape-offset) (fr-location reader)
               (let ((escape (fr-next reader)))
                 (case escape
                   (#\0 (vector-push-extend (code-char 0) output))
                   (#\a (vector-push-extend (code-char 7) output))
                   (#\b (vector-push-extend (code-char 8) output))
                   (#\t (vector-push-extend #\Tab output))
                   (#\n (vector-push-extend #\Newline output))
                   (#\v (vector-push-extend (code-char 11) output))
                   (#\f (vector-push-extend (code-char 12) output))
                   (#\r (vector-push-extend #\Return output))
                   (#\e (vector-push-extend (code-char 27) output))
                   (#\Space (vector-push-extend #\Space output))
                   (#\" (vector-push-extend #\" output))
                   (#\/ (vector-push-extend #\/ output))
                   (#\\ (vector-push-extend #\\ output))
                   (#\N (push-codepoint (fr-parser reader) output #x85
                                         escape-line escape-column escape-offset))
                   (#\_ (push-codepoint (fr-parser reader) output #xa0
                                         escape-line escape-column escape-offset))
                   (#\L (push-codepoint (fr-parser reader) output #x2028
                                         escape-line escape-column escape-offset))
                   (#\P (push-codepoint (fr-parser reader) output #x2029
                                         escape-line escape-column escape-offset))
                   ((#\x #\u #\U)
                    (push-hex-escape reader output escape
                                     escape-line escape-column escape-offset))
                   (#\Newline
                    (fr-skip-separation reader))
                   (otherwise
                    (yaml-fail (fr-parser reader) :invalid-escape
                               (format nil "unknown YAML escape '\\~a'" escape)
                               :line escape-line :column escape-column :offset escape-offset))))))
            ((or (char= character #\Newline) (char= character #\Return))
             (vector-push-extend #\Space output)
             (fr-skip-separation reader))
            ((< (char-code character) #x20)
             (yaml-fail (fr-parser reader) :control-character
                        "unescaped control character in double-quoted scalar"
                        :line line :column (+ (fr-column reader) (fr-position reader))
                        :offset (+ (fr-offset reader) (fr-position reader))))
            (t (vector-push-extend character output))))
        (when (> (length output) +max-scalar-length+)
          (yaml-fail (fr-parser reader) :scalar-limit "YAML scalar length limit exceeded"
                     :line line :column 1 :offset (fr-offset reader)))))))

(defun parse-single-quoted (reader)
  (fr-next reader)
  (let ((output (make-array 16 :element-type 'character :adjustable t :fill-pointer 0)))
    (loop
      (let ((character (fr-next reader)))
        (cond
          ((char= character #\')
           (if (eql (fr-peek reader) #\')
               (progn (fr-next reader) (vector-push-extend #\' output))
               (return (coerce output 'string))))
          ((or (char= character #\Newline) (char= character #\Return))
           (vector-push-extend #\Space output)
           (fr-skip-separation reader))
          (t (vector-push-extend character output))))
      (when (> (length output) +max-scalar-length+)
        (multiple-value-bind (line column offset) (fr-location reader)
          (yaml-fail (fr-parser reader) :scalar-limit "YAML scalar length limit exceeded"
                     :line line :column column :offset offset))))))

(defun flow-plain-end-p (character key-p)
  (or (member character '(#\, #\] #\}))
      (and key-p (char= character #\:))))

(defun parse-flow-plain (reader key-p)
  (let ((start (fr-position reader)))
    (loop for character = (fr-peek reader)
          while (and character (not (flow-plain-end-p character key-p)))
          do (incf (fr-position reader)))
    (let* ((raw (subseq (fr-text reader) start (fr-position reader)))
           (comment (comment-start raw 0))
           (text (trim-ascii-space (subseq raw 0 (or comment (length raw))))))
      (when (zerop (length text))
        (multiple-value-bind (line column offset) (fr-location reader)
          (yaml-fail (fr-parser reader) :empty-flow-node "expected a YAML flow value"
                     :line line :column column :offset offset)))
      text)))

(defun merge-key-node-p (node)
  (and (eq (yaml-node-kind node) :string)
       (string= (yaml-node-value node) "<<")
       (eq (yaml-node-style node) :plain)
       (null (yaml-node-tag node))))

(defun mapping-key-string (node)
  (case (yaml-node-kind node)
    (:string (yaml-node-value node))
    (:null "null")
    (:boolean (if (yaml-node-value node) "true" "false"))
    (:number
     (let ((value (yaml-node-value node)))
       (case value
         (:positive-infinity "Infinity")
         (:negative-infinity "-Infinity")
         (:nan "NaN")
         (otherwise (princ-to-string value)))))
    (:sequence "")
    (:mapping "[object Object]")
    (otherwise "")))

(defun mapping-source-nodes (parser node pair)
  (case (yaml-node-kind node)
    (:mapping (list node))
    (:sequence
     (loop for item across (yaml-node-value node)
           do (unless (eq (yaml-node-kind item) :mapping)
                (yaml-fail parser :invalid-merge "merge sequence items must be mappings"
                           :line (yaml-pair-line pair) :column (yaml-pair-column pair)
                           :offset (yaml-pair-offset pair)))
           collect item))
    (otherwise
     (yaml-fail parser :invalid-merge "merge value must be a mapping or sequence of mappings"
                :line (yaml-pair-line pair) :column (yaml-pair-column pair)
                :offset (yaml-pair-offset pair)))))

(defun finalize-mapping (parser node)
  "Apply merge precedence and last-explicit-key-wins without copying target nodes."
  (let ((raw (yaml-node-value node))
        (explicit (make-hash-table :test 'equal))
        (merged (make-hash-table :test 'equal))
        (result (make-node-vector)))
    ;; Establish every explicit key first, so it wins regardless of merge position.
    (loop for pair across raw
          unless (yaml-pair-merge-p pair)
            do (setf (gethash (mapping-key-string (yaml-pair-key pair)) explicit) pair))
    ;; Bun materializes explicit keys first, preserving the last occurrence at
    ;; its final source position, then appends non-overridden merge keys.
    (loop for pair across raw
          unless (yaml-pair-merge-p pair) do
            (let ((key (mapping-key-string (yaml-pair-key pair))))
              (when (eq pair (gethash key explicit))
                (vector-push-extend pair result))))
    ;; Merge sources are considered in source order; their first definition wins.
    (loop for pair across raw
          when (yaml-pair-merge-p pair) do
            (dolist (source (mapping-source-nodes parser (yaml-pair-value pair) pair))
              (loop for source-pair across (yaml-node-value source)
                    for key = (mapping-key-string (yaml-pair-key source-pair))
                    unless (or (gethash key explicit) (gethash key merged)) do
                      (checked-edge parser (yaml-pair-line pair) (yaml-pair-column pair)
                                    (yaml-pair-offset pair))
                      (setf (gethash key merged) t)
                      (vector-push-extend source-pair result))))
    (setf (yaml-node-value node) result)
    node))

(defun flow-parse-node (reader depth &key key-p)
  (when (> depth +max-depth+)
    (multiple-value-bind (line column offset) (fr-location reader)
      (yaml-fail (fr-parser reader) :depth-limit "YAML nesting depth limit exceeded"
                 :line line :column column :offset offset)))
  (fr-skip-separation reader)
  (multiple-value-bind (line column offset) (fr-location reader)
    (multiple-value-bind (position anchor tag)
        (parse-node-properties (fr-parser reader) (fr-text reader) (fr-position reader)
                               line (fr-column reader) (fr-offset reader))
      (setf (fr-position reader) position)
      (fr-skip-separation reader)
      (let* ((character (fr-peek reader))
             (node
               (cond
                 ((null character)
                  (scalar-node (fr-parser reader) "" line column offset :tag tag))
                 ((char= character #\*)
                  (fr-next reader)
                  (let ((start (fr-position reader)))
                    (loop for current = (fr-peek reader)
                          while (and current (not (token-delimiter-p current)))
                          do (incf (fr-position reader)))
                    (when (= start (fr-position reader))
                      (yaml-fail (fr-parser reader) :invalid-alias "alias name is empty"
                                 :line line :column column :offset offset))
                    (when (or anchor tag)
                      (yaml-fail (fr-parser reader) :alias-properties
                                 "aliases cannot have anchors or tags"
                                 :line line :column column :offset offset))
                    (resolve-alias (fr-parser reader)
                                   (subseq (fr-text reader) start (fr-position reader))
                                   line column offset)))
                 ((char= character #\[)
                  (let ((sequence (checked-node (fr-parser reader) :sequence (make-node-vector)
                                                line column offset :anchor anchor :tag tag
                                                :style :flow)))
                    (register-anchor (fr-parser reader) anchor sequence line column offset)
                    (apply-collection-tag (fr-parser reader) sequence tag line column offset)
                    (fr-next reader)
                    (fr-skip-separation reader)
                    (unless (eql (fr-peek reader) #\])
                      (loop
                        (let ((item (flow-parse-node reader (1+ depth))))
                          (checked-edge (fr-parser reader) line column offset)
                          (vector-push-extend item (yaml-node-value sequence)))
                        (fr-skip-separation reader)
                        (case (fr-peek reader)
                          (#\, (fr-next reader)
                               (fr-skip-separation reader)
                               (when (eql (fr-peek reader) #\]) (return)))
                          (#\] (return))
                          (otherwise
                           (yaml-fail (fr-parser reader) :flow-separator
                                      "expected ',' or ']' in flow sequence"
                                      :line line :column column :offset offset)))))
                    (unless (eql (fr-next reader) #\])
                      (yaml-fail (fr-parser reader) :flow-close "expected ']'"
                                 :line line :column column :offset offset))
                    sequence))
                 ((char= character #\{)
                  (let ((mapping (checked-node (fr-parser reader) :mapping (make-node-vector)
                                               line column offset :anchor anchor :tag tag
                                               :style :flow)))
                    (register-anchor (fr-parser reader) anchor mapping line column offset)
                    (apply-collection-tag (fr-parser reader) mapping tag line column offset)
                    (fr-next reader)
                    (fr-skip-separation reader)
                    (unless (eql (fr-peek reader) #\})
                      (loop
                        (multiple-value-bind (key-line key-column key-offset) (fr-location reader)
                          (let ((key (flow-parse-node reader (1+ depth) :key-p t)))
                            (fr-skip-separation reader)
                            (unless (eql (fr-next reader) #\:)
                              (yaml-fail (fr-parser reader) :mapping-colon
                                         "expected ':' in flow mapping"
                                         :line key-line :column key-column :offset key-offset))
                            (fr-skip-separation reader)
                            (let ((value (if (member (fr-peek reader) '(#\, #\}))
                                             (scalar-node (fr-parser reader) ""
                                                          key-line key-column key-offset)
                                             (flow-parse-node reader (1+ depth)))))
                              (checked-edge (fr-parser reader) key-line key-column key-offset)
                              (vector-push-extend
                               (make-yaml-pair :key key :value value
                                               :merge-p (merge-key-node-p key)
                                               :line key-line :column key-column
                                               :offset key-offset)
                               (yaml-node-value mapping)))))
                        (fr-skip-separation reader)
                        (case (fr-peek reader)
                          (#\, (fr-next reader)
                               (fr-skip-separation reader)
                               (when (eql (fr-peek reader) #\}) (return)))
                          (#\} (return))
                          (otherwise
                           (yaml-fail (fr-parser reader) :flow-separator
                                      "expected ',' or '}' in flow mapping"
                                      :line line :column column :offset offset)))))
                    (unless (eql (fr-next reader) #\})
                      (yaml-fail (fr-parser reader) :flow-close "expected '}'"
                                 :line line :column column :offset offset))
                    (finalize-mapping (fr-parser reader) mapping)))
                 ((char= character #\")
                  (scalar-node (fr-parser reader) (parse-double-quoted reader)
                               line column offset :tag tag :style :double-quoted))
                 ((char= character #\')
                  (scalar-node (fr-parser reader) (parse-single-quoted reader)
                               line column offset :tag tag :style :single-quoted))
                 (t
                  (scalar-node (fr-parser reader) (parse-flow-plain reader key-p)
                               line column offset :tag tag :style :plain)))))
        (unless (member (yaml-node-kind node) '(:sequence :mapping))
          (register-anchor (fr-parser reader) anchor node line column offset))
        node))))

(defun parse-inline-value (parser text line column offset &key key-p)
  (let ((reader (make-flow-reader :parser parser :text text :length (length text)
                                  :line line :column column :offset offset)))
    (let ((node (flow-parse-node reader 0 :key-p key-p)))
      (fr-skip-separation reader)
      (when (< (fr-position reader) (fr-length reader))
        (yaml-fail parser :trailing-content "unexpected trailing YAML content"
                   :line line :column (+ column (fr-position reader))
                   :offset (+ offset (fr-position reader))))
      node)))

;;; Block collections, scalar folding, and document framing.

(defun block-mapping-colon (text)
  "Return the first block mapping indicator outside quotes/flow collections."
  (let ((single nil) (double nil) (escape nil) (depth 0))
    (loop for index below (length text)
          for character = (char text index) do
      (cond
        (double
         (cond (escape (setf escape nil))
               ((char= character #\\) (setf escape t))
               ((char= character #\") (setf double nil))))
        (single
         (when (char= character #\')
           (if (and (< (1+ index) (length text))
                    (char= (char text (1+ index)) #\'))
               (incf index)
               (setf single nil))))
        ((char= character #\") (setf double t))
        ((char= character #\') (setf single t))
        ((member character '(#\[ #\{)) (incf depth))
        ((member character '(#\] #\})) (when (plusp depth) (decf depth)))
        ((and (zerop depth) (char= character #\:)
              (or (= (1+ index) (length text))
                  (ascii-space-p (char text (1+ index)))))
         (return index))))))

(defun sequence-indicator-p (content)
  (and (plusp (length content))
       (char= (char content 0) #\-)
       (or (= (length content) 1)
           (ascii-space-p (char content 1)))))

(defun inline-state (text)
  "Return flow depth, quote state, and escape state after scanning TEXT."
  (let ((stack '()) (quote nil) (escape nil))
    (loop for character across text do
      (cond
        ((eq quote :double)
         (cond (escape (setf escape nil))
               ((char= character #\\) (setf escape t))
               ((char= character #\") (setf quote nil))))
        ((eq quote :single)
         (when (char= character #\') (setf quote nil)))
        ((char= character #\") (setf quote :double))
        ((char= character #\') (setf quote :single))
        ((char= character #\[) (push #\] stack))
        ((char= character #\{) (push #\} stack))
        ((member character '(#\] #\}))
         (when (and stack (char= character (first stack))) (pop stack)))))
    (values (length stack) quote escape)))

(defun gather-inline-lines (parser initial line column offset)
  "Gather a multiline quoted/flow value starting on the current parser line."
  (let ((output (make-array (max 16 (length initial))
                            :element-type 'character :adjustable t :fill-pointer 0))
        (text initial))
    (loop for character across initial do (vector-push-extend character output))
    (incf (yp-index parser))
    (loop
      (multiple-value-bind (depth quote escape) (inline-state text)
        (declare (ignore escape))
        (when (and (zerop depth) (null quote))
          (return (coerce output 'string)))
        (when (or (>= (yp-index parser) (length (yp-lines parser)))
                  (document-boundary-p parser))
          (yaml-fail parser :unexpected-eof "unterminated quoted or flow value"
                     :line line :column column :offset offset))
        (let* ((next (aref (yp-lines parser) (yp-index parser)))
               (next-text (sl-text next)))
          (vector-push-extend #\Newline output)
          (loop for character across next-text do (vector-push-extend character output))
          (setf text (coerce output 'string))
          (incf (yp-index parser))
          (when (> (length output) +max-scalar-length+)
            (yaml-fail parser :scalar-limit "YAML scalar length limit exceeded"
                       :line (sl-number next) :column 1 :offset (sl-offset next))))))))

(defun comment-only-line-p (line)
  (let* ((text (sl-text line))
         (start (trim-left-index text)))
    (and (< start (length text)) (char= (char text start) #\#))))

(defun gather-block-plain-lines (parser initial parent-indent allow-same-indent)
  "Fold physical continuation lines for a block-context plain scalar."
  (let* ((initial-line (aref (yp-lines parser) (yp-index parser)))
         (parts (list initial))
        (pending-empty-lines 0)
        ;; A separated comment terminates a plain scalar. Keeping later lines
        ;; outside the scalar also lets the document parser reject an illegal
        ;; continuation after that comment.
         (terminated-by-comment
           (not (null (comment-start (sl-text initial-line))))))
    (incf (yp-index parser))
    (loop while (and (not terminated-by-comment)
                     (< (yp-index parser) (length (yp-lines parser)))) do
      (when (document-boundary-p parser) (return))
      (let* ((next (aref (yp-lines parser) (yp-index parser)))
             (indent (line-indentation parser next))
             (content (line-content next indent)))
        (cond
          ((comment-only-line-p next) (return))
          ((zerop (length content))
           (incf pending-empty-lines)
           (incf (yp-index parser)))
          ((or (> indent parent-indent)
               (and allow-same-indent (= indent parent-indent)))
           (when (or (sequence-indicator-p content)
                     (block-explicit-key-p content)
                     (block-mapping-colon content))
             (return))
           (let ((comment (comment-start (sl-text next) indent)))
             (push (if (plusp pending-empty-lines)
                       (make-string pending-empty-lines :initial-element #\Newline)
                       " ")
                   parts)
             (push content parts)
             (setf terminated-by-comment (not (null comment))))
           (setf pending-empty-lines 0)
           (incf (yp-index parser)))
          (t (return)))))
    (when terminated-by-comment
      (loop for index from (yp-index parser) below (length (yp-lines parser))
            for next = (aref (yp-lines parser) index)
            for indent = (line-indentation parser next)
            for content = (line-content next indent)
            unless (or (zerop (length content)) (comment-only-line-p next)) do
              (cond
                ((or (marker-line-p parser next "---")
                     (marker-line-p parser next "..."))
                 (return))
                ((and (zerop indent) (char= (char content 0) #\%))
                 (yaml-fail parser :directive-after-content
                            "YAML directive requires an explicit prior document end"
                            :line (sl-number next) :column 1 :offset (sl-offset next)))
                ((and (or (> indent parent-indent)
                          (and allow-same-indent (= indent parent-indent)))
                      (not (sequence-indicator-p content))
                      (not (block-explicit-key-p content))
                      (not (block-mapping-colon content)))
                 (yaml-fail parser :invalid-plain-continuation
                            "plain scalar cannot continue after a comment"
                            :line (sl-number next) :column (1+ indent)
                            :offset (+ (sl-offset next) indent))))
              (return)))
    (let ((result (with-output-to-string (output)
                    (dolist (part (nreverse parts))
                      (write-string part output)))))
      (when (> (length result) +max-scalar-length+)
        (yaml-fail parser :scalar-limit "YAML scalar length limit exceeded"))
      result)))

(defun string-trailing-newline-count (string)
  (loop for index downfrom (1- (length string)) to 0
        while (char= (char string index) #\Newline)
        count 1))

(defun chomp-block-scalar (string mode had-content-p had-body-p)
  (let* ((trailing (string-trailing-newline-count string))
         (base (if (plusp trailing) (subseq string 0 (- (length string) trailing)) string)))
    (ecase mode
      (:strip base)
      (:clip (if had-content-p (concatenate 'string base (string #\Newline)) ""))
      (:keep (cond
               ((plusp trailing) string)
               (had-content-p (concatenate 'string string (string #\Newline)))
               (had-body-p (string #\Newline))
               (t ""))))))

(defun fold-block-lines (entries literal-p)
  "ENTRIES is a list of (text newline-p more-indented-p)."
  (let ((seen-content nil))
    (with-output-to-string (output)
      (loop for entry on entries
            for current = (first entry)
            for next = (second entry)
            for text = (first current)
            for newline-p = (second current)
            do (write-string text output)
               (unless (zerop (length text)) (setf seen-content t))
               (when newline-p
                 (cond
                   (literal-p (write-char #\Newline output))
                   ((null next) (write-char #\Newline output))
                   ((or (third current) (third next))
                    (write-char #\Newline output))
                   ((zerop (length text))
                    (when (or (zerop (length (first next))) (not seen-content))
                      (write-char #\Newline output)))
                   ((zerop (length (first next)))
                    (write-char #\Newline output))
                   (t (write-char #\Space output))))))))

(defun parse-block-scalar (parser header parent-indent line column offset)
  (let ((literal-p (char= (char header 0) #\|))
        (chomp :clip)
        (explicit-indent nil))
    (loop for index from 1 below (length header)
          for character = (char header index) do
      (cond
        ((char= character #\+) (if (eq chomp :clip) (setf chomp :keep)
                                   (yaml-fail parser :block-header
                                              "duplicate block chomping indicator"
                                              :line line :column (+ column index)
                                              :offset (+ offset index))))
        ((char= character #\-) (if (eq chomp :clip) (setf chomp :strip)
                                   (yaml-fail parser :block-header
                                              "duplicate block chomping indicator"
                                              :line line :column (+ column index)
                                              :offset (+ offset index))))
        ((and (digit-char-p character) (not (char= character #\0)))
         (if explicit-indent
             (yaml-fail parser :block-header "duplicate block indentation indicator"
                        :line line :column (+ column index) :offset (+ offset index))
             (setf explicit-indent (digit-char-p character))))
        ((ascii-space-p character) (return))
        (t (yaml-fail parser :block-header "invalid block scalar header"
                      :line line :column (+ column index) :offset (+ offset index)))))
    (let ((content-indent (and explicit-indent (+ parent-indent explicit-indent))))
      (unless content-indent
        (loop for scan from (yp-index parser) below (length (yp-lines parser))
              for candidate = (aref (yp-lines parser) scan)
              until (or (marker-line-p parser candidate "---")
                        (marker-line-p parser candidate "..."))
              unless (ignorable-line-p parser candidate) do
                (let ((indent (line-indentation parser candidate)))
                  (when (<= indent parent-indent)
                    (return))
                  (setf content-indent indent)
                  (return))))
      (unless content-indent (setf content-indent (1+ parent-indent)))
      (let ((entries '()) (had-content nil))
        (loop while (< (yp-index parser) (length (yp-lines parser)))
              for current = (aref (yp-lines parser) (yp-index parser))
              do (when (or (marker-line-p parser current "---")
                           (marker-line-p parser current "..."))
                   (return))
                 (let* ((indent (line-indentation parser current))
                        (blank (ignorable-line-p parser current)))
                   (when (and (not blank) (< indent content-indent))
                     (return))
                   (let* ((raw (sl-text current))
                          (start (if blank (min content-indent (length raw)) content-indent))
                          (text (if (<= start (length raw)) (subseq raw start) "")))
                     (when (plusp (length text)) (setf had-content t))
                     (push (list text (sl-newline-p current)
                                 (and (not blank) (> indent content-indent)))
                           entries))
                   (incf (yp-index parser))))
        (let* ((ordered (nreverse entries))
               (result (fold-block-lines ordered literal-p)))
          (when (> (length result) +max-scalar-length+)
            (yaml-fail parser :scalar-limit "YAML scalar length limit exceeded"
                       :line line :column column :offset offset))
          (chomp-block-scalar result chomp had-content (not (null ordered))))))))

(defun retag-existing-node (parser node tag line column offset)
  (if (null tag)
      node
      (let ((canonical (canonical-tag parser tag line column offset)))
        (case (yaml-node-kind node)
          ((:sequence :mapping)
           (setf (yaml-node-tag node) canonical)
           node)
          (otherwise
           (let* ((text (case (yaml-node-kind node)
                          (:null "")
                          (:boolean (if (yaml-node-value node) "true" "false"))
                          (:number (princ-to-string (yaml-node-value node)))
                          (:string (yaml-node-value node))))
                  (replacement (scalar-node parser text line column offset
                                            :tag canonical :style (yaml-node-style node))))
             replacement))))))

(defun apply-deferred-properties (parser node anchor tag line column offset)
  (let ((tagged (retag-existing-node parser node tag line column offset)))
    (register-anchor parser anchor tagged line column offset)
    tagged))

(defun adopt-node-contents (target source)
  "Turn the pre-registered TARGET placeholder into SOURCE without breaking aliases."
  (unless (eq target source)
    (setf (yaml-node-kind target) (yaml-node-kind source)
          (yaml-node-value target) (yaml-node-value source)
          (yaml-node-line target) (yaml-node-line source)
          (yaml-node-column target) (yaml-node-column source)
          (yaml-node-offset target) (yaml-node-offset source)
          (yaml-node-tag target) (yaml-node-tag source)
          (yaml-node-style target) (yaml-node-style source)))
  target)

(declaim (ftype (function (yaml-parser integer integer) yaml-node) parse-block-node))

(defun parse-value-from-current (parser text parent-indent line column offset depth
                                 &key allow-same-indent allow-indentless-sequence
                                   allow-same-indent-plain)
  "Parse TEXT from the current physical line and advance to its successor."
  (multiple-value-bind (rest-index anchor tag)
      (parse-node-properties parser text 0 line column offset)
    (let* ((rest (trim-ascii-space (subseq text rest-index)))
           (rest-column (+ column rest-index))
           (rest-offset (+ offset rest-index)))
      (cond
        ((zerop (length rest))
         (incf (yp-index parser))
         (skip-ignorable-lines parser)
         (let* ((has-next (and (< (yp-index parser) (length (yp-lines parser)))
                               (not (document-boundary-p parser))))
                (indent (and has-next
                             (line-indentation
                              parser (aref (yp-lines parser) (yp-index parser)))))
                (has-child
                  (and has-next
                       (or (> indent parent-indent)
                           (and allow-same-indent (>= indent parent-indent))
                           (and allow-indentless-sequence
                                (= indent parent-indent)
                                (sequence-indicator-p
                                 (line-content
                                  (aref (yp-lines parser) (yp-index parser))
                                  indent)))))))
           (cond
             ((and has-child anchor)
              ;; Register before descending so an anchored block collection may
              ;; legally refer to itself.  Aliases keep pointing at this object
              ;; while its parsed contents are adopted after the descent.
              (let ((placeholder
                      (make-yaml-node :kind :pending :value nil
                                      :line line :column column :offset offset
                                      :anchor anchor :style :block)))
                (register-anchor parser anchor placeholder line column offset)
                (let* ((parsed (parse-block-node parser indent (1+ depth)))
                       (effective-tag (and (not (yaml-node-tag parsed)) tag))
                       (tagged (retag-existing-node parser parsed effective-tag
                                                   line column offset)))
                  (when (eq tagged placeholder)
                    (yaml-fail parser :recursive-alias
                               "an alias cannot be the complete anchored node"
                               :line line :column column :offset offset))
                  (adopt-node-contents placeholder tagged))))
             (has-child
              (let ((node (parse-block-node parser indent (1+ depth))))
                (apply-deferred-properties parser node nil
                                           (and (not (yaml-node-tag node)) tag)
                                           line column offset)))
             (t
              (let ((node (scalar-node parser "" line column offset :tag tag)))
                (apply-deferred-properties parser node anchor
                                           (and (not (yaml-node-tag node)) tag)
                                           line column offset))))))
        ((member (char rest 0) '(#\| #\>))
         (incf (yp-index parser))
         (let ((node (scalar-node parser
                                  (parse-block-scalar parser rest parent-indent
                                                      line rest-column rest-offset)
                                  line rest-column rest-offset :tag tag
                                  :style (if (char= (char rest 0) #\|)
                                             :literal :folded))))
           (register-anchor parser anchor node line column offset)))
        (t
         (let* ((plain-p (not (member (char rest 0) '(#\" #\' #\[ #\{ #\*))))
                (gathered (if plain-p
                              (gather-block-plain-lines
                               parser text parent-indent allow-same-indent-plain)
                              (gather-inline-lines parser text line column offset)))
                (node (parse-inline-value parser gathered line column offset)))
           node))))))

(defun block-explicit-key-p (content)
  (and (plusp (length content))
       (char= (char content 0) #\?)
       (or (= (length content) 1)
           (ascii-space-p (char content 1)))))

(defun block-explicit-value-p (content)
  (and (plusp (length content))
       (char= (char content 0) #\:)
       (or (= (length content) 1)
           (ascii-space-p (char content 1)))))

(defun parse-block-explicit-mapping-pair (parser mapping content mapping-indent
                                          line column offset depth)
  (let* ((key-start (trim-left-index content 1))
         (key-text (subseq content key-start))
         (key (parse-value-from-current parser key-text mapping-indent
                                        line (+ column key-start)
                                        (+ offset key-start) depth)))
    (skip-ignorable-lines parser)
    (let ((value
            (if (and (< (yp-index parser) (length (yp-lines parser)))
                     (not (document-boundary-p parser)))
                (let* ((current (aref (yp-lines parser) (yp-index parser)))
                       (current-indent (line-indentation parser current))
                       (current-content (line-content current current-indent)))
                  (if (and (= current-indent mapping-indent)
                           (block-explicit-value-p current-content))
                      (let* ((value-start (trim-left-index current-content 1))
                             (value-text (subseq current-content value-start))
                             (value-column (+ 1 current-indent value-start))
                             (value-offset (+ (sl-offset current) current-indent value-start)))
                        (if (and (plusp (length value-text))
                                 (block-mapping-colon value-text))
                            (parse-block-mapping
                             parser (+ mapping-indent 2) depth
                             :first-content value-text :first-line current
                             :first-column value-column :first-offset value-offset)
                            (parse-value-from-current
                             parser value-text mapping-indent
                             (sl-number current) value-column value-offset depth
                             :allow-indentless-sequence t)))
                      (scalar-node parser "" line column offset)))
                (scalar-node parser "" line column offset))))
      (checked-edge parser line column offset)
      (vector-push-extend
       (make-yaml-pair :key key :value value :merge-p (merge-key-node-p key)
                       :line line :column column :offset offset)
       (yaml-node-value mapping))
      mapping)))

(defun parse-block-mapping-pair (parser mapping content mapping-indent
                                 line column offset depth)
  (let ((colon (block-mapping-colon content)))
    (unless colon
      (yaml-fail parser :mapping-colon "expected ':' in block mapping"
                 :line line :column column :offset offset))
    (let* ((key-text (trim-ascii-space (subseq content 0 colon)))
           (value-start (trim-left-index content (1+ colon)))
           (value-text (subseq content value-start))
           (key (if (zerop (length key-text))
                    (scalar-node parser "" line column offset)
                    (parse-inline-value parser key-text line column offset :key-p t)))
           (value (parse-value-from-current parser value-text mapping-indent
                                            line (+ column value-start)
                                            (+ offset value-start) depth
                                            :allow-indentless-sequence t)))
      (checked-edge parser line column offset)
      (vector-push-extend
       (make-yaml-pair :key key :value value :merge-p (merge-key-node-p key)
                       :line line :column column :offset offset)
       (yaml-node-value mapping))
      mapping)))

(defun parse-block-mapping (parser indent depth
                            &key first-content first-line first-column first-offset)
  (let* ((origin (or first-line (aref (yp-lines parser) (yp-index parser))))
         (line (if (source-line-p origin) (sl-number origin) origin))
         (column (or first-column (1+ indent)))
         (offset (or first-offset
                     (+ (sl-offset origin) indent)))
         (mapping (checked-node parser :mapping (make-node-vector)
                                line column offset :style :block)))
    (when first-content
      (if (block-explicit-key-p first-content)
          (parse-block-explicit-mapping-pair parser mapping first-content indent
                                             line column offset depth)
          (parse-block-mapping-pair parser mapping first-content indent
                                    line column offset depth)))
    (loop while (< (yp-index parser) (length (yp-lines parser))) do
      (when (document-boundary-p parser) (return))
      (let* ((current (aref (yp-lines parser) (yp-index parser))))
        (when (ignorable-line-p parser current)
          (skip-ignorable-lines parser)
          (when (or (>= (yp-index parser) (length (yp-lines parser)))
                    (document-boundary-p parser))
            (return))
          (setf current (aref (yp-lines parser) (yp-index parser))))
        (let* ((current-indent (line-indentation parser current))
               (content (line-content current current-indent)))
          (unless (and (= current-indent indent)
                       (or (block-explicit-key-p content)
                           (and (block-mapping-colon content)
                                (not (sequence-indicator-p content)))))
            (return))
          (if (block-explicit-key-p content)
              (parse-block-explicit-mapping-pair
               parser mapping content indent
               (sl-number current) (1+ current-indent)
               (+ (sl-offset current) current-indent) depth)
              (parse-block-mapping-pair parser mapping content indent
                                        (sl-number current) (1+ current-indent)
                                        (+ (sl-offset current) current-indent) depth)))))
    (finalize-mapping parser mapping)))

(defun parse-compact-mapping (parser content sequence-indent line column offset depth)
  (parse-block-mapping parser (+ sequence-indent 2) depth
                       :first-content content :first-line line
                       :first-column column :first-offset offset))

(defun parse-block-sequence (parser indent depth)
  (let* ((origin (aref (yp-lines parser) (yp-index parser)))
         (sequence (checked-node parser :sequence (make-node-vector)
                                 (sl-number origin) (1+ indent)
                                 (+ (sl-offset origin) indent) :style :block)))
    (loop while (< (yp-index parser) (length (yp-lines parser))) do
      (when (document-boundary-p parser) (return))
      (let ((current (aref (yp-lines parser) (yp-index parser))))
        (when (ignorable-line-p parser current)
          (skip-ignorable-lines parser)
          (when (or (>= (yp-index parser) (length (yp-lines parser)))
                    (document-boundary-p parser))
            (return))
          (setf current (aref (yp-lines parser) (yp-index parser))))
        (let* ((current-indent (line-indentation parser current))
               (content (line-content current current-indent)))
          (unless (and (= current-indent indent) (sequence-indicator-p content))
            (return))
          (let* ((value-start (trim-left-index content 1))
                 (rest (subseq content value-start))
                 (line (sl-number current))
                 (column (+ 1 indent value-start))
                 (offset (+ (sl-offset current) indent value-start))
                 (value
                   (if (and (plusp (length rest))
                            (or (block-explicit-key-p rest)
                                (block-mapping-colon rest)))
                       (parse-compact-mapping parser rest indent line column offset depth)
                       (parse-value-from-current parser rest indent line column offset depth))))
            (checked-edge parser line column offset)
            (vector-push-extend value (yaml-node-value sequence))))))
    sequence))

(defun parse-block-node (parser indent depth)
  (when (> depth +max-depth+)
    (yaml-fail parser :depth-limit "YAML nesting depth limit exceeded"))
  (skip-ignorable-lines parser)
  (when (or (>= (yp-index parser) (length (yp-lines parser)))
            (document-boundary-p parser))
    (return-from parse-block-node
      (checked-node parser :null nil 1 1 0 :style :plain)))
  (let* ((line (aref (yp-lines parser) (yp-index parser)))
         (actual-indent (line-indentation parser line))
         (content (line-content line actual-indent))
         (line-number (sl-number line))
         (column (1+ actual-indent))
         (offset (+ (sl-offset line) actual-indent)))
    (when (< actual-indent indent)
      (yaml-fail parser :indentation "unexpected dedent"
                 :line line-number :column column :offset offset))
    (multiple-value-bind (rest-index anchor tag)
        (parse-node-properties parser content 0 line-number column offset)
      (let ((rest (trim-ascii-space (subseq content rest-index))))
        (cond
          ;; A property-only line applies to the following indented node.
          ((and (or anchor tag) (zerop (length rest)))
           (parse-value-from-current parser content actual-indent
                                     line-number column offset depth
                                     :allow-same-indent t))
          ;; Block collections do not carry inline properties in their indicator.
          ((and (null anchor) (null tag) (sequence-indicator-p content))
           (parse-block-sequence parser actual-indent depth))
          ((and (null anchor) (null tag)
                (or (block-explicit-key-p content)
                    (block-mapping-colon content)))
           (parse-block-mapping parser actual-indent depth))
          (t
           (parse-value-from-current parser content actual-indent
                                     line-number column offset depth
                                     :allow-same-indent-plain t)))))))

(defun reset-document-state (parser)
  (clrhash (yp-anchors parser))
  (clrhash (yp-tag-handles parser))
  (clrhash (yp-declared-tag-handles parser))
  (setf (gethash "!!" (yp-tag-handles parser)) "tag:yaml.org,2002:"
        (gethash "!" (yp-tag-handles parser)) "!"))

(defun directive-line-p (parser line)
  (let* ((indent (line-indentation parser line))
         (content (line-content line indent)))
    (and (zerop indent) (plusp (length content))
         (char= (char content 0) #\%))))

(defun yaml-version-token-p (text)
  (let ((dot (position #\. text)))
    (and dot
         (plusp dot)
         (< (1+ dot) (length text))
         (all-digits-p text 0 dot)
         (all-digits-p text (1+ dot)))))

(defun parse-directive (parser line)
  (let* ((content (line-content line 0))
         (parts (loop with start = 0
                      for position = (position-if #'ascii-space-p content :start start)
                      collect (subseq content start (or position (length content)))
                      while position
                      do (setf start (trim-left-index content position))
                      while (< start (length content)))))
    (cond
      ((and (= (length parts) 2) (string= (first parts) "%YAML"))
       ;; Bun's reference parser accepts other syntactically valid YAML
       ;; versions with a warning. Clun has no warning channel here, so it
       ;; parses them with the same safe schema.
       (unless (yaml-version-token-p (second parts))
         (yaml-fail parser :invalid-directive "invalid YAML version directive"
                    :line (sl-number line) :column 1 :offset (sl-offset line)))
       (when (gethash "%YAML" (yp-tag-handles parser))
         (yaml-fail parser :duplicate-directive "duplicate %YAML directive"
                    :line (sl-number line) :column 1 :offset (sl-offset line)))
       (setf (gethash "%YAML" (yp-tag-handles parser)) t))
      ((and (= (length parts) 3) (string= (first parts) "%TAG"))
       (let ((handle (second parts)) (prefix (third parts)))
         (unless (and (>= (length handle) 1)
                      (char= (char handle 0) #\!)
                      (char= (char handle (1- (length handle))) #\!))
           (yaml-fail parser :invalid-directive "invalid %TAG handle"
                      :line (sl-number line) :column 1 :offset (sl-offset line)))
         (when (gethash handle (yp-declared-tag-handles parser))
           (yaml-fail parser :duplicate-directive "duplicate %TAG handle"
                      :line (sl-number line) :column 1 :offset (sl-offset line)))
         (setf (gethash handle (yp-declared-tag-handles parser)) t
               (gethash handle (yp-tag-handles parser)) prefix)))
      ((and parts (member (first parts) '("%YAML" "%TAG") :test #'string=))
       (yaml-fail parser :invalid-directive "invalid YAML directive"
                  :line (sl-number line) :column 1 :offset (sl-offset line)))
      ;; Reserved directives are intentionally ignored, as required by the
      ;; YAML grammar. Their arguments never execute or alter parser state.
      (t nil))))

(defun marker-rest (line marker)
  (let* ((text (sl-text line))
         (start (length marker))
         (comment (comment-start text start))
         (end (trim-right-index text (or comment (length text)))))
    (if (<= end start) "" (trim-ascii-space (subseq text start end)))))

(defun parse-one-document (parser)
  (reset-document-state parser)
  (let ((had-directive nil))
    (loop while (< (yp-index parser) (length (yp-lines parser)))
          for line = (aref (yp-lines parser) (yp-index parser))
          while (directive-line-p parser line)
          do (setf had-directive t)
             (parse-directive parser line)
             (incf (yp-index parser)))
    (when had-directive
      (unless (and (< (yp-index parser) (length (yp-lines parser)))
                   (marker-line-p parser
                                  (aref (yp-lines parser) (yp-index parser)) "---"))
        (yaml-fail parser :directive-boundary
                   "directives must be followed by a document start marker")))
    (let ((inline-start nil) (inline-line nil))
      (when (and (< (yp-index parser) (length (yp-lines parser)))
                 (marker-line-p parser
                                (aref (yp-lines parser) (yp-index parser)) "---"))
        (setf inline-line (aref (yp-lines parser) (yp-index parser))
              inline-start (marker-rest inline-line "---"))
        (unless (zerop (length inline-start))
          ;; The line itself is consumed by gather-inline-lines.
          (return-from parse-one-document
            (parse-value-from-current parser inline-start 0
                                      (sl-number inline-line) 5
                                      (+ (sl-offset inline-line) 4) 0
                                      :allow-same-indent t
                                      :allow-same-indent-plain t)))
        (incf (yp-index parser)))
      (skip-ignorable-lines parser)
      (if (or (>= (yp-index parser) (length (yp-lines parser)))
              (document-boundary-p parser))
          (checked-node parser :null nil
                        (if inline-line (sl-number inline-line) 1) 1
                        (if inline-line (sl-offset inline-line) 0)
                        :style :plain)
          (let* ((line (aref (yp-lines parser) (yp-index parser)))
                 (indent (line-indentation parser line)))
            (parse-block-node parser indent 0))))))

(defun invalid-yaml-source-index (source)
  (let ((index 0) (length (length source)))
    (loop while (< index length) do
      (let ((code (char-code (char source index))))
        (cond
          ((or (member code '(#x09 #x0a #x0d))
               (<= #x20 code #x7e)
               (= code #x85)
               (<= #xa0 code #xd7ff)
               (<= #xe000 code #xfffd)
               (<= #x10000 code #x10ffff))
           (incf index))
          ((<= #xd800 code #xdbff)
           (if (and (< (1+ index) length)
                    (<= #xdc00 (char-code (char source (1+ index))) #xdfff))
               (incf index 2)
               (return index)))
          (t (return index)))))))

(defun parse-yaml (source)
  "Parse SOURCE into a bounded YAML-STREAM graph."
  (unless (stringp source)
    (error 'type-error :datum source :expected-type 'string))
  (when (> (length source) +max-source-length+)
    (error 'yaml-error :code :source-limit :reason "YAML source length limit exceeded"
           :line 1 :column 1 :offset 0 :document 0))
  (let ((invalid (invalid-yaml-source-index source)))
    (when invalid
      (error 'yaml-error :code :control-character
             :reason "non-printable character is not allowed in a YAML stream"
             :line 1 :column (1+ invalid) :offset invalid :document 0)))
  (let* ((parser (make-yaml-parser :source source :lines (split-source-lines source)))
         (documents (make-array 2 :adjustable t :fill-pointer 0)))
    (skip-ignorable-lines parser)
    (if (>= (yp-index parser) (length (yp-lines parser)))
        (vector-push-extend (checked-node parser :null nil 1 1 0 :style :plain)
                            documents)
        (loop
          (when (>= (length documents) +max-documents+)
            (yaml-fail parser :document-limit "YAML document limit exceeded"))
          (setf (yp-document parser) (length documents))
          (vector-push-extend (parse-one-document parser) documents)
          (skip-ignorable-lines parser)
          (when (and (< (yp-index parser) (length (yp-lines parser)))
                     (marker-line-p parser
                                    (aref (yp-lines parser) (yp-index parser)) "..."))
            (incf (yp-index parser))
            (skip-ignorable-lines parser))
          (cond
            ((>= (yp-index parser) (length (yp-lines parser))) (return))
            ((marker-line-p parser
                            (aref (yp-lines parser) (yp-index parser)) "---"))
            (t
             (let ((line (aref (yp-lines parser) (yp-index parser))))
               (yaml-fail parser :trailing-content
                          "unexpected content after YAML document"
                          :line (sl-number line) :column 1 :offset (sl-offset line)))))))
    (make-yaml-stream :documents (coerce documents 'vector))))
