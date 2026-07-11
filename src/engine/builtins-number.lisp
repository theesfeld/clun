;;;; builtins-number.lisp — Number.prototype numeric formatting + Number statics
;;;; (PLAN.md Phase 04, §21.1). toString(radix), toFixed, toExponential, toPrecision
;;;; via exact-rational rounding (pure, no libc). Extends the Phase 03 Number set.

(in-package :clun.engine)

(defparameter +radix-digits+ "0123456789abcdefghijklmnopqrstuvwxyz")

(defun js-parse-float (string)
  "§19.2.5 parseFloat — longest leading StrDecimalLiteral prefix, or NaN."
  (let* ((s string) (n (length s)) (i 0))
    (loop while (and (< i n) (%js-whitespace-p (char s i))) do (incf i))
    (let ((start i))
      (when (and (< i n) (member (char s i) '(#\+ #\-))) (incf i))
      ;; Infinity
      (when (and (<= (+ i 8) n) (string= s "Infinity" :start1 i :end1 (+ i 8)))
        (return-from js-parse-float (if (and (> i start) (char= (char s start) #\-)) +js-neg-infinity+ +js-infinity+)))
      (let ((any nil))
        (loop while (and (< i n) (char<= #\0 (char s i) #\9)) do (incf i) (setf any t))
        (when (and (< i n) (char= (char s i) #\.))
          (incf i)
          (loop while (and (< i n) (char<= #\0 (char s i) #\9)) do (incf i) (setf any t)))
        (unless any (return-from js-parse-float *js-nan*))
        (let ((mant-end i))
          (when (and (< i n) (member (char s i) '(#\e #\E)))
            (let ((j (1+ i)))
              (when (and (< j n) (member (char s j) '(#\+ #\-))) (incf j))
              (let ((edig nil))
                (loop while (and (< j n) (char<= #\0 (char s j) #\9)) do (incf j) (setf edig t))
                (when edig (setf mant-end j)))))
          (js-string->number (subseq s start mant-end)))))))

(defun %number-radix-string (x radix)
  "ToString of finite double X in RADIX (2..36, != 10)."
  (cond
    ((js-nan-p x) "NaN")
    ((js-zero-p x) "0")
    ((minusp x) (concatenate 'string "-" (%number-radix-string (- x) radix)))
    ((eql x +js-infinity+) "Infinity")
    (t (let* ((r (rational x))
              (int (floor r))
              (frac (- r int))
              (int-str (if (zerop int) "0"
                           (with-output-to-string (o)
                             (let ((digs '()))
                               (loop while (plusp int)
                                     do (push (char +radix-digits+ (mod int radix)) digs)
                                        (setf int (floor int radix)))
                               (map nil (lambda (c) (write-char c o)) digs))))))
         (if (zerop frac) int-str
             (with-output-to-string (o)
               (write-string int-str o) (write-char #\. o)
               (loop repeat 1100 while (plusp frac)
                     do (setf frac (* frac radix))
                        (let ((d (floor frac)))
                          (write-char (char +radix-digits+ d) o)
                          (decf frac d)))))))))

(defun %round-half-up-scaled (r scale)
  "Nearest integer to R*SCALE, ties away from zero toward +Infinity (spec's larger n)."
  (let* ((v (* r scale)) (fl (floor v)) (diff (- v fl)))
    (cond ((> diff 1/2) (1+ fl)) ((< diff 1/2) fl) (t (1+ fl)))))

(defun %number-to-fixed (x f)
  "§21.1.3.3 Number.prototype.toFixed for finite |X| < 1e21, F in [0,100]."
  (let* ((neg (minusp x)) (r (rational (abs x)))
         (n (%round-half-up-scaled r (expt 10 f)))
         (s (format nil "~d" n)))
    (when (<= (length s) f) (setf s (concatenate 'string (make-string (- (1+ f) (length s)) :initial-element #\0) s)))
    (let* ((point (- (length s) f))
           (out (if (zerop f) s (concatenate 'string (subseq s 0 point) "." (subseq s point)))))
      (if (and neg (not (every (lambda (c) (or (char= c #\0) (char= c #\.))) out)))
          (concatenate 'string "-" out) out))))

(defun %number-to-exponential (x f-arg)
  (cond
    ((js-nan-p x) "NaN")
    ((js-infinite-p x) (if (minusp x) "-Infinity" "Infinity"))
    (t (let* ((neg (minusp x))
              (fixed (not (js-undefined-p f-arg)))
              (fd (and fixed (%int f-arg))))
         (multiple-value-bind (digits n)
             (cond ((js-zero-p x)
                    (values (make-string (if fixed (1+ fd) 1) :initial-element #\0) 1))
                   (fixed (multiple-value-bind (d k nn) (%round-to-digits (abs x) (1+ fd))
                            (declare (ignore k)) (values d nn)))
                   (t (multiple-value-bind (d k nn) (%shortest-digits (abs x))
                        (declare (ignore k)) (values d nn))))
           (let* ((exp (1- n))
                  (mant (if (= (length digits) 1) digits
                            (concatenate 'string (subseq digits 0 1) "." (subseq digits 1)))))
             (format nil "~:[~;-~]~ae~:[+~;-~]~d" neg mant (minusp exp) (abs exp))))))))

(defun %round-to-digits (x k)
  "Round positive double X to K significant digits, TIES AWAY FROM ZERO (§21.1.3
toExponential/toPrecision: 'pick the larger n'): (values digit-string k n). Distinct
from %round-to-k, whose ties-to-even is correct for the Ryū shortest-digits path."
  (with-js-floats
    (let* ((r (rational x)) (e10 (%floor-log10 r))
           (scale-exp (- (1+ e10) k))
           (s (floor (+ (* r (expt 10 (- scale-exp))) 1/2))))   ; half away (r > 0)
      (when (>= s (expt 10 k)) (setf s (truncate s 10)) (incf scale-exp))
      (values (format nil "~v,'0d" k s) k (+ k scale-exp)))))

(defun %number-to-precision (x p)
  (cond ((js-nan-p x) "NaN") ((js-infinite-p x) (if (minusp x) "-Infinity" "Infinity"))
        ((js-zero-p x) (if (= p 1) "0" (concatenate 'string "0." (make-string (1- p) :initial-element #\0))))
        (t (let ((neg (minusp x)))
             (multiple-value-bind (digits k n) (%round-to-digits (abs x) p)
               (declare (ignore k))
               (let ((body (cond ((or (< n -5) (> n p))     ; exponential
                                  (let ((exp (1- n)))
                                    (format nil "~ae~:[+~;-~]~d"
                                            (if (= p 1) digits (concatenate 'string (subseq digits 0 1) "." (subseq digits 1)))
                                            (minusp exp) (abs exp))))
                                 ((= n p) digits)
                                 ((<= 1 n p) (concatenate 'string (subseq digits 0 n) "." (subseq digits n)))
                                 (t (concatenate 'string "0." (make-string (- n) :initial-element #\0) digits)))))
                 (if neg (concatenate 'string "-" body) body)))))))

(defun %bootstrap-number-extra ()
  (let ((np (intrinsic :number-prototype)) (nc (intrinsic :number-constructor)))
    (install-method np "toString" 1
      (lambda (this args)
        (let ((x (this-number this)) (radix (arg args 0)))
          (if (or (js-undefined-p radix) (= (to-integer-or-infinity radix) 10d0))
              (number->js-string x)
              (let ((r (%int radix)))
                (unless (<= 2 r 36) (throw-range-error "toString() radix must be between 2 and 36"))
                (%number-radix-string x r))))))
    (install-method np "toLocaleString" 0 (lambda (this args) (declare (ignore args)) (number->js-string (this-number this))))
    (install-method np "toFixed" 1
      (lambda (this args)
        (let ((x (this-number this)) (f (%int (arg args 0))))
          (unless (<= 0 f 100) (throw-range-error "toFixed() digits argument must be between 0 and 100"))
          (cond ((js-nan-p x) "NaN") ((js-infinite-p x) (if (minusp x) "-Infinity" "Infinity"))
                ((>= (abs x) 1d21) (number->js-string x))
                (t (%number-to-fixed x f))))))
    (install-method np "toExponential" 1
      (lambda (this args)
        (let ((f (arg args 0)))
          (unless (js-undefined-p f)
            (let ((fi (%int f))) (unless (<= 0 fi 100) (throw-range-error "toExponential() argument must be between 0 and 100"))))
          (%number-to-exponential (this-number this) f))))
    (install-method np "toPrecision" 1
      (lambda (this args)
        (let ((p (arg args 0)) (x (this-number this)))
          (if (js-undefined-p p) (number->js-string x)
              (let ((pr (%int p)))
                (unless (<= 1 pr 100) (throw-range-error "toPrecision() argument must be between 1 and 100"))
                (if (or (js-nan-p x) (js-infinite-p x)) (%number-to-exponential x +undefined+)
                    (%number-to-precision x pr)))))))
    ;; statics
    (hidden-prop nc "MAX_VALUE" most-positive-double-float)
    (hidden-prop nc "MIN_VALUE" least-positive-double-float)
    (install-method nc "isSafeInteger" 1
      (lambda (this args) (declare (ignore this))
        (let ((v (arg args 0)))
          (js-boolean (and (js-number-p v) (js-finite-p v) (= v (ftruncate v)) (<= (abs v) 9007199254740991d0))))))
    (install-method nc "parseFloat" 1
      (lambda (this args) (declare (ignore this)) (js-parse-float (to-string (arg args 0)))))
    (install-method nc "parseInt" 2
      (lambda (this args) (declare (ignore this)) (js-parse-int (to-string (arg args 0)) (arg args 1))))))
