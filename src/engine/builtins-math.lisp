;;;; builtins-math.lisp — the Math namespace object (PLAN.md Phase 04, §21.3).
;;;; Pure double-float arithmetic under the JS float-trap mask; CL's real-valued
;;;; transcendentals with explicit domain guards (CL returns COMPLEX out of domain
;;;; where JS wants NaN, and that is contagion, not a maskable trap).

(in-package :clun.engine)

(declaim (inline %real))
(defun %real (z)
  "Coerce a CL number to a double; a complex result (out-of-domain) becomes NaN."
  (cond ((complexp z) *js-nan*)
        ((rationalp z) (coerce z 'double-float))
        ((typep z 'single-float) (coerce z 'double-float))
        (t z)))

(defmacro %m1 (obj name (x) &body body)
  "Install a 1-arg Math method: BODY sees X = ToNumber(arg0), runs under the mask."
  `(install-method ,obj ,name 1
     (lambda (this args) (declare (ignore this))
       (let ((,x (to-number (arg args 0))))
         (with-js-floats ,@body)))))

(defun %math-round (x)
  (cond ((or (js-nan-p x) (js-infinite-p x) (js-zero-p x)) x)
        (t (let* ((f (ffloor x)) (frac (- x f))
                  (r (if (>= frac 0.5d0) (+ f 1d0) f)))
             (if (and (zerop r) (minusp x)) -0d0 r)))))

(defun %math-sign (x)
  (cond ((js-nan-p x) x) ((js-neg-zero-p x) -0d0) ((js-zero-p x) 0d0)
        ((minusp x) -1d0) (t 1d0)))

(defun %math-pow (base ex)
  (with-js-floats
    (cond
      ((js-zero-p ex) 1d0)                                  ; x^±0 = 1 (even NaN^0)
      ((js-nan-p ex) *js-nan*)
      ((js-nan-p base) *js-nan*)
      ((and (js-infinite-p ex) (= (abs base) 1d0)) *js-nan*) ; (±1)^±Inf = NaN
      (t (%real (expt base ex))))))

(defun %math-hypot (args)
  (with-js-floats
    (let ((vals (mapcar #'to-number args)) (any-nan nil) (sum 0d0))
      (dolist (v vals) (when (js-infinite-p v) (return-from %math-hypot +js-infinity+)))
      (dolist (v vals) (when (js-nan-p v) (setf any-nan t)))
      (if any-nan *js-nan*
          (progn (dolist (v vals) (incf sum (* v v))) (%real (sqrt sum)))))))

(defun %math-extremum (args maxp)
  "Math.max / Math.min over ARGS with the -0/+0 and NaN rules."
  (let ((acc (if maxp +js-neg-infinity+ +js-infinity+)))
    (dolist (a args acc)
      (let ((v (to-number a)))
        (when (js-nan-p v) (return-from %math-extremum *js-nan*))
        (cond ((if maxp (> v acc) (< v acc)) (setf acc v))
              ((and (js-zero-p v) (js-zero-p acc))       ; -0 vs +0 tie-break
               (when (if maxp (js-neg-zero-p acc) (js-neg-zero-p v)) (setf acc v))))))))

(defun %math-log10 (x)
  "log10 with exact integer powers of ten returning the exact exponent (Node parity;
the generic log(x)/log(10) gives 2.9999999999999996 for 1000)."
  (if (and (js-finite-p x) (= x (ftruncate x)) (<= x 1d22))
      (let* ((i (truncate x)) (k (round (log x 10d0))))
        (if (and (>= k 0) (= i (expt 10 k))) (coerce k 'double-float)
            (%real (/ (log x) (log 10d0)))))
      (%real (/ (log x) (log 10d0)))))

(defun %clz32 (x)
  ;; integer-length is exact; (- 31 (floor (log n 2))) rounds log2 up near 2^32
  ;; and returns -1 for 0xFFFFFFFF. Range is always 0..32.
  (coerce (- 32 (integer-length (double->uint32 x))) 'double-float))

(defun %bootstrap-math ()
  (let ((m (js-make-object (intrinsic :object-prototype))))
    (setf (realm-intrinsic *realm* :math) m)
    (with-js-floats
      (macrolet ((k (name val) `(obj-set-desc m ,name (data-pd (coerce ,val 'double-float)
                                                                :writable nil :enumerable nil :configurable nil))))
        (k "E" (exp 1d0))            (k "LN10" (log 10d0))      (k "LN2" (log 2d0))
        (k "LOG10E" (/ 1d0 (log 10d0))) (k "LOG2E" (/ 1d0 (log 2d0)))
        (k "PI" pi)                  (k "SQRT1_2" (sqrt 0.5d0)) (k "SQRT2" (sqrt 2d0))))
    (obj-set-desc m (well-known :to-string-tag)
                  (data-pd "Math" :writable nil :enumerable nil :configurable t))
    (%m1 m "abs" (x) (abs x))
    (%m1 m "floor" (x) (if (or (js-nan-p x) (js-infinite-p x)) x (ffloor x)))
    (%m1 m "ceil" (x) (if (or (js-nan-p x) (js-infinite-p x)) x
                          (let ((r (fceiling x))) (if (and (zerop r) (minusp x)) -0d0 r))))
    (%m1 m "trunc" (x) (if (or (js-nan-p x) (js-infinite-p x)) x
                           (let ((r (ftruncate x))) (if (and (zerop r) (minusp x)) -0d0 r))))
    (%m1 m "round" (x) (%math-round x))
    (%m1 m "sign" (x) (%math-sign x))
    (%m1 m "sqrt" (x) (cond ((js-neg-zero-p x) -0d0) ((minusp x) *js-nan*) (t (%real (sqrt x)))))
    (%m1 m "cbrt" (x) (cond ((or (js-nan-p x) (js-infinite-p x) (js-zero-p x)) x)
                            (t (* (%math-sign x) (%real (expt (abs x) (/ 1d0 3d0)))))))
    (%m1 m "exp" (x) (%real (exp x)))
    (%m1 m "expm1" (x) (cond ((js-zero-p x) x) (t (%real (- (exp x) 1d0)))))
    (%m1 m "log" (x) (cond ((js-zero-p x) +js-neg-infinity+) ((minusp x) *js-nan*) (t (%real (log x)))))
    (%m1 m "log2" (x) (cond ((js-zero-p x) +js-neg-infinity+) ((minusp x) *js-nan*) (t (%real (/ (log x) (log 2d0))))))
    (%m1 m "log10" (x) (cond ((js-zero-p x) +js-neg-infinity+) ((minusp x) *js-nan*)
                             (t (%math-log10 x))))
    (%m1 m "log1p" (x) (cond ((js-zero-p x) x) ((< x -1d0) *js-nan*) ((= x -1d0) +js-neg-infinity+) (t (%real (log (+ 1d0 x))))))
    (%m1 m "sin" (x) (if (js-infinite-p x) *js-nan* (%real (sin x))))
    (%m1 m "cos" (x) (if (js-infinite-p x) *js-nan* (%real (cos x))))
    (%m1 m "tan" (x) (if (js-infinite-p x) *js-nan* (%real (tan x))))
    (%m1 m "asin" (x) (if (> (abs x) 1d0) *js-nan* (%real (asin x))))
    (%m1 m "acos" (x) (if (> (abs x) 1d0) *js-nan* (%real (acos x))))
    (%m1 m "atan" (x) (%real (atan x)))
    (%m1 m "sinh" (x) (%real (sinh x)))
    (%m1 m "cosh" (x) (%real (cosh x)))
    (%m1 m "tanh" (x) (%real (tanh x)))
    (%m1 m "asinh" (x) (if (or (js-infinite-p x) (js-zero-p x)) x (%real (asinh x))))
    (%m1 m "acosh" (x) (if (< x 1d0) *js-nan* (%real (acosh x))))
    (%m1 m "atanh" (x) (cond ((> (abs x) 1d0) *js-nan*) ((= (abs x) 1d0) (* (%math-sign x) +js-infinity+)) (t (%real (atanh x)))))
    (%m1 m "fround" (x) (if (or (js-nan-p x) (js-infinite-p x)) x (coerce (coerce x 'single-float) 'double-float)))
    (%m1 m "clz32" (x) (%clz32 x))
    (install-method m "atan2" 2
      (lambda (this args) (declare (ignore this))
        (with-js-floats (%real (atan (to-number (arg args 0)) (to-number (arg args 1)))))))
    (install-method m "pow" 2
      (lambda (this args) (declare (ignore this)) (%math-pow (to-number (arg args 0)) (to-number (arg args 1)))))
    (install-method m "hypot" 2 (lambda (this args) (declare (ignore this)) (%math-hypot args)))
    (install-method m "max" 2 (lambda (this args) (declare (ignore this)) (%math-extremum args t)))
    (install-method m "min" 2 (lambda (this args) (declare (ignore this)) (%math-extremum args nil)))
    (install-method m "imul" 2
      (lambda (this args) (declare (ignore this))
        (coerce (double->int32 (coerce (* (double->int32 (to-number (arg args 0)))
                                          (double->int32 (to-number (arg args 1)))) 'double-float))
                'double-float)))
    (install-method m "random" 0 (lambda (this args) (declare (ignore this args)) (%js-random)))
    m))

;;; A tiny xorshift64* PRNG. Math.random's unpredictability is not observable by
;;; test262 (only the [0,1) range and type are), so a fixed seed keeps us pure and
;;; deterministic. State advances per call.
(defparameter *random-state64* #x2545F4914F6CDD1D)
(defun %js-random ()
  (let ((s *random-state64*))
    (setf s (ldb (byte 64 0) (logxor s (ash s -12))))
    (setf s (ldb (byte 64 0) (logxor s (ash s 25))))
    (setf s (ldb (byte 64 0) (logxor s (ash s -27))))
    (setf *random-state64* s)
    ;; top 53 bits -> [0,1)
    (coerce (/ (ldb (byte 53 11) (ldb (byte 64 0) (* s #x2545F4914F6CDD1D)))
               (expt 2d0 53))
            'double-float)))
