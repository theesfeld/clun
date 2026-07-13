;;;; querystring.lisp — node:querystring (legacy API).
;;;; Pure string percent-encoding/decoding; UTF-8 via CL char-code (code points
;;;; encoded per UTF-8; decode is lenient and reconstructs code points).

(in-package :clun.runtime)

(defun %qs-unreserved-p (c)
  "escape() leaves these unescaped: A-Z a-z 0-9 - _ . ! ~ * ' ( )."
  (or (char<= #\A c #\Z) (char<= #\a c #\z) (char<= #\0 c #\9)
      (member c '(#\- #\_ #\. #\! #\~ #\* #\' #\( #\)) :test #'char=)))

(defun %utf8-bytes (code)
  "Encode a code point integer as a list of UTF-8 byte integers."
  (cond
    ((< code #x80) (list code))
    ((< code #x800)
     (list (logior #xC0 (ash code -6)) (logior #x80 (logand code #x3F))))
    ((< code #x10000)
     (list (logior #xE0 (ash code -12)) (logior #x80 (logand (ash code -6) #x3F))
           (logior #x80 (logand code #x3F))))
    (t (list (logior #xF0 (ash code -18)) (logior #x80 (logand (ash code -12) #x3F))
             (logior #x80 (logand (ash code -6) #x3F)) (logior #x80 (logand code #x3F))))))

(defun %qs-escape (str)
  "Percent-encode UTF-8 of STR, leaving unreserved characters untouched."
  (let ((out (make-string-output-stream)))
    (loop for c across str do
      (if (%qs-unreserved-p c)
          (write-char c out)
          (dolist (b (%utf8-bytes (char-code c)))
            (format out "%~2,'0X" b))))
    (get-output-stream-string out)))

(defun %hex-digit (c)
  "Value of a hex digit char, or NIL if not a hex digit."
  (cond ((char<= #\0 c #\9) (- (char-code c) (char-code #\0)))
        ((char<= #\a c #\f) (+ 10 (- (char-code c) (char-code #\a))))
        ((char<= #\A c #\F) (+ 10 (- (char-code c) (char-code #\A))))
        (t nil)))

(defun %utf8-decode (bytes)
  "Decode a list of UTF-8 byte integers into a CL string (lenient)."
  (let ((out (make-string-output-stream)) (v bytes))
    (loop while v do
      (let ((b (pop v)))
        (cond
          ((< b #x80) (write-char (code-char b) out))
          ((and (>= b #xF0) (>= (length v) 3))
           (let ((cp (logior (ash (logand b #x07) 18) (ash (logand (pop v) #x3F) 12)
                             (ash (logand (pop v) #x3F) 6) (logand (pop v) #x3F))))
             (write-char (code-char cp) out)))
          ((and (>= b #xE0) (>= (length v) 2))
           (let ((cp (logior (ash (logand b #x0F) 12) (ash (logand (pop v) #x3F) 6)
                             (logand (pop v) #x3F))))
             (write-char (code-char cp) out)))
          ((and (>= b #xC0) (>= (length v) 1))
           (let ((cp (logior (ash (logand b #x1F) 6) (logand (pop v) #x3F))))
             (write-char (code-char cp) out)))
          (t (write-char (code-char b) out)))))
    (get-output-stream-string out)))

(defun %qs-unescape (str)
  "Decode %XX escapes (UTF-8) in STR; '+' is preserved literally."
  (let ((bytes '()) (n (length str)) (i 0))
    (loop while (< i n) do
      (let ((c (char str i)))
        (if (and (char= c #\%) (< (+ i 2) n)
                 (%hex-digit (char str (1+ i))) (%hex-digit (char str (+ i 2))))
            (progn
              (push (+ (* 16 (%hex-digit (char str (1+ i)))) (%hex-digit (char str (+ i 2)))) bytes)
              (incf i 3))
            (progn
              (dolist (b (%utf8-bytes (char-code c))) (push b bytes))
              (incf i)))))
    (%utf8-decode (nreverse bytes))))

(defun %qs-decode-component (str)
  "parse-side decode: '+' becomes space, then %XX UTF-8 decode."
  (%qs-unescape (substitute #\Space #\+ str)))

(defun %qs-primitive (v)
  "Node stringifyPrimitive: string/bigint -> text, finite number -> text, boolean ->
true/false, everything else (null/undefined/object/symbol/NaN/Infinity) -> \"\"."
  (cond ((eng:js-string-p v) v)
        ((eng:js-bigint-p v) (eng:to-string v))
        ((eng:js-number-p v)
         (let ((n (eng:to-number v)))          ; nonfinite -> "" (bitwise NaN/Inf check, no =)
           (if (or (eng:js-nan-p n) (eng:js-infinite-p n)) "" (eng:to-string v))))
        ((eq v eng:+true+) "true")
        ((eq v eng:+false+) "false")
        (t "")))

(defun %qs-value->list (v)
  "Array value -> element list; otherwise a single stringified value."
  (if (eng:js-array-p v)
      (mapcar #'%qs-primitive (eng:array-like->list v))
      (list (%qs-primitive v))))

(defun %qs-stringify (obj sep eq)
  "key=value pairs joined by SEP; array values repeat the key. Keys/values escaped."
  (when (or (eng:js-nullish-p obj) (not (eng:js-object-p obj))) (return-from %qs-stringify ""))
  (let ((parts '()))
    (dolist (key (eng:jm-own-property-keys obj))
      (when (stringp key)
        (let ((desc (eng:obj-own-desc obj key)))
          (when (and desc (eng:pd-enumerable desc))
            (let ((ek (%qs-escape key)))
              (dolist (val (%qs-value->list (eng:js-get obj key)))
                (push (concatenate 'string ek eq (%qs-escape val)) parts)))))))
    (setf parts (nreverse parts))
    (if (null parts) ""
        (with-output-to-string (out)
          (loop for p in parts for first = t then nil
                do (unless first (write-string sep out)) (write-string p out))))))

(defun %qs-parse (str sep eq)
  "Decoded key->value object; repeated key -> JS array. Empty string -> empty object."
  ;; null-prototype result (Node) + OWN-property lookup, so a key like "toString" or
  ;; "constructor" neither inherits nor collides with Object.prototype (§ prototype-safety).
  (let ((o (eng:new-object eng:+null+)))
    (when (string= str "") (return-from %qs-parse o))
    (dolist (pair (%split str (char sep 0)))
      (unless (string= pair "")
        (let* ((idx (search eq pair))
               (rawk (if idx (subseq pair 0 idx) pair))
               (rawv (if idx (subseq pair (+ idx (length eq))) ""))
               (k (%qs-decode-component rawk))
               (v (%qs-decode-component rawv))
               (desc (eng:obj-own-desc o k))
               (existing (and desc (eng:pd-value desc))))
          (cond
            ((null desc) (eng:data-prop o k v))
            ((eng:js-array-p existing)
             (eng:js-call (eng:js-get existing "push") existing (list v)))
            (t (eng:data-prop o k (eng:new-array (list existing v))))))))
    o))

(defun build-node-querystring ()
  (let ((o (eng:new-object)))
    (labels ((m (name arity fn) (eng:install-method o name arity fn)))
      (let ((stringify (lambda (this args) (declare (ignore this))
                         (let ((sep (a args 1)) (eq (a args 2)))
                           (%qs-stringify (a args 0)
                                          (if (undef-p sep) "&" (->str sep))
                                          (if (undef-p eq) "=" (->str eq))))))
            (parse (lambda (this args) (declare (ignore this))
                     (let ((sep (a args 1)) (eq (a args 2)))
                       (%qs-parse (->str (a args 0))
                                  (if (undef-p sep) "&" (->str sep))
                                  (if (undef-p eq) "=" (->str eq)))))))
        (m "escape" 1 (lambda (this args) (declare (ignore this)) (%qs-escape (->str (a args 0)))))
        (m "unescape" 1 (lambda (this args) (declare (ignore this)) (%qs-unescape (->str (a args 0)))))
        (m "stringify" 3 stringify)
        (m "encode" 3 stringify)
        (m "parse" 3 parse)
        (m "decode" 3 parse))
      o)))

(register-node-builtin "querystring" #'build-node-querystring)
