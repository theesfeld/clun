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
    (integer (not (zerop v)))              ; BigInt: 0n is falsy
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
    (integer (throw-type-error "Cannot convert a BigInt value to a number"))
    (string (js-string->number v))
    (js-object (to-number (to-primitive v :number)))
    (t (cond ((js-undefined-p v) *js-nan*)
             ((js-null-p v) 0d0)
             ((eq v +true+) 1d0)
             ((eq v +false+) 0d0)
             (t (throw-type-error (format nil "cannot convert ~s to a number" v)))))))

(defun to-numeric (v)
  "§7.1.3 ToNumeric — ToPrimitive(:number) then a Number (double) or a BigInt (integer)."
  (let ((p (to-primitive v :number)))
    (if (integerp p) p (to-number p))))

(defun to-string (v)
  "§7.1.17 -> a CL string (UTF-16 code units)."
  (typecase v
    (string v)
    (double-float (number->js-string v))
    (integer (format nil "~d" v))          ; BigInt → decimal, no `n` suffix
    (js-object (to-string (to-primitive v :string)))
    (t (cond ((js-undefined-p v) "undefined")
             ((js-null-p v) "null")
             ((eq v +true+) "true")
             ((eq v +false+) "false")
             (t (throw-type-error (format nil "cannot convert ~s to a string" v)))))))

;;; --- BigInt coercions (§7.1.13/14) ------------------------------------------

(defun %string->bigint (s)
  "StringToBigInt (§7.1.14): a CL integer, or NIL on parse failure. Whitespace-only → 0.
Accepts a signed decimal or an unsigned 0x/0o/0b literal (no sign on non-decimal)."
  (let* ((str (%trim-js-whitespace s)) (len (length str)))
    (cond
      ((zerop len) 0)
      ((and (>= len 2) (char= (char str 0) #\0) (find (char-downcase (char str 1)) "xob"))
       (let ((radix (ecase (char-downcase (char str 1)) (#\x 16) (#\o 8) (#\b 2)))
             (digits (subseq str 2)))
         (and (plusp (length digits))
              (every (lambda (c) (digit-char-p c radix)) digits)
              (parse-integer digits :radix radix :junk-allowed nil))))
      (t (let* ((neg (char= (char str 0) #\-))
                (body (if (or neg (char= (char str 0) #\+)) (subseq str 1) str)))
           (and (plusp (length body))
                (every (lambda (c) (digit-char-p c 10)) body)
                (let ((n (parse-integer body :radix 10))) (if neg (- n) n))))))))

(defun to-bigint (v)
  "§7.1.13 ToBigInt — a CL integer. Number → TypeError; bad string → SyntaxError."
  (let ((p (to-primitive v :number)))
    (typecase p
      (integer p)
      (string (or (%string->bigint p)
                  (throw-syntax-error "Cannot convert string to a BigInt")))
      (double-float (throw-type-error "Cannot convert a number to a BigInt"))
      (js-symbol (throw-type-error "Cannot convert a Symbol value to a BigInt"))
      (t (cond ((eq p +true+) 1)
               ((eq p +false+) 0)
               (t (throw-type-error (format nil "Cannot convert ~a to a BigInt"
                                            (if (js-null-p p) "null" "undefined")))))))))

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
