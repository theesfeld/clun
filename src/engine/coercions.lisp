;;;; coercions.lisp — ECMA-262 §7.1 abstract operations (PLAN.md Phase 01).
;;;; ToPrimitive/ToBoolean/ToNumber/ToString/ToInt32/ToUint32. Object conversion
;;;; routes through *ordinary-to-primitive*, installed once the object kernel and
;;;; valueOf/toString exist (Phase 03/04); Phase 01 inputs are all primitive.

(in-package :clun.engine)

(defvar *ordinary-to-primitive* nil
  "Phase 03/04 installs (lambda (object hint) -> primitive) here (OrdinaryToPrimitive).")

(defun to-primitive (input &optional (hint :default))
  "§7.1.1. HINT is :default, :number, or :string."
  (if (js-object-p input)
      (if *ordinary-to-primitive*
          (funcall *ordinary-to-primitive* input hint)
          (error "ToPrimitive on an object before the object kernel exists (Phase 03)"))
      input))

(defun js-truthy (v)
  "The CL-boolean core of ToBoolean (§7.1.2) — used directly by control flow."
  (typecase v
    (double-float (not (or (js-nan-p v) (zerop v))))
    (string (plusp (length v)))
    (js-object t)
    (t (eq v +true+))))                    ; of the singletons only +true+ is truthy

(defun to-boolean (v)
  "§7.1.2 -> a JS boolean value."
  (js-boolean (js-truthy v)))

(defun to-number (v)
  "§7.1.4 -> a double-float."
  (typecase v
    (double-float v)
    (string (js-string->number v))
    (js-object (to-number (to-primitive v :number)))
    (t (cond ((js-undefined-p v) *js-nan*)
             ((js-null-p v) 0d0)
             ((eq v +true+) 1d0)
             ((eq v +false+) 0d0)
             (t (throw-type-error (format nil "cannot convert ~s to a number" v)))))))

(defun to-string (v)
  "§7.1.17 -> a CL string (UTF-16 code units)."
  (typecase v
    (string v)
    (double-float (number->js-string v))
    (js-object (to-string (to-primitive v :string)))
    (t (cond ((js-undefined-p v) "undefined")
             ((js-null-p v) "null")
             ((eq v +true+) "true")
             ((eq v +false+) "false")
             (t (throw-type-error (format nil "cannot convert ~s to a string" v)))))))

(defun to-int32 (v)  "§7.1.6."  (double->int32 (to-number v)))
(defun to-uint32 (v) "§7.1.7."  (double->uint32 (to-number v)))

(defun to-integer-or-infinity (v)
  "§7.1.5 -> a double-float integer value (or ±Infinity). NaN -> +0."
  (let ((n (to-number v)))
    (cond ((js-nan-p n) 0d0)
          ((js-infinite-p n) n)
          ((js-zero-p n) 0d0)
          (t (ftruncate n)))))

(defconstant +max-safe-length+ (1- (expt 2 53)))

(defun to-length (v)
  "§7.1.20 -> a non-negative CL integer clamped to [0, 2^53-1]."
  (let ((n (to-integer-or-infinity v)))
    (cond ((<= n 0d0) 0)
          ((js-infinite-p n) +max-safe-length+)
          (t (min (floor n) +max-safe-length+)))))

(defun to-index (v)
  "§7.1.22 -> a CL integer in [0, 2^53-1], else RangeError."
  (if (js-undefined-p v) 0
      (let ((n (to-integer-or-infinity v)))
        (when (or (< n 0d0) (> n +max-safe-length+) (js-infinite-p n))
          (throw-range-error "invalid index"))
        (floor n))))

(defun require-object-coercible (v)
  "§7.2.1 — throw if V is nullish, else return V."
  (if (js-nullish-p v)
      (throw-type-error "cannot convert undefined or null to object")
      v))

(defun length-of-array-like (o)
  "§7.3.18 LengthOfArrayLike — ToLength of O.length."
  (to-length (js-getv o "length")))

(defun %int (v)
  "ToIntegerOrInfinity of V as a CL integer, mapping ±Infinity to fixnum bounds so
it can be clamped/compared. Never traps (unlike (floor/truncate) on NaN/Infinity),
which matters because most builtins run outside the JS float-trap mask."
  (let ((n (to-integer-or-infinity v)))
    (if (js-infinite-p n) (if (plusp n) most-positive-fixnum most-negative-fixnum) (truncate n))))
