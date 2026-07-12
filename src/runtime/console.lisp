;;;; console.lisp — console.* + the util.format core (PLAN.md §3.6, Phase 08).
;;;; log/info/debug/dir → stdout; warn/error/trace → stderr. Format specifiers
;;;; %s %d %i %f %j %o %O %c %%. Bun-faithful; the inspector does the value work.

(in-package :clun.runtime)

(defun render-arg (v colors)
  "Top-level console arg: a string prints RAW; anything else via the inspector."
  (if (stringp v) v (eng:inspect-value v :colors colors)))

(defun %fmt-number (v int)
  "%d/%i (INT t) or %f (INT nil): Node coerces with Number(); a Symbol → NaN. Runs
OUTSIDE the engine float-trap mask, so NaN/Infinity are checked bitwise (never `=`)."
  (if (eng:js-symbol-p v)
      "NaN"
      (let ((n (eng:to-number v)))
        (cond ((eng:js-nan-p n) "NaN")
              ((eng:js-infinite-p n) (eng:to-string n))  ; Infinity/-Infinity
              (int (princ-to-string (truncate n)))
              (t (eng:to-string n))))))

(defun %fmt-json (v)
  (handler-case
      (let ((sfn (eng:js-get (eng:intrinsic :json) "stringify")))
        (let ((r (eng:js-call sfn eng:+undefined+ (list v))))
          (if (eng:js-undefined-p r) "undefined" (eng:to-string r))))
    (eng:js-condition () "[Circular]")
    (error () "[Circular]")))

(defun apply-format (fmt args colors)
  "Process FMT's %-specifiers, consuming from ARGS. Return (values string leftover)."
  (let ((rest args))
    (values
     (with-output-to-string (o)
       (let ((i 0) (n (length fmt)))
         (loop while (< i n) do
           (let ((c (char fmt i)))
             (if (and (char= c #\%) (< (1+ i) n))
                 (let ((spec (char fmt (1+ i))))
                   (case spec
                     (#\% (write-char #\% o) (incf i 2))
                     ((#\s #\d #\i #\f #\j #\o #\O #\c)
                      (if (and (member spec '(#\c)) rest)
                          (progn (pop rest) (incf i 2))          ; %c consumes, emits nothing
                          (if rest
                              (let ((a (pop rest)))
                                (write-string
                                 (ecase spec
                                   (#\s (cond ((stringp a) a)
                                              ((or (eng:js-object-p a) (eng:js-symbol-p a))
                                               (eng:inspect-value a :colors colors))
                                              (t (eng:to-string a))))
                                   ((#\d #\i) (%fmt-number a t))
                                   (#\f (%fmt-number a nil))
                                   (#\j (%fmt-json a))
                                   ((#\o #\O) (eng:inspect-value a :colors colors))
                                   (#\c ""))
                                 o)
                                (incf i 2))
                              ;; no arg left: leave the specifier literal
                              (progn (write-char c o) (incf i)))))
                     (t (write-char c o) (incf i))))
                 (progn (write-char c o) (incf i)))))))
     rest)))

(defun format-log-args (args &key colors)
  "The util.format core: format ARGS (a list of js-values) into one line."
  (if (and args (stringp (first args)))
      (multiple-value-bind (str rest) (apply-format (first args) (rest args) colors)
        (with-output-to-string (o)
          (write-string str o)
          (dolist (a rest) (write-char #\Space o) (write-string (render-arg a colors) o))))
      (format nil "~{~a~^ ~}" (mapcar (lambda (a) (render-arg a colors)) args))))

(defun %write-line-to (stream text)
  (write-string text stream)
  (write-char #\Newline stream)
  (finish-output stream))

(defun install-console (realm rt)
  (let* ((eng:*realm* realm)
         (console (eng:new-object))
         (counts (make-hash-table :test 'equal))
         (group-depth 0))
    (labels ((colors () (runtime-colors rt))
             (indent () (make-string (* 2 group-depth) :initial-element #\Space))
             (emit (stream args)
               (%write-line-to stream
                               (let ((body (format-log-args args :colors (colors))))
                                 (if (plusp group-depth)
                                     (concatenate 'string (indent) body) body))))
             (out (args) (unless (runtime-silent rt) (emit *standard-output* args)))
             (err (args) (emit *error-output* args)))
      (macrolet ((m (name arity fn) `(eng:install-method console ,name ,arity ,fn)))
        (m "log"   0 (lambda (this a) (declare (ignore this)) (out a) eng:+undefined+))
        (m "info"  0 (lambda (this a) (declare (ignore this)) (out a) eng:+undefined+))
        (m "debug" 0 (lambda (this a) (declare (ignore this)) (out a) eng:+undefined+))
        (m "dir"   0 (lambda (this a) (declare (ignore this))
                       (unless (runtime-silent rt)
                         (%write-line-to *standard-output* (eng:inspect-value (eng:arg a 0) :colors (colors))))
                       eng:+undefined+))
        (m "warn"  0 (lambda (this a) (declare (ignore this)) (err a) eng:+undefined+))
        (m "error" 0 (lambda (this a) (declare (ignore this)) (err a) eng:+undefined+))
        (m "trace" 0 (lambda (this a) (declare (ignore this))
                       (%write-line-to *error-output*
                                       (concatenate 'string "Trace: " (format-log-args a :colors (colors))))
                       eng:+undefined+))
        (m "assert" 0 (lambda (this a) (declare (ignore this))
                        (unless (eng:js-truthy (eng:arg a 0))
                          (%write-line-to *error-output*
                                          (concatenate 'string "Assertion failed"
                                                       (if (rest a)
                                                           (concatenate 'string ": " (format-log-args (rest a) :colors (colors)))
                                                           ""))))
                        eng:+undefined+))
        (m "count" 1 (lambda (this a) (declare (ignore this))
                       (let ((label (if a (eng:to-string (eng:arg a 0)) "default")))
                         (incf (gethash label counts 0))
                         (out (list (format nil "~a: ~a" label (gethash label counts)))))
                       eng:+undefined+))
        (m "countReset" 1 (lambda (this a) (declare (ignore this))
                            (remhash (if a (eng:to-string (eng:arg a 0)) "default") counts)
                            eng:+undefined+))
        (m "group" 0 (lambda (this a) (declare (ignore this))
                       (when a (out a)) (incf group-depth) eng:+undefined+))
        (m "groupCollapsed" 0 (lambda (this a) (declare (ignore this))
                                (when a (out a)) (incf group-depth) eng:+undefined+))
        (m "groupEnd" 0 (lambda (this a) (declare (ignore this a))
                          (when (plusp group-depth) (decf group-depth)) eng:+undefined+)))
      (eng:hidden-prop (eng:realm-global realm) "console" console)
      console)))
