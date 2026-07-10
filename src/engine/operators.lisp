;;;; operators.lisp — JS operator abstract operations (PLAN.md Phase 03, §7.2/§13).
;;;; Built on the Phase 01 coercions and the object kernel; called by the emitter.

(in-package :clun.engine)

;;; --- typeof (§13.5.3) -------------------------------------------------------

(defun js-typeof (v)
  (typecase v
    (double-float "number")
    (string "string")
    (js-symbol "symbol")
    (js-object (if (callable-p v) "function" "object"))
    (t (cond ((js-undefined-p v) "undefined")
             ((js-null-p v) "object")
             ((js-boolean-p v) "boolean")
             (t "object")))))

;;; --- addition (§13.15.3) ----------------------------------------------------

(defun js-add (l r)
  (let ((lp (to-primitive l)) (rp (to-primitive r)))
    (if (or (stringp lp) (stringp rp))
        (concatenate 'string (to-string lp) (to-string rp))
        (with-js-floats (+ (to-number lp) (to-number rp))))))

;;; --- numeric binary ops -----------------------------------------------------

(defmacro def-numeric-op (name op)
  `(defun ,name (l r) (with-js-floats (,op (to-number l) (to-number r)))))
(def-numeric-op js-sub -)
(def-numeric-op js-mul *)

(defun js-div (l r) (with-js-floats (/ (to-number l) (to-number r))))

(defun js-mod (l r)
  (with-js-floats
    (let ((x (to-number l)) (y (to-number r)))
      (cond ((or (js-nan-p x) (js-nan-p y) (js-infinite-p x) (zerop y)) *js-nan*)
            ((js-infinite-p y) x)
            ((zerop x) x)
            (t (rem x y))))))

(defun js-exp (l r)
  (with-js-floats
    (let ((base (to-number l)) (exp (to-number r)))
      (cond ((js-nan-p exp) *js-nan*)
            ((zerop exp) 1d0)
            ((and (minusp base) (js-finite-p base) (js-finite-p exp)
                  (/= exp (fround exp))) *js-nan*)   ; negative base, non-integer exp
            (t (let ((res (expt base exp)))
                 (if (complexp res) *js-nan* (coerce res 'double-float))))))))

;;; --- bitwise & shift (via ToInt32/ToUint32, Phase 01) ----------------------

(defun js-bit-and (l r) (%int32->double (logand (to-int32 l) (to-int32 r))))
(defun js-bit-or  (l r) (%int32->double (logior (to-int32 l) (to-int32 r))))
(defun js-bit-xor (l r) (%int32->double (logxor (to-int32 l) (to-int32 r))))
(defun js-bit-not (v)   (%int32->double (lognot (to-int32 v))))
(defun js-shl (l r) (%int32->double (%to-int32 (ash (to-int32 l) (logand (to-uint32 r) 31)))))
(defun js-shr (l r) (%int32->double (ash (to-int32 l) (- (logand (to-uint32 r) 31)))))
(defun js-ushr (l r) (coerce (ash (to-uint32 l) (- (logand (to-uint32 r) 31))) 'double-float))

(defun %int32->double (i) (coerce i 'double-float))
(defun %to-int32 (i)
  (let ((m (ldb (byte 32 0) i))) (if (>= m #x80000000) (- m #x100000000) m)))

;;; --- unary minus/plus -------------------------------------------------------

(defun js-neg (v) (with-js-floats (- (to-number v))))
(defun js-unary-plus (v) (to-number v))

;;; --- equality (§7.2.15/16) --------------------------------------------------

(defun js-strict-eq (x y)
  (let ((tx (js-type x)) (ty (js-type y)))
    (if (not (eq tx ty))
        nil
        (case tx
          (:number (and (not (js-nan-p x)) (not (js-nan-p y)) (= x y)))
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
      ((and (member tx '(:number :string :symbol :bigint)) (eq ty :object))
       (js-loose-eq x (to-primitive y)))
      ((and (eq tx :object) (member ty '(:number :string :symbol :bigint)))
       (js-loose-eq (to-primitive x) y))
      (t nil))))

;;; --- relational (§7.2.13) ---------------------------------------------------

(defun %abstract-lt (x y left-first)
  "Abstract Relational Comparison x < y. Returns T, NIL, or :undefined (NaN)."
  (multiple-value-bind (px py)
      (if left-first
          (let ((a (to-primitive x :number))) (values a (to-primitive y :number)))
          (let ((b (to-primitive y :number))) (values (to-primitive x :number) b)))
    (if (and (stringp px) (stringp py))
        (string< px py)                        ; code-unit lexicographic (T/NIL)
        (let ((nx (to-number px)) (ny (to-number py)))
          (cond ((or (js-nan-p nx) (js-nan-p ny)) :undefined)
                (t (< nx ny)))))))

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
        (ordinary-has-instance c v)
        (js-truthy (js-call has-inst c (list v))))))

(defun ordinary-has-instance (c o)
  (unless (callable-p c) (throw-type-error "right-hand side of 'instanceof' is not callable"))
  (if (not (js-object-p o))
      nil
      (let ((proto (js-get c "prototype")))
        (unless (js-object-p proto) (throw-type-error "prototype is not an object"))
        (loop for obj = (jm-get-prototype-of o) then (jm-get-prototype-of obj)
              while (js-object-p obj)
              when (eq obj proto) do (return t)
              finally (return nil)))))

(defun js-in (key obj)
  (unless (js-object-p obj) (throw-type-error "'in' operand is not an object"))
  (has-property obj (to-property-key key)))
