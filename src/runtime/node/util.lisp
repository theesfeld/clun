;;;; util.lisp — node:util (PLAN.md Phase 12). format/inspect/promisify/callbackify + types.
;;;; inherits sets super_ only; the prototype chain wiring is skipped (documented gap 🟡).

(in-package :clun.runtime)

(defun %util-global (name) (eng:js-get (eng:realm-global eng:*realm*) name))

(defun %util-inspect-1 (v depth)
  (if (eng:js-string-p v) v (eng:inspect-value v :depth depth)))

(defun %util-json-stringify (v)
  "JSON.stringify(v); fall back to inspect on any throw."
  (let ((json (%util-global "JSON")))
    (handler-case
        (if (and (eng:js-object-p json))
            (let ((fn (eng:js-get json "stringify")))
              (if (eng:callable-p fn) (eng:js-call fn json (list v)) (%util-inspect-1 v 2)))
            (%util-inspect-1 v 2))
      (eng:js-condition (c) (declare (ignore c)) "[Circular]"))))   ; Node: circular -> [Circular]

(defun %util-bigint-or-symbol (v)
  "Node special-cases %d/%i/%f/%s for BigInt (-> \"<n>n\") and Symbol (-> String()); NIL else."
  (cond ((eng:js-bigint-p v) (concatenate 'string (eng:to-string v) "n"))
        ((eng:js-symbol-p v) (eng:inspect-value v))))       ; -> "Symbol(x)"

(defun %util-num->str (v)                        ; %f: Number(v), NaN stays NaN, no truncation
  (or (%util-bigint-or-symbol v) (eng:to-string (eng:to-number v))))

(defun %util-int->str (v)                        ; %d/%i: Number(v) then truncate; NaN -> "NaN"
  (or (%util-bigint-or-symbol v)
      (let ((n (eng:to-number v)))               ; runs OUTSIDE the float mask — never = on NaN
        (cond ((eng:js-nan-p n) "NaN") ((eng:js-infinite-p n) (eng:to-string n))
              (t (princ-to-string (truncate n)))))))

(defun %util-format (fmt args)
  "Node util.format core. ARGS is the list AFTER the format value."
  (if (not (eng:js-string-p fmt))
      (%util-format-join (cons fmt args))
      (let ((out (make-string-output-stream)) (rest args) (i 0) (n (length fmt)))
        (loop while (< i n) do
          (let ((ch (char fmt i)))
            (if (and (char= ch #\%) (< (1+ i) n))
                (let ((spec (char fmt (1+ i))))
                  (incf i 2)
                  (case spec
                    (#\% (write-char #\% out))
                    (#\c (when rest (pop rest)))
                    ((#\s) (if rest (write-string (%util-format-s (pop rest)) out)
                               (write-string "%s" out)))
                    ((#\d #\i) (if rest (write-string (%util-int->str (pop rest)) out)
                                   (progn (write-char #\% out) (write-char spec out))))
                    ((#\f) (if rest (write-string (%util-num->str (pop rest)) out)
                               (write-string "%f" out)))
                    ((#\j) (if rest (write-string (->str (%util-json-stringify (pop rest))) out)
                               (write-string "%j" out)))
                    ((#\o #\O) (if rest (write-string (eng:inspect-value (pop rest)) out)
                                   (progn (write-char #\% out) (write-char spec out))))
                    (t (write-char #\% out) (write-char spec out))))
                (progn (write-char ch out) (incf i)))))
        (let ((base (get-output-stream-string out)))
          (if rest
              (format nil "~a~{ ~a~}" base (mapcar #'%util-format-tail rest))
              base)))))

(defun %util-format-s (v)
  (cond ((eng:js-string-p v) v)
        ((eng:js-number-p v) (eng:to-string v))
        ((eng:js-bigint-p v) (concatenate 'string (eng:to-string v) "n"))
        ((eng:js-symbol-p v) (eng:inspect-value v))    ; "Symbol(x)" — never throw
        ((or (eng:js-null-p v) (eng:js-undefined-p v)) (eng:to-string v))
        ((eng:js-object-p v) (eng:inspect-value v :depth 2))
        (t (eng:to-string v))))

(defun %util-format-tail (v)
  (if (eng:js-string-p v) v (eng:inspect-value v :depth 2)))

(defun %util-format-join (vals)
  (format nil "~{~a~^ ~}" (mapcar #'%util-format-tail vals)))

(defun %util-strip-vt (s)
  "Remove ESC '[' ... final-letter CSI sequences."
  (let ((out (make-string-output-stream)) (i 0) (n (length s)))
    (loop while (< i n) do
      (let ((ch (char s i)))
        (if (and (= (char-code ch) 27) (< (1+ i) n) (char= (char s (1+ i)) #\[))
            (let ((j (+ i 2)))
              (loop while (and (< j n) (not (alpha-char-p (char s j)))) do (incf j))
              (setf i (if (< j n) (1+ j) j)))
            (progn (write-char ch out) (incf i)))))
    (get-output-stream-string out)))

(defun %util-promisify (fn)
  "Return a fn that invokes FN with a node (err,val) callback and returns a Promise."
  (eng:make-native-function "" 0
    (lambda (this args)
      (let ((promise-ctor (%util-global "Promise")))
        (eng:js-construct promise-ctor
          (list (eng:make-native-function "" 2
                  (lambda (ex-this ex-args)
                    (declare (ignore ex-this))
                    (let ((resolve (eng:arg ex-args 0)) (reject (eng:arg ex-args 1)))
                      (let ((cb (eng:make-native-function "" 2
                                  (lambda (cb-this cb-args)
                                    (declare (ignore cb-this))
                                    (let ((err (eng:arg cb-args 0)))
                                      (if (eng:js-truthy err)
                                          (eng:js-call reject eng:+undefined+ (list err))
                                          (eng:js-call resolve eng:+undefined+
                                                       (list (eng:arg cb-args 1)))))
                                    eng:+undefined+))))
                        (eng:js-call fn this (append args (list cb)))
                        eng:+undefined+))))))))))

(defun %util-callbackify (fn)
  "Return a fn taking args + a node callback; drives the Promise FN returns."
  (eng:make-native-function "" 0
    (lambda (this args)
      (let* ((cb (car (last args)))
             (call-args (butlast args))
             (promise (eng:js-call fn this call-args)))
        (let ((on-ok (eng:make-native-function "" 1
                       (lambda (h-this h-args) (declare (ignore h-this))
                         (eng:js-call cb eng:+undefined+
                                      (list eng:+null+ (eng:arg h-args 0)))
                         eng:+undefined+)))
              (on-err (eng:make-native-function "" 1
                        (lambda (h-this h-args) (declare (ignore h-this))
                          (eng:js-call cb eng:+undefined+ (list (eng:arg h-args 0)))
                          eng:+undefined+))))
          (if (and (eng:js-object-p promise) (eng:callable-p (eng:js-get promise "then")))
              (eng:js-call (eng:js-get promise "then") promise (list on-ok on-err))
              (eng:js-call cb eng:+undefined+ (list eng:+null+ promise)))
          eng:+undefined+)))))

(defun %util-has-then (v)
  (and (eng:js-object-p v) (eng:callable-p (eng:js-get v "then"))))

(defun %util-tag-p (v tag)
  "True when v's Symbol.toStringTag equals TAG."
  (and (eng:js-object-p v)
       (let ((s (eng:js-getv v (eng:well-known :to-string-tag))))
         (and (eng:js-string-p s) (string= s tag)))))

(defun %util-build-types ()
  (let ((o (eng:new-object)))
    (labels ((p (name pred)
               (eng:install-method o name 1
                 (lambda (this args) (declare (ignore this))
                   (eng:js-boolean (funcall pred (eng:arg args 0)))))))
      (p "isDate" (lambda (v) (and (eng:js-object-p v) (eq (eng:js-object-class v) :date))))
      (p "isRegExp" (lambda (v) (and (eng:js-object-p v)
                                     (eng:js-string-p (eng:js-getv v "source"))
                                     (eng:js-string-p (eng:js-getv v "flags")))))
      (p "isMap" (lambda (v) (%util-tag-p v "Map")))
      (p "isSet" (lambda (v) (%util-tag-p v "Set")))
      (p "isPromise" (lambda (v) (%util-has-then v)))
      (p "isTypedArray" (lambda (v) (and (eng:js-object-p v)
                                         (eng:js-number-p (eng:js-getv v "BYTES_PER_ELEMENT")))))
      (p "isAnyArrayBuffer" (lambda (v) (%util-tag-p v "ArrayBuffer"))))
    o))

(defun %util-inspect-depth (d)
  "Node depth option: null OR Infinity -> unbounded; a finite number -> truncate; else 2.
Guards (truncate Infinity), which raises a host float error."
  (cond ((eng:js-null-p d) 1000000)
        ((eng:js-number-p d)
         (let ((n (eng:to-number d)))
           (cond ((eng:js-nan-p n) 2) ((eng:js-infinite-p n) 1000000) (t (max 0 (truncate n))))))
        (t 2)))

(defun build-node-util ()
  (let ((o (eng:new-object)))
    (labels ((m (name arity fn) (eng:install-method o name arity fn)))
      (m "format" 0 (lambda (this args) (declare (ignore this))
                      (%util-format (eng:arg args 0) (cdr args))))
      (m "formatWithOptions" 0
         (lambda (this args) (declare (ignore this))
           (%util-format (eng:arg args 1) (cddr args))))
      (m "inspect" 2
         (lambda (this args) (declare (ignore this))
           (let* ((opts (eng:arg args 1))
                  (depth (%util-inspect-depth (if (eng:js-object-p opts) (eng:js-get opts "depth") (undef)))))
             (eng:inspect-value (eng:arg args 0) :depth depth))))
      (m "isDeepStrictEqual" 2
         (lambda (this args) (declare (ignore this))
           (eng:js-boolean (eng:js-deep-equal (eng:arg args 0) (eng:arg args 1)))))
      (m "promisify" 1 (lambda (this args) (declare (ignore this))
                         (%util-promisify (eng:arg args 0))))
      (m "callbackify" 1 (lambda (this args) (declare (ignore this))
                           (%util-callbackify (eng:arg args 0))))
      (m "inherits" 2
         (lambda (this args) (declare (ignore this))
           (let ((ctor (eng:arg args 0)) (super (eng:arg args 1)))
             (when (eng:js-object-p ctor) (eng:js-set ctor "super_" super nil))
             eng:+undefined+)))
      (m "deprecate" 2 (lambda (this args) (declare (ignore this))
                         (let ((fn (eng:arg args 0)))     ; a NEW wrapper (warning elided)
                           (eng:make-native-function "" 0
                             (lambda (wt wa) (eng:js-call fn wt wa))))))
      (m "stripVTControlCharacters" 1
         (lambda (this args) (declare (ignore this))
           (%util-strip-vt (->str (eng:arg args 0)))))
      (eng:data-prop o "types" (%util-build-types))
      (eng:data-prop o "TextEncoder" (%util-global "TextEncoder"))
      (eng:data-prop o "TextDecoder" (%util-global "TextDecoder"))
      o)))

(register-node-builtin "util" #'build-node-util)
