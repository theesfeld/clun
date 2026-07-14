;;;; json.lisp — a hand-rolled, engine-free JSON reader (PLAN.md §3.5). The module
;;;; resolver must read package.json without depending on the engine (§3.6), so it
;;;; can't use builtins-json.lisp. Shared with Phase 21 (lockfile). Read-only for
;;;; now (no serializer). ~250 LOC.
;;;;
;;;; Representation (chosen for the resolver): objects -> alist of (string . value)
;;;; preserving key ORDER (exports/imports condition matching is order-sensitive);
;;;; arrays -> simple-vector; strings -> string; numbers -> double-float;
;;;; true/false/null -> the sentinels json-true/json-false/json-null.

(in-package :clun.sys)

(define-condition json-error (error)
  ((message :initarg :message :reader json-error-message)
   (position :initarg :position :initform nil :reader json-error-position))
  (:report (lambda (c s)
             (format s "JSON parse error~@[ at ~a~]: ~a"
                     (json-error-position c) (json-error-message c)))))

(defvar json-null  '#:json-null  "The parsed JSON `null`.")
(defvar json-true  '#:json-true  "The parsed JSON `true`.")
(defvar json-false '#:json-false "The parsed JSON `false`.")

(defun jobject-p (x)
  "True iff X is a parsed JSON object (an alist, or the empty object NIL sentinel
is disallowed — we use :empty-object). We represent an object as a (possibly
empty) list of conses; distinguish the empty object with a wrapper."
  (or (eq x :empty-object)
      (and (consp x) (consp (car x)) (stringp (caar x)))))

(defun jget (object key &optional default)
  "Look up string KEY in a parsed JSON OBJECT (alist), returning DEFAULT if absent
or if OBJECT is not an object."
  (if (eq object :empty-object)
      default
      (let ((cell (and (consp object) (assoc key object :test #'string=))))
        (if cell (cdr cell) default))))

;;; --- the reader -------------------------------------------------------------

(defstruct (jparser (:conc-name jp-) (:constructor %make-jparser (src)))
  (src "" :type simple-string)
  (pos 0 :type fixnum))

(declaim (inline jp-peek jp-eof-p))
(defun jp-peek (p)
  (if (< (jp-pos p) (length (jp-src p))) (char (jp-src p) (jp-pos p)) nil))
(defun jp-eof-p (p) (>= (jp-pos p) (length (jp-src p))))

(defun jp-next (p)
  (prog1 (char (jp-src p) (jp-pos p)) (incf (jp-pos p))))

(defun jp-err (p fmt &rest args)
  (error 'json-error :position (jp-pos p) :message (apply #'format nil fmt args)))

(defun jp-skip-ws (p)
  ;; JSON whitespace: space, tab, newline, carriage return. (No comments — strict.)
  (loop for c = (jp-peek p)
        while (and c (member c '(#\Space #\Tab #\Newline #\Return)))
        do (incf (jp-pos p))))

(defun jp-expect (p ch)
  (if (eql (jp-peek p) ch)
      (incf (jp-pos p))
      (jp-err p "expected ~s" ch)))

(defun jp-value (p)
  (jp-skip-ws p)
  (let ((c (jp-peek p)))
    (cond ((null c) (jp-err p "unexpected end of input"))
          ((char= c #\{) (jp-object p))
          ((char= c #\[) (jp-array p))
          ((char= c #\") (jp-string p))
          ((or (char= c #\-) (digit-char-p c)) (jp-number p))
          ((char= c #\t) (jp-literal p "true" json-true))
          ((char= c #\f) (jp-literal p "false" json-false))
          ((char= c #\n) (jp-literal p "null" json-null))
          (t (jp-err p "unexpected character ~s" c)))))

(defun jp-literal (p word val)
  (dotimes (i (length word))
    (unless (eql (jp-peek p) (char word i))
      (jp-err p "invalid literal, expected ~s" word))
    (incf (jp-pos p)))
  val)

(defun jp-object (p)
  (jp-expect p #\{)
  (jp-skip-ws p)
  (when (eql (jp-peek p) #\})
    (jp-next p)
    (return-from jp-object :empty-object))
  (let ((pairs '()))
    (loop
      (jp-skip-ws p)
      (unless (eql (jp-peek p) #\")
        (jp-err p "expected string key in object"))
      (let ((key (jp-string p)))
        (jp-skip-ws p)
        (jp-expect p #\:)
        (let* ((val (jp-value p))
               ;; JSON.parse keeps the LAST value for a duplicate key, at the key's
               ;; FIRST position — update in place rather than re-ordering.
               (existing (assoc key pairs :test #'string=)))
          (if existing (setf (cdr existing) val) (push (cons key val) pairs))))
      (jp-skip-ws p)
      (case (jp-peek p)
        (#\, (jp-next p))
        (#\} (jp-next p) (return))
        (t (jp-err p "expected `,` or `}` in object"))))
    (let ((result (nreverse pairs)))
      (if result result :empty-object))))

(defun jp-array (p)
  (jp-expect p #\[)
  (jp-skip-ws p)
  (when (eql (jp-peek p) #\])
    (jp-next p)
    (return-from jp-array (vector)))
  (let ((items '()))
    (loop
      (push (jp-value p) items)
      (jp-skip-ws p)
      (case (jp-peek p)
        (#\, (jp-next p))
        (#\] (jp-next p) (return))
        (t (jp-err p "expected `,` or `]` in array"))))
    (coerce (nreverse items) 'simple-vector)))

(defun jp-hex4 (p)
  (let ((code 0))
    (dotimes (i 4)
      (let ((d (digit-char-p (or (jp-peek p) (jp-err p "bad \\u escape")) 16)))
        (unless d (jp-err p "bad \\u escape"))
        (setf code (+ (* code 16) d))
        (jp-next p)))
    code))

(defun jp-string (p)
  (jp-expect p #\")
  (let ((out (make-array 16 :element-type 'character :adjustable t :fill-pointer 0)))
    (loop
      (let ((c (or (jp-peek p) (jp-err p "unterminated string"))))
        (cond
          ((char= c #\") (jp-next p) (return))
          ((char= c #\\)
           (jp-next p)
           (let ((e (or (jp-peek p) (jp-err p "unterminated escape"))))
             (jp-next p)
             (case e
               (#\" (vector-push-extend #\" out))
               (#\\ (vector-push-extend #\\ out))
               (#\/ (vector-push-extend #\/ out))
               (#\b (vector-push-extend #\Backspace out))
               (#\f (vector-push-extend #\Page out))
               (#\n (vector-push-extend #\Newline out))
               (#\r (vector-push-extend #\Return out))
               (#\t (vector-push-extend #\Tab out))
               (#\u (let ((cp (jp-hex4 p)))
                      ;; surrogate pair -> combine; lone surrogate -> keep as-is.
                      (if (<= #xD800 cp #xDBFF)
                          (if (and (eql (jp-peek p) #\\)
                                   (progn (jp-next p) (eql (jp-peek p) #\u)))
                              (progn (jp-next p)
                                     (let ((lo (jp-hex4 p)))
                                       (vector-push-extend
                                        (code-char (+ #x10000
                                                      (ash (- cp #xD800) 10)
                                                      (- lo #xDC00)))
                                        out)))
                              (vector-push-extend (code-char cp) out))
                          (vector-push-extend (code-char cp) out))))
               (t (jp-err p "invalid escape \\~a" e)))))
          ((< (char-code c) #x20) (jp-err p "control character in string"))
          (t (vector-push-extend c out) (jp-next p)))))
    (coerce out 'simple-string)))

(defun jp-number (p)
  (let ((start (jp-pos p)))
    (when (eql (jp-peek p) #\-) (jp-next p))
    (loop while (and (jp-peek p) (digit-char-p (jp-peek p))) do (jp-next p))
    (when (eql (jp-peek p) #\.)
      (jp-next p)
      ;; JSON grammar: `frac = '.' 1*DIGIT` — at least one digit after the dot.
      (unless (and (jp-peek p) (digit-char-p (jp-peek p)))
        (jp-err p "a digit must follow the decimal point"))
      (loop while (and (jp-peek p) (digit-char-p (jp-peek p))) do (jp-next p)))
    (when (member (jp-peek p) '(#\e #\E))
      (jp-next p)
      (when (member (jp-peek p) '(#\+ #\-)) (jp-next p))
      (unless (and (jp-peek p) (digit-char-p (jp-peek p)))
        (jp-err p "a digit must follow the exponent"))
      (loop while (and (jp-peek p) (digit-char-p (jp-peek p))) do (jp-next p)))
    (let* ((str (subseq (jp-src p) start (jp-pos p)))
           (rat (json-lexeme->rational str)))
      ;; Coerce the exact value to double; a magnitude past the double range becomes
      ;; +/-Infinity (JSON.parse('1e400') === Infinity), never a parse error.
      (cond ((> rat (rational most-positive-double-float))
             sb-ext:double-float-positive-infinity)
            ((< rat (rational most-negative-double-float))
             sb-ext:double-float-negative-infinity)
            (t (coerce rat 'double-float))))))

(defun json-lexeme->rational (str)
  "Parse a validated JSON number lexeme STR into an EXACT rational (no float
overflow), so 1e400 etc. survive to be coerced to +/-Infinity by the caller."
  (let ((neg nil) (i 0) (n (length str)) (mant 0) (scale 0) (exp 0))
    (when (char= (char str 0) #\-) (setf neg t i 1))
    (loop while (and (< i n) (digit-char-p (char str i)))
          do (setf mant (+ (* mant 10) (digit-char-p (char str i)))) (incf i))
    (when (and (< i n) (char= (char str i) #\.))
      (incf i)
      (loop while (and (< i n) (digit-char-p (char str i)))
            do (setf mant (+ (* mant 10) (digit-char-p (char str i))) scale (1+ scale))
               (incf i)))
    (when (and (< i n) (member (char str i) '(#\e #\E)))
      (incf i)
      (let ((esign 1))
        (when (and (< i n) (member (char str i) '(#\+ #\-)))
          (when (char= (char str i) #\-) (setf esign -1)) (incf i))
        (loop while (and (< i n) (digit-char-p (char str i)))
              do (setf exp (+ (* exp 10) (digit-char-p (char str i)))) (incf i))
        (setf exp (* esign exp))))
    (let ((r (* mant (expt 10 (- exp scale)))))
      (if neg (- r) r))))

(defun parse-json (string)
  "Parse a JSON STRING into CL data (see file header for the representation).
Signals JSON-ERROR on malformed input."
  (let ((p (%make-jparser (coerce string 'simple-string))))
    (let ((v (jp-value p)))
      (jp-skip-ws p)
      (unless (jp-eof-p p)
        (jp-err p "trailing content after JSON value"))
      v)))

;;; --- writer (Phase 21/23: lockfile + package.json + registry write needs) ---
;;; Round-trips the reader representation back out. Objects are alists of
;;; (string . value); the empty object is :empty-object; arrays are vectors;
;;; the sentinels json-true/false/null print as their JSON literals.

(defun %json-write-string (s out)
  (write-char #\" out)
  (loop for c across s do
    (case c
      (#\" (write-string "\\\"" out))
      (#\\ (write-string "\\\\" out))
      (#\Newline (write-string "\\n" out))
      (#\Return (write-string "\\r" out))
      (#\Tab (write-string "\\t" out))
      (#\Backspace (write-string "\\b" out))
      (#\Page (write-string "\\f" out))
      (t (if (< (char-code c) #x20)
             (format out "\\u~4,'0x" (char-code c))
             (write-char c out)))))
  (write-char #\" out))

(defun %json-write-number (x out)
  "Emit X as a JSON number: an integer (or integer-valued double) prints with no decimal point."
  (cond ((integerp x) (format out "~d" x))
        ((and (typep x 'double-float) (= x (fround x)) (< (abs x) 1d15))
         (format out "~d" (round x)))
        ((rationalp x) (format out "~a" x))
        (t (write-string (substitute #\e #\d (princ-to-string x)) out))))

(defun %json-write (v out indent sort-keys depth)
  (flet ((nl (d) (when (plusp indent)
                   (write-char #\Newline out)
                   (dotimes (i (* indent d)) (write-char #\Space out)))))
    (cond
      ((eq v json-null) (write-string "null" out))
      ((eq v json-true) (write-string "true" out))
      ((eq v json-false) (write-string "false" out))
      ((eq v :empty-object) (write-string "{}" out))
      ((stringp v) (%json-write-string v out))
      ((numberp v) (%json-write-number v out))
      ((null v) (write-string "null" out))
      ((and (consp v) (consp (car v)) (stringp (caar v)))         ; object (alist)
       (let ((pairs (if sort-keys (stable-sort (copy-list v) #'string< :key #'car) v)))
         (write-char #\{ out)
         (loop for (k . val) in pairs for first = t then nil do
           (unless first (write-char #\, out))
           (nl (1+ depth))
           (%json-write-string (string k) out)
           (write-string ": " out)
           (%json-write val out indent sort-keys (1+ depth)))
         (nl depth) (write-char #\} out)))
      ((vectorp v)                                                ; array
       (if (zerop (length v))
           (write-string "[]" out)
           (progn (write-char #\[ out)
                  (loop for x across v for first = t then nil do
                    (unless first (write-char #\, out))
                    (nl (1+ depth))
                    (%json-write x out indent sort-keys (1+ depth)))
                  (nl depth) (write-char #\] out))))
      (t (error 'json-error :message (format nil "cannot serialize ~s to JSON" v))))))

(defun write-json (value &key (indent 2) sort-keys)
  "Serialize VALUE (the parse-json representation) to a JSON string. INDENT>0 pretty-prints; SORT-KEYS
emits object keys in sorted order (deterministic — for the lockfile). Trailing newline is the caller's."
  (with-output-to-string (out)
    (%json-write value out indent sort-keys 0)))
