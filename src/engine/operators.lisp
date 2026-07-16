;;;; operators.lisp — JS operator abstract operations (PLAN.md Phase 03, §7.2/§13).
;;;; Built on the Phase 01 coercions and the object kernel; called by the emitter.

(in-package :clun.engine)

;;; --- typeof (§13.5.3) -------------------------------------------------------

(defun js-typeof (v)
  (typecase v
    (double-float "number")
    (integer "bigint")
    (string "string")
    (js-symbol "symbol")
    (js-object (if (callable-p v) "function" "object"))
    (t (cond ((js-undefined-p v) "undefined")
             ((js-null-p v) "object")
             ((js-boolean-p v) "boolean")
             (t "object")))))

;;; --- addition (§13.15.3) ----------------------------------------------------

(defun js-add (l r)
  ;; §13.15.3 (+): ToPrimitive BOTH first (for the string-concat check), then ToNumeric both.
  (let ((lp (to-primitive l)) (rp (to-primitive r)))
    (cond ((or (stringp lp) (stringp rp))
           (concatenate 'string (to-string lp) (to-string rp)))
          (t (numeric-binary lp rp #'+ #'+)))))

;;; --- numeric binary ops -----------------------------------------------------

(defun numeric-binary (l r bigint-fn float-fn)
  "§6.1.6: FULLY ToNumeric(L) then FULLY ToNumeric(R) — the throwing side is observable
(a Symbol lhs must TypeError before the rhs is coerced). Then both BigInt → BIGINT-FN,
both Number → FLOAT-FN (trap-masked), or a mix → TypeError."
  (let* ((lp (to-numeric l))            ; ToNumeric(L) in full, incl. a Symbol→TypeError
         (rp (to-numeric r)))           ; then ToNumeric(R) in full
    (cond ((and (integerp lp) (integerp rp)) (funcall bigint-fn lp rp))
          ((or (integerp lp) (integerp rp))
           (throw-type-error "Cannot mix BigInt and other types, use explicit conversions"))
          (t (with-js-floats (funcall float-fn lp rp))))))

(defmacro def-numeric-op (name bigint-op float-op)
  ;; -,*: NOT +, so ToNumeric each operand in order (no ToPrimitive-both-first).
  `(defun ,name (l r) (numeric-binary l r ,bigint-op ,float-op)))
(def-numeric-op js-sub #'- #'-)
(def-numeric-op js-mul #'* #'*)

(defun js-div (l r)
  (numeric-binary l r
                  (lambda (a b) (if (zerop b) (throw-range-error "Division by zero") (truncate a b)))
                  #'/))

(defun js-mod (l r)
  (numeric-binary l r
                  (lambda (a b) (if (zerop b) (throw-range-error "Division by zero") (rem a b)))
                  (lambda (x y)
                    (cond ((or (js-nan-p x) (js-nan-p y) (js-infinite-p x) (zerop y)) *js-nan*)
                          ((js-infinite-p y) x)
                          ((zerop x) x)
                          (t (rem x y))))))

(defun js-exp (l r)
  (numeric-binary l r
                  (lambda (a b)
                    (cond ((minusp b) (throw-range-error "Exponent must be non-negative"))
                          ;; bound the result bit length (~b·log2|a|) before the expt DoS.
                          ((and (> (abs a) 1) (> (* (integer-length a) b) +max-bigint-bits+))
                           (throw-range-error "Maximum BigInt size exceeded"))
                          (t (expt a b))))
                  (lambda (base exp)
                    (cond ((js-nan-p exp) *js-nan*)
                          ((zerop exp) 1d0)
                          ((and (minusp base) (js-finite-p base) (js-finite-p exp)
                                (/= exp (fround exp))) *js-nan*)   ; negative base, non-integer exp
                          (t (let ((res (expt base exp)))
                               (if (complexp res) *js-nan* (coerce res 'double-float))))))))

;;; --- bitwise & shift (via ToInt32/ToUint32, Phase 01) ----------------------

;; BigInt bitwise: CL integer ops are arbitrary-precision + two's-complement-consistent for
;; negatives, so logand/logior/logxor/lognot/ash match the spec directly. Mixed → TypeError.
(defun bitwise-binary (l r bigint-fn int32-fn)
  (let ((lp (to-numeric l)) (rp (to-numeric r)))
    (cond ((and (integerp lp) (integerp rp)) (funcall bigint-fn lp rp))
          ((or (integerp lp) (integerp rp))
           (throw-type-error "Cannot mix BigInt and other types, use explicit conversions"))
          (t (%int32->double (funcall int32-fn (double->int32 lp) (double->int32 rp)))))))

(defun js-bit-and (l r) (bitwise-binary l r #'logand #'logand))
(defun js-bit-or  (l r) (bitwise-binary l r #'logior #'logior))
(defun js-bit-xor (l r) (bitwise-binary l r #'logxor #'logxor))
(defun js-bit-not (v)
  (let ((p (to-numeric v)))
    (if (integerp p) (lognot p) (%int32->double (lognot (double->int32 p))))))

(defconstant +max-bigint-bits+ (expt 2 27)
  "Cap on a BigInt result's bit length (~16 MB) — a larger op throws a catchable RangeError
rather than letting a tiny source expression heap-exhaust the runtime. Shared by <<, **,
and BigInt.asIntN/asUintN.")

(defun %bigint-shift (a n)                     ; n>0 = left, n<0 = right; bound the result size
  (when (> (abs n) +max-bigint-bits+) (throw-range-error "Maximum BigInt size exceeded"))
  (ash a n))

(defun js-shl (l r)
  (let ((lp (to-numeric l)) (rp (to-numeric r)))
    (cond ((and (integerp lp) (integerp rp)) (%bigint-shift lp rp))
          ((or (integerp lp) (integerp rp))
           (throw-type-error "Cannot mix BigInt and other types, use explicit conversions"))
          (t (%int32->double (%to-int32 (ash (double->int32 lp) (logand (double->uint32 rp) 31))))))))
(defun js-shr (l r)
  (let ((lp (to-numeric l)) (rp (to-numeric r)))
    (cond ((and (integerp lp) (integerp rp)) (%bigint-shift lp (- rp)))
          ((or (integerp lp) (integerp rp))
           (throw-type-error "Cannot mix BigInt and other types, use explicit conversions"))
          (t (%int32->double (ash (double->int32 lp) (- (logand (double->uint32 rp) 31))))))))
(defun js-ushr (l r)                           ; >>> is a TypeError for BigInt (§6.1.6.2.11)
  (let ((lp (to-numeric l)) (rp (to-numeric r)))
    (if (or (integerp lp) (integerp rp))
        (throw-type-error "BigInts have no unsigned right shift, use >> instead")
        (coerce (ash (double->uint32 lp) (- (logand (double->uint32 rp) 31))) 'double-float))))

(defun %int32->double (i) (coerce i 'double-float))
(defun %to-int32 (i)
  (let ((m (ldb (byte 32 0) i))) (if (>= m #x80000000) (- m #x100000000) m)))

;;; --- unary minus/plus -------------------------------------------------------

(defun js-neg (v)
  (let ((p (to-numeric v))) (if (integerp p) (- p) (with-js-floats (- p)))))
(defun js-unary-plus (v)                        ; §13.5.4: +bigint is a TypeError (the asymmetry)
  ;; ToPrimitive ONCE (a double valueOf/@@toPrimitive is observable — order-of-eval tests).
  (let ((p (to-primitive v :number)))
    (if (js-bigint-p p)
        (throw-type-error "Cannot convert a BigInt value to a number")
        (to-number p))))

;;; --- equality (§7.2.15/16) --------------------------------------------------

(defun js-strict-eq (x y)
  (let ((tx (js-type x)) (ty (js-type y)))
    (if (not (eq tx ty))
        nil
        (case tx
          (:number (and (not (js-nan-p x)) (not (js-nan-p y)) (= x y)))
          (:bigint (= x y))
          (:string (string= x y))
          ((:undefined :null) t)
          (:boolean (eq x y))
          (:symbol (eq x y))
          (:object (eq x y))
          (t (eq x y))))))

(defun js-loose-eq (x y)
  (let ((tx (js-type x)) (ty (js-type y)))
    (cond
      ((eq tx ty) (js-strict-eq x y))
      ((or (and (eq tx :null) (eq ty :undefined)) (and (eq tx :undefined) (eq ty :null))) t)
      ((and (eq tx :number) (eq ty :string)) (js-loose-eq x (to-number y)))
      ((and (eq tx :string) (eq ty :number)) (js-loose-eq (to-number x) y))
      ((eq tx :boolean) (js-loose-eq (to-number x) y))
      ((eq ty :boolean) (js-loose-eq x (to-number y)))
      ;; §7.2.15: BigInt == Number is MATHEMATICAL equality (1n == 1 → true), not auto-false;
      ;; BigInt == String parses the string to a BigInt (false on parse failure).
      ((and (eq tx :bigint) (eq ty :number)) (%bigint-number-eq x y))
      ((and (eq tx :number) (eq ty :bigint)) (%bigint-number-eq y x))
      ((and (eq tx :bigint) (eq ty :string)) (let ((b (%string->bigint y))) (and b (= x b))))
      ((and (eq tx :string) (eq ty :bigint)) (let ((b (%string->bigint x))) (and b (= b y))))
      ((and (member tx '(:number :string :symbol :bigint)) (eq ty :object))
       (js-loose-eq x (to-primitive y)))
      ((and (eq tx :object) (member ty '(:number :string :symbol :bigint)))
       (js-loose-eq (to-primitive x) y))
      (t nil))))

(defun %bigint-number-eq (b d)
  "BigInt == Number: equal iff the double is a finite integer mathematically equal to B."
  (and (not (js-nan-p d)) (js-finite-p d) (= b (rational d))))

;;; --- relational (§7.2.13) ---------------------------------------------------

(defun %exactify (x) (if (and (floatp x) (js-finite-p x)) (rational x) x))
(defun %numeric-lt (a b)
  "a<b for ToNumeric values (each integer or double); T/NIL/:undefined(NaN). Mixed
BigInt/Number compare EXACTLY (rationalize finite doubles so 2^53+1n vs a double is right)."
  (flet ((nan (v) (and (floatp v) (js-nan-p v))))
    (cond ((or (nan a) (nan b)) :undefined)
          ((and (integerp a) (integerp b)) (< a b))
          (t (< (%exactify a) (%exactify b))))))

(defun %abstract-lt (x y left-first)
  "Abstract Relational Comparison x < y. Returns T, NIL, or :undefined (NaN)."
  (multiple-value-bind (px py)
      (if left-first
          (let ((a (to-primitive x :number))) (values a (to-primitive y :number)))
          (let ((b (to-primitive y :number))) (values (to-primitive x :number) b)))
    (cond
      ((and (stringp px) (stringp py)) (string< px py))          ; code-unit lexicographic
      ((and (js-bigint-p px) (stringp py))
       (let ((b (%string->bigint py))) (if b (%numeric-lt px b) :undefined)))
      ((and (stringp px) (js-bigint-p py))
       (let ((b (%string->bigint px))) (if b (%numeric-lt b py) :undefined)))
      (t (%numeric-lt (to-numeric px) (to-numeric py))))))

(defun js-lt (x y) (let ((r (%abstract-lt x y t))) (if (eq r :undefined) nil (and r t))))
(defun js-gt (x y) (let ((r (%abstract-lt y x nil))) (if (eq r :undefined) nil (and r t))))
(defun js-le (x y) (let ((r (%abstract-lt y x nil))) (if (or (eq r :undefined) r) nil t)))
(defun js-ge (x y) (let ((r (%abstract-lt x y t))) (if (or (eq r :undefined) r) nil t)))

;;; --- instanceof / in --------------------------------------------------------

(defvar *well-known-symbols* (make-hash-table :test 'eq)
  "Realm-independent registry of @@ symbols (has-instance, iterator, to-primitive…).")

(defun js-instanceof (v c)
  (unless (js-object-p c) (throw-type-error "right-hand side of 'instanceof' is not an object"))
  (let ((has-inst (get-method c (gethash :has-instance *well-known-symbols*))))
    (if (js-undefined-p has-inst)
        (progn
          (unless (callable-p c)
            (throw-type-error "right-hand side of 'instanceof' is not callable"))
          (ordinary-has-instance c v))
        (js-truthy (js-call has-inst c (list v))))))

(defun ordinary-has-instance (c o)
  (cond
    ((not (callable-p c)) nil)
    ((js-bound-function-p c)
     ;; Bound-function delegation uses InstanceofOperator, not a direct
     ;; OrdinaryHasInstance recursion: the target's own @@hasInstance must be
     ;; observed (and another bound target must delegate in the same way).
     (js-instanceof o (js-bound-function-target c)))
    ((not (js-object-p o)) nil)
    (t
     (let ((proto (js-get c "prototype")))
       (unless (js-object-p proto) (throw-type-error "prototype is not an object"))
       (loop for obj = (jm-get-prototype-of o) then (jm-get-prototype-of obj)
             while (js-object-p obj)
             when (eq obj proto) do (return t)
             finally (return nil))))))

(defun js-in (key obj)
  (unless (js-object-p obj) (throw-type-error "'in' operand is not an object"))
  (has-property obj (to-property-key key)))
