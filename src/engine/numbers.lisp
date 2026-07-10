;;;; numbers.lisp — doubles, trap masking, NaN/Inf/-0, Int32/Uint32, and the
;;;; Number<->String conversions (PLAN.md Phase 01, §3.1). Number->String uses
;;;; exact-rational shortest-round-trip (the plan's named Ryū fallback; Phase 04
;;;; swaps in Ryū for speed). String->Number implements StrNumericLiteral (§7.1.4.1).

(in-package :clun.engine)

;;; --- Float trap discipline (Appendix C fact 4) -----------------------------

(defmacro with-js-floats (&body body)
  "Mask the float traps JS semantics require (Inf/NaN/-0 instead of signals)."
  `(sb-int:with-float-traps-masked (:overflow :invalid :divide-by-zero)
     ,@body))

(defconstant +js-infinity+      sb-ext:double-float-positive-infinity)
(defconstant +js-neg-infinity+  sb-ext:double-float-negative-infinity)

;; A special var keeps (- inf inf) from constant-folding at COMPILE time (which
;; traps, outside the runtime mask — Appendix C fact 4); load-time eval under the
;; mask then yields a real quiet NaN.
(defparameter *nan-seed* +js-infinity+)
(defparameter *js-nan*
  (with-js-floats (- *nan-seed* *nan-seed*))
  "The canonical quiet NaN. Not a defconstant: NaN is not eql to itself.")

(declaim (inline js-nan-p js-infinite-p js-finite-p js-neg-zero-p js-zero-p))
(defun js-nan-p (x)      (and (typep x 'double-float) (sb-ext:float-nan-p x)))
(defun js-infinite-p (x) (and (typep x 'double-float) (sb-ext:float-infinity-p x)))
(defun js-finite-p (x)   (and (typep x 'double-float) (not (sb-ext:float-nan-p x))
                              (not (sb-ext:float-infinity-p x))))
(defun js-neg-zero-p (x) (eql x -0d0))          ; (eql -0d0 0d0) => NIL
(defun js-zero-p (x)     (and (typep x 'double-float) (zerop x)))  ; +0 or -0

;;; --- ToInt32 / ToUint32 numeric core (§7.1.6 / §7.1.7) ---------------------
;;; These take an already-ToNumber'd double; coercions.lisp adds the ToNumber step.

(defun double->int32 (d)
  (if (or (js-nan-p d) (js-infinite-p d))
      0
      (let ((m (ldb (byte 32 0) (truncate d))))   ; truncate = toward zero
        (if (>= m #x80000000) (- m #x100000000) m))))

(defun double->uint32 (d)
  (if (or (js-nan-p d) (js-infinite-p d))
      0
      (ldb (byte 32 0) (truncate d))))

;;; --- Number -> String (§6.1.6.1.20) ----------------------------------------

(defun %floor-log10 (r)
  "floor(log10 R) exactly for positive rational R."
  (let ((est (with-js-floats (floor (log (coerce r 'double-float) 10d0)))))
    (loop while (>= r (expt 10 (1+ est))) do (incf est))
    (loop while (< r (expt 10 est)) do (decf est))
    est))

(defun %round-to-k (r e10 k)
  "Round positive rational R (with floor-log10 = E10) to K significant digits.
Returns (values s n): integer S has K digits, value = S * 10^(N-K)."
  (let* ((scale-exp (- (1+ e10) k))                 ; n-k, n = e10+1
         (s (round (* r (expt 10 (- scale-exp))))))  ; CL round = ties-to-even
    (when (>= s (expt 10 k))                          ; rollover, e.g. 9.99 -> 10.0
      (setf s (round s 10))
      (incf scale-exp))
    (values s (+ k scale-exp))))

(defun %shortest-digits (x)
  "For positive finite double X: (values digit-string k n), shortest round-trip."
  (with-js-floats
    (let* ((r (rational x))
           (e10 (%floor-log10 r)))
      (loop for k from 1 to 17 do
        (multiple-value-bind (s n) (%round-to-k r e10 k)
          (when (= (coerce (* s (expt 10 (- n k))) 'double-float) x)
            (return-from %shortest-digits (values (format nil "~d" s) k n)))))
      ;; 17 digits always round-trip a double; defensive fallthrough
      (multiple-value-bind (s n) (%round-to-k r e10 17)
        (values (format nil "~d" s) 17 n)))))

(defun %format-decimal (digits k n)
  "ECMA-262 §6.1.6.1.20 steps 6-10 given the K digit string DIGITS and position N."
  (cond
    ((<= k n 21)                                     ; step 6
     (concatenate 'string digits (make-string (- n k) :initial-element #\0)))
    ((< 0 n 22)                                      ; step 7 (n < k here)
     (concatenate 'string (subseq digits 0 n) "." (subseq digits n)))
    ((< -6 n 1)                                      ; step 8 (-6 < n <= 0)
     (concatenate 'string "0." (make-string (- n) :initial-element #\0) digits))
    (t                                               ; steps 9-10: exponential
     (let ((mantissa (if (= k 1)
                         digits
                         (concatenate 'string (subseq digits 0 1) "." (subseq digits 1))))
           (exp (1- n)))
       (format nil "~ae~a~d" mantissa (if (>= exp 0) "+" "-") (abs exp))))))

(defun number->js-string (x)
  "ToString applied to a JS number X (double-float)."
  (cond
    ((js-nan-p x) "NaN")
    ((js-zero-p x) "0")                              ; +0 and -0 both -> "0"
    ((minusp x) (concatenate 'string "-" (number->js-string (- x))))
    ((eql x +js-infinity+) "Infinity")
    (t (multiple-value-bind (digits k n) (%shortest-digits x)
         (%format-decimal digits k n)))))

;;; --- String -> Number (§7.1.4.1 StrNumericLiteral) -------------------------

(defparameter *js-whitespace-codes*
  ;; WhiteSpace + LineTerminator + <USP> (category Zs).
  '(#x09 #x0A #x0B #x0C #x0D #x20 #xA0 #x1680
    #x2000 #x2001 #x2002 #x2003 #x2004 #x2005 #x2006 #x2007 #x2008 #x2009 #x200A
    #x2028 #x2029 #x202F #x205F #x3000 #xFEFF))

(declaim (inline %js-whitespace-p))
(defun %js-whitespace-p (ch)
  (and (member (char-code ch) *js-whitespace-codes*) t))

(defun %trim-js-whitespace (s)
  (let ((start 0) (end (length s)))
    (loop while (and (< start end) (%js-whitespace-p (char s start))) do (incf start))
    (loop while (and (< start end) (%js-whitespace-p (char s (1- end)))) do (decf end))
    (subseq s start end)))

;; ECMA-262 §12.9.3: numeric literals admit ONLY ASCII digits. CL digit-char-p
;; accepts every Unicode Nd char (Arabic-Indic, Devanagari, fullwidth, ...), so we
;; must not use it here — Number("١") is NaN, not 1.
(declaim (inline %ascii-decimal-digit-p %ascii-digit))
(defun %ascii-decimal-digit-p (ch)
  (char<= #\0 ch #\9))
(defun %ascii-digit (ch radix)
  "Weight of ASCII digit CH in RADIX (2..16), or NIL. ASCII-only."
  (let ((c (char-code ch)))
    (cond
      ((<= 48 c 57) (let ((d (- c 48))) (and (< d radix) d)))                 ; 0-9
      ((<= 97 (logior c 32) 102) (let ((d (- (logior c 32) 87))) (and (< d radix) d))) ; a-f / A-F
      (t nil))))

(defun %decimal-length (n)
  "Number of decimal digits of positive integer N."
  (length (write-to-string n)))

(defun %digits-value (s start end radix)
  "Integer value of S[START,END) in RADIX, or NIL if empty/any invalid digit."
  (when (< start end)
    (let ((acc 0))
      (loop for i from start below end
            for d = (%ascii-digit (char s i) radix)
            do (if d (setf acc (+ (* acc radix) d)) (return-from %digits-value nil)))
      acc)))

(defun %parse-decimal (s)
  "Parse trimmed S as StrDecimalLiteral -> double, or :fail."
  (let ((i 0) (n (length s)) (sign 1))
    (when (zerop n) (return-from %parse-decimal :fail))
    (case (char s 0)
      (#\+ (incf i))
      (#\- (setf sign -1) (incf i)))
    (let ((int-start i) (int-end i) (frac-start nil) (frac-end nil)
          (exp-sign 1) (exp-val 0))
      (loop while (and (< i n) (%ascii-decimal-digit-p (char s i))) do (incf i))
      (setf int-end i)
      (when (and (< i n) (char= (char s i) #\.))
        (incf i) (setf frac-start i)
        (loop while (and (< i n) (%ascii-decimal-digit-p (char s i))) do (incf i))
        (setf frac-end i))
      ;; need at least one digit somewhere in the mantissa
      (when (and (= int-start int-end) (or (null frac-start) (= frac-start frac-end)))
        (return-from %parse-decimal :fail))
      (when (and (< i n) (member (char s i) '(#\e #\E)))
        (incf i)
        (case (and (< i n) (char s i))
          (#\+ (incf i))
          (#\- (setf exp-sign -1) (incf i)))
        (let ((es i))
          (loop while (and (< i n) (%ascii-decimal-digit-p (char s i))) do (incf i))
          (when (= es i) (return-from %parse-decimal :fail))   ; "1e" invalid
          (setf exp-val (%digits-value s es i 10))))
      (when (/= i n) (return-from %parse-decimal :fail))        ; trailing garbage
      (let* ((int-part (or (%digits-value s int-start int-end 10) 0))
             (frac-len (if frac-start (- frac-end frac-start) 0))
             (frac-part (if (and frac-start (> frac-end frac-start))
                            (%digits-value s frac-start frac-end 10) 0))
             (mantissa (+ (* int-part (expt 10 frac-len)) frac-part))
             (exponent (- (* exp-sign exp-val) frac-len)))
        (with-js-floats
          (if (zerop mantissa)
              (* sign 0d0)                     ; +/-0 (Number("-0") is -0)
              ;; Clamp obvious over/underflow before building a giant 10^exponent
              ;; bignum (adversarial-length guard, §6). value < 10^(digits+exponent).
              (let ((mag (+ (%decimal-length mantissa) exponent)))
                (cond
                  ((> mag 310) (* sign +js-infinity+))
                  ((<= mag -324) (* sign 0d0))
                  (t (* sign (coerce (* mantissa (expt 10 exponent)) 'double-float)))))))))))

(defun js-string->number (string)
  "StringToNumber (§7.1.4.1). Returns a double (NaN on invalid)."
  (let ((s (%trim-js-whitespace string)))
    (cond
      ((zerop (length s)) 0d0)                        ; empty (or all ws) -> +0
      ((string= s "Infinity") +js-infinity+)
      ((string= s "+Infinity") +js-infinity+)
      ((string= s "-Infinity") +js-neg-infinity+)
      ((and (>= (length s) 2) (char= (char s 0) #\0)
            (member (char s 1) '(#\x #\X #\o #\O #\b #\B)))
       (let* ((radix (ecase (char-downcase (char s 1)) (#\x 16) (#\o 8) (#\b 2)))
              (v (%digits-value s 2 (length s) radix)))
         (if v (with-js-floats (coerce v 'double-float)) *js-nan*)))
      (t (let ((v (%parse-decimal s)))
           (if (eq v :fail) *js-nan* v))))))
