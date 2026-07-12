;;;; builtins-bigint.lisp — the BigInt constructor, prototype, and statics
;;;; (PLAN.md Phase 11, §21.2). BigInt values are plain CL integers (values.lisp);
;;;; this file adds the reflective surface: BigInt(), toString(radix), asIntN/asUintN.

(in-package :clun.engine)

(defun this-bigint (this)
  (cond ((js-bigint-p this) this)
        ((and (js-object-p this) (eq (js-object-class this) :bigint)) (wrapper-primitive this))
        (t (throw-type-error "not a BigInt"))))

(defun %number-to-bigint (n)
  "NumberToBigInt (§21.2.1.1.1): a finite integral double → its integer; else RangeError."
  (if (and (js-number-p n) (js-finite-p n) (not (js-nan-p n)) (= n (ftruncate n)))
      (truncate n)
      (throw-range-error "The number is not a safe integer and cannot be converted to a BigInt")))

(defun %bigint-from-value (v)
  "BigInt(value) (§21.2.1.1): a Number goes through NumberToBigInt, else ToBigInt."
  (let ((p (to-primitive v :number)))
    (if (js-number-p p) (%number-to-bigint p) (to-bigint p))))

(defun %bootstrap-bigint ()
  (let ((bp (make-wrapper-prototype :bigint-prototype :bigint 0)))
    (install-method bp "valueOf" 0 (lambda (this args) (declare (ignore args)) (this-bigint this)))
    (install-method bp "toString" 0
      (lambda (this args)
        (let ((n (this-bigint this))
              (r (if (js-undefined-p (arg args 0)) 10 (%int (arg args 0)))))
          (when (or (< r 2) (> r 36))
            (throw-range-error "toString() radix must be between 2 and 36"))
          (if (= r 10) (format nil "~d" n) (string-downcase (format nil "~vR" r n))))))
    (install-method bp "toLocaleString" 0
      (lambda (this args) (declare (ignore args)) (format nil "~d" (this-bigint this))))
    (obj-set-desc bp (well-known :to-string-tag)
                  (data-pd "BigInt" :writable nil :enumerable nil :configurable t))
    (let ((c (make-constructor "BigInt" 1
               (lambda (this args) (declare (ignore this)) (%bigint-from-value (arg args 0)))
               :prototype bp)))          ; no construct-fn → `new BigInt()` throws TypeError
      (install-method c "asUintN" 2
        (lambda (this args) (declare (ignore this))
          (let ((bits (to-index (arg args 0))) (v (to-bigint (arg args 1))))
            (when (> bits +max-bigint-bits+) (throw-range-error "BigInt width too large"))
            (ldb (byte bits 0) v))))
      (install-method c "asIntN" 2
        (lambda (this args) (declare (ignore this))
          (let ((bits (to-index (arg args 0))) (v (to-bigint (arg args 1))))
            (when (> bits +max-bigint-bits+) (throw-range-error "BigInt width too large"))
            (let ((u (ldb (byte bits 0) v)))
              (if (and (plusp bits) (>= u (ash 1 (1- bits)))) (- u (ash 1 bits)) u)))))
      (setf (realm-intrinsic *realm* :bigint-constructor) c))
    bp))
