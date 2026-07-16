;;;; builtins-json.lisp — the JSON object (PLAN.md Phase 04, §25.5). A hand-rolled
;;;; recursive-descent reader over UTF-16 code units (strict ECMA-404 grammar) and a
;;;; SerializeJSONProperty printer with toJSON, replacer, indentation, cycle
;;;; detection, and the exact QuoteJSONString escaping. Pure CL, no host JSON.

(in-package :clun.engine)

;;; --- JSON.parse -------------------------------------------------------------

(defstruct (json-reader (:conc-name jr-)) (str "") (pos 0) (len 0))

(defun %json-syntax (msg) (throw-syntax-error (format nil "JSON.parse: ~a" msg)))

(defun jr-peek (r) (if (< (jr-pos r) (jr-len r)) (char (jr-str r) (jr-pos r)) nil))
(defun jr-next (r)
  ;; EOF-safe: a truncated literal/escape/\u at end-of-input is a JSON SyntaxError,
  ;; not a host array-index crash (the unchecked (char …) would escape JS try/catch).
  (if (< (jr-pos r) (jr-len r))
      (prog1 (char (jr-str r) (jr-pos r)) (incf (jr-pos r)))
      (%json-syntax "unexpected end of input")))

(defun jr-skip-ws (r)
  (loop for c = (jr-peek r)
        while (and c (member c '(#\Space #\Tab #\Newline #\Return)))
        do (incf (jr-pos r))))

(defun jr-expect (r ch)
  (jr-skip-ws r)
  (if (eql (jr-peek r) ch) (incf (jr-pos r)) (%json-syntax (format nil "expected '~a'" ch))))

(defun json-parse-value (r)
  (jr-skip-ws r)
  (let ((c (jr-peek r)))
    (cond
      ((null c) (%json-syntax "unexpected end of input"))
      ((char= c #\{) (json-parse-object r))
      ((char= c #\[) (json-parse-array r))
      ((char= c #\") (json-parse-string r))
      ((or (char= c #\-) (char<= #\0 c #\9)) (json-parse-number r))
      ((char= c #\t) (json-parse-lit r "true" +true+))
      ((char= c #\f) (json-parse-lit r "false" +false+))
      ((char= c #\n) (json-parse-lit r "null" +null+))
      (t (%json-syntax (format nil "unexpected token '~a'" c))))))

(defun json-parse-lit (r word value)
  (dotimes (i (length word)) (unless (eql (jr-next r) (char word i)) (%json-syntax "invalid literal")))
  value)

(defun json-parse-object (r)
  (jr-next r)                                   ; consume {
  (let ((o (new-object)))
    (jr-skip-ws r)
    (when (eql (jr-peek r) #\}) (jr-next r) (return-from json-parse-object o))
    (loop
      (jr-skip-ws r)
      (unless (eql (jr-peek r) #\") (%json-syntax "expected string key"))
      (let ((key (json-parse-string r)))
        (jr-expect r #\:)
        (create-data-property o key (json-parse-value r)))
      (jr-skip-ws r)
      (case (jr-peek r)
        (#\, (jr-next r))
        (#\} (jr-next r) (return o))
        (t (%json-syntax "expected ',' or '}'"))))))

(defun json-parse-array (r)
  (jr-next r)                                   ; consume [
  (let ((elems '()))
    (jr-skip-ws r)
    (when (eql (jr-peek r) #\]) (jr-next r) (return-from json-parse-array (new-array '())))
    (loop
      (push (json-parse-value r) elems)
      (jr-skip-ws r)
      (case (jr-peek r)
        (#\, (jr-next r))
        (#\] (jr-next r) (return (new-array (nreverse elems))))
        (t (%json-syntax "expected ',' or ']'"))))))

(defun json-parse-string (r)
  (jr-next r)                                   ; consume opening "
  (let ((out (make-array 8 :element-type 'character :adjustable t :fill-pointer 0)))
    (loop
      (let ((c (jr-peek r)))
        (cond
          ((null c) (%json-syntax "unterminated string"))
          ((char= c #\") (jr-next r) (return (coerce out '(simple-array character (*)))))
          ((char= c #\\)
           (jr-next r)
           (let ((e (jr-next r)))
             (case e
               (#\" (vector-push-extend #\" out))
               (#\\ (vector-push-extend #\\ out))
               (#\/ (vector-push-extend #\/ out))
               (#\b (vector-push-extend (code-char 8) out))
               (#\f (vector-push-extend (code-char 12) out))
               (#\n (vector-push-extend #\Newline out))
               (#\r (vector-push-extend #\Return out))
               (#\t (vector-push-extend #\Tab out))
               (#\u (vector-push-extend (code-char (json-parse-hex4 r)) out))
               (t (%json-syntax "invalid escape")))))
          ((< (char-code c) #x20) (%json-syntax "unescaped control character"))
          (t (jr-next r) (vector-push-extend c out)))))))

(defun json-parse-hex4 (r)
  (let ((n 0))
    (dotimes (i 4 n)
      (let ((d (digit-char-p (jr-next r) 16)))
        (unless d (%json-syntax "invalid \\u escape"))
        (setf n (+ (* n 16) d))))))

(defun json-parse-number (r)
  (let ((start (jr-pos r)))
    (when (eql (jr-peek r) #\-) (jr-next r))
    (if (eql (jr-peek r) #\0) (jr-next r)
        (progn (unless (and (jr-peek r) (char<= #\1 (jr-peek r) #\9)) (%json-syntax "invalid number"))
               (loop while (and (jr-peek r) (char<= #\0 (jr-peek r) #\9)) do (jr-next r))))
    (when (eql (jr-peek r) #\.)
      (jr-next r)
      (unless (and (jr-peek r) (char<= #\0 (jr-peek r) #\9)) (%json-syntax "invalid fraction"))
      (loop while (and (jr-peek r) (char<= #\0 (jr-peek r) #\9)) do (jr-next r)))
    (when (member (jr-peek r) '(#\e #\E))
      (jr-next r)
      (when (member (jr-peek r) '(#\+ #\-)) (jr-next r))
      (unless (and (jr-peek r) (char<= #\0 (jr-peek r) #\9)) (%json-syntax "invalid exponent"))
      (loop while (and (jr-peek r) (char<= #\0 (jr-peek r) #\9)) do (jr-next r)))
    (js-string->number (subseq (jr-str r) start (jr-pos r)))))

(defun json-parse (text reviver)
  (let ((r (make-json-reader :str text :pos 0 :len (length text))))
    (let ((val (json-parse-value r)))
      (jr-skip-ws r)
      (when (< (jr-pos r) (jr-len r)) (%json-syntax "trailing characters"))
      (if (callable-p reviver)
          (let ((holder (new-object)))
            (create-data-property holder "" val)
            (json-internalize holder "" reviver))
          val))))

(defun json-internalize (holder key reviver)
  (let ((val (js-get holder key)))
    (when (js-object-p val)
      (if (is-array val)
          (let ((len (length-of-array-like val)))
            (dotimes (i len)
              (let ((new (json-internalize val (princ-to-string i) reviver)))
                (if (js-undefined-p new) (jm-delete val (princ-to-string i))
                    (create-data-property val (princ-to-string i) new)))))
          (dolist (k (enum-own-keys val :key))
            (let ((new (json-internalize val k reviver)))
              (if (js-undefined-p new) (jm-delete val k)
                  (create-data-property val k new))))))
    (js-call reviver holder (list key val))))

;;; --- JSON.stringify ---------------------------------------------------------

(defstruct (json-writer (:conc-name jw-))
  (gap "") (indent "") (replacer-fn nil) (prop-list nil) (prop-list-p nil) (stack '()))

(defun json-quote (s)
  "QuoteJSONString (§25.5.2.3), with lone-surrogate escaping (ES2019)."
  (let ((out (make-array (+ (length s) 2) :element-type 'character :adjustable t :fill-pointer 0))
        (n (length s)) (i 0))
    (vector-push-extend #\" out)
    (loop while (< i n) do
      (let* ((c (char s i)) (code (char-code c)))
        (cond
          ((char= c #\") (vector-push-extend #\\ out) (vector-push-extend #\" out))
          ((char= c #\\) (vector-push-extend #\\ out) (vector-push-extend #\\ out))
          ((= code 8)  (vector-push-extend #\\ out) (vector-push-extend #\b out))
          ((= code 12) (vector-push-extend #\\ out) (vector-push-extend #\f out))
          ((= code 10) (vector-push-extend #\\ out) (vector-push-extend #\n out))
          ((= code 13) (vector-push-extend #\\ out) (vector-push-extend #\r out))
          ((= code 9)  (vector-push-extend #\\ out) (vector-push-extend #\t out))
          ((< code #x20) (json-push-u out code))
          ((high-surrogate-p code)
           (if (and (< (1+ i) n) (low-surrogate-p (char-code (char s (1+ i)))))
               (progn (vector-push-extend c out)
                      (vector-push-extend (char s (1+ i)) out) (incf i))
               (json-push-u out code)))
          ((low-surrogate-p code) (json-push-u out code))
          (t (vector-push-extend c out))))
      (incf i))
    (vector-push-extend #\" out)
    (coerce out '(simple-array character (*)))))

(defun json-push-u (out code)
  (dolist (c (coerce (format nil "\\u~(~4,'0x~)" code) 'list)) (vector-push-extend c out)))

(defun json-serialize-property (w holder key)
  "SerializeJSONProperty -> a CL string, or NIL for undefined/function/symbol."
  (let ((value (js-getv holder key)))
    (when (js-object-p value)
      (let ((to-json (get-method value "toJSON")))
        (when (callable-p to-json) (setf value (js-call to-json value (list key))))))
    (when (jw-replacer-fn w)
      (setf value (js-call (jw-replacer-fn w) holder (list key value))))
    ;; unwrap Number/String/Boolean/BigInt wrapper objects
    (when (js-object-p value)
      (case (js-object-class value)
        (:number (setf value (to-number value)))
        (:string (setf value (to-string value)))
        (:boolean (setf value (wrapper-primitive value)))
        (:bigint (setf value (wrapper-primitive value)))))
    (cond
      ((js-null-p value) "null")
      ((eq value +true+) "true")
      ((eq value +false+) "false")
      ((stringp value) (json-quote value))
      ((js-number-p value) (if (js-finite-p value) (number->js-string value) "null"))
      ((js-bigint-p value)                        ; §25.5.2.2 step 10: BigInt is not serializable
       (throw-type-error "Do not know how to serialize a BigInt"))
      ((and (js-object-p value) (not (callable-p value)))
       (if (is-array value) (json-serialize-array w value) (json-serialize-object w value)))
      (t nil))))                                 ; undefined, function, symbol

(defun json-check-cycle (w value)
  (when (member value (jw-stack w)) (throw-type-error "Converting circular structure to JSON"))
  (push value (jw-stack w)))

(defun json-serialize-object (w o)
  (json-check-cycle w o)
  (let* ((saved (jw-indent w))
         (new-indent (concatenate 'string saved (jw-gap w)))
         (keys (if (jw-prop-list-p w) (jw-prop-list w) (enum-own-keys o :key)))
         (parts '()))
    (setf (jw-indent w) new-indent)
    (dolist (k keys)
      (let ((s (json-serialize-property w o k)))
        (when s
          (push (concatenate 'string (json-quote k) (if (string= (jw-gap w) "") ":" ": ") s) parts))))
    (setf (jw-indent w) saved)
    (pop (jw-stack w))
    (json-wrap (nreverse parts) "{" "}" saved new-indent w)))

(defun json-serialize-array (w a)
  (json-check-cycle w a)
  (let* ((saved (jw-indent w))
         (new-indent (concatenate 'string saved (jw-gap w)))
         (len (length-of-array-like a))
         (parts '()))
    (setf (jw-indent w) new-indent)
    (dotimes (i len)
      (push (or (json-serialize-property w a (princ-to-string i)) "null") parts))
    (setf (jw-indent w) saved)
    (pop (jw-stack w))
    (json-wrap (nreverse parts) "[" "]" saved new-indent w)))

(defun json-wrap (parts open close saved new-indent w)
  "Join already-ordered PARTS between OPEN/CLOSE, applying indentation."
  (cond
    ((null parts) (concatenate 'string open close))
    ((string= (jw-gap w) "")
     (format nil "~a~{~a~^,~}~a" open parts close))
    (t (with-output-to-string (out)
         (write-string open out)
         (loop for p in parts for first = t then nil
               do (write-string (if first "" ",") out)
                  (write-char #\Newline out) (write-string new-indent out) (write-string p out))
         (write-char #\Newline out) (write-string saved out) (write-string close out)))))

(defun json-stringify (value replacer space)
  (let ((w (make-json-writer)))
    ;; replacer: function or array-of-keys
    (cond
      ((callable-p replacer) (setf (jw-replacer-fn w) replacer))
      ((is-array replacer)
       (let ((seen '()) (list '()))
         (dotimes (i (length-of-array-like replacer))
           (let ((v (js-getv replacer (princ-to-string i))))
             (when (js-object-p v)
               (case (js-object-class v) ((:string :number) (setf v (to-string v)))))
             (when (or (stringp v) (js-number-p v))
               (let ((s (if (stringp v) v (number->js-string v))))
                 (unless (member s seen :test #'string=) (push s seen) (push s list))))))
         (setf (jw-prop-list w) (nreverse list) (jw-prop-list-p w) t))))
    ;; space -> gap
    (when (js-object-p space)
      (case (js-object-class space) (:number (setf space (to-number space))) (:string (setf space (to-string space)))))
    (setf (jw-gap w)
          (cond ((js-number-p space) (make-string (min 10 (max 0 (%int space))) :initial-element #\Space))
                ((stringp space) (if (> (length space) 10) (subseq space 0 10) space))
                (t "")))
    (let ((holder (new-object)))
      (create-data-property holder "" value)
      (let ((s (json-serialize-property w holder "")))
        (if s s +undefined+)))))

;;; --- bootstrap --------------------------------------------------------------

(defun %bootstrap-json ()
  (let ((j (js-make-object (intrinsic :object-prototype))))
    (setf (realm-intrinsic *realm* :json) j)
    (obj-set-desc j (well-known :to-string-tag)
                  (data-pd "JSON" :writable nil :enumerable nil :configurable t))
    (install-method j "parse" 2
      (lambda (this args) (declare (ignore this))
        (json-parse (to-string (arg args 0)) (arg args 1))))
    (install-method j "stringify" 3
      (lambda (this args) (declare (ignore this))
        (json-stringify (arg args 0) (arg args 1) (arg args 2))))
    j))
