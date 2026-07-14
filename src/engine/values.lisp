;;;; values.lisp — the JS value domain in CL (PLAN.md Phase 01, §3.1).
;;;; Native representation: numbers = double-float, strings = CL string (one char =
;;;; one UTF-16 code unit), objects = struct rooted at js-object, and the four
;;;; singletons below. Benchmarked 4.3x faster than a uniform tagged struct
;;;; (DECISIONS.md). No bare :undefined/:null literals elsewhere — go through the
;;;; constants and predicates so the representation stays swappable.

(in-package :clun.engine)

;;; Singletons. Keywords can never collide with a JS value (numbers are doubles,
;;; strings are strings, everything else is a struct), so eq is unambiguous.
(defconstant +undefined+ :undefined)
(defconstant +null+      :null)
(defconstant +true+      :true)
(defconstant +false+     :false)

;;; Root of the object hierarchy. The full object kernel (descriptors, prototype
;;; chains, exotic behaviors) is Phase 03; this empty base only makes js-object-p
;;; stable from Phase 01 so the value domain is complete. Phase 03 :includes it.
;;; Root of the object hierarchy. Slots: property storage, [[Prototype]],
;;; [[Extensible]], and a [[Class]]/brand tag. Exotic objects (Array, Function,
;;; arguments, ...) :include this in objects.lisp and override internal methods.
(defstruct (js-object (:predicate js-object-p) (:copier nil))
  (props nil)                  ; nil | a `ptable` struct (order-preserving keys+descs, lazy equal
                               ;   hash index, + a Phase-25 shape token); see objects.lisp
  (proto +null+)               ; [[Prototype]]: a js-object or +null+
  (extensible t)
  (class :object))             ; [[Class]] / brand keyword

;;; Symbols are primitives (NOT js-objects). description is a string or +undefined+.
(defstruct (js-symbol (:predicate js-symbol-p) (:copier nil) (:constructor %make-js-symbol))
  (description +undefined+)
  (well-known nil))            ; e.g. :iterator :to-primitive :has-instance for @@-symbols

(declaim (inline js-undefined-p js-null-p js-nullish-p js-boolean-p
                 js-number-p js-bigint-p js-string-p js-primitive-p))

(defun js-undefined-p (v) (eq v +undefined+))
(defun js-null-p       (v) (eq v +null+))
(defun js-nullish-p    (v) (or (eq v +undefined+) (eq v +null+)))
(defun js-boolean-p    (v) (or (eq v +true+) (eq v +false+)))
(defun js-number-p     (v) (typep v 'double-float))
;; BigInt IS a CL integer — no engine value is ever a raw integer otherwise (numbers
;; are doubles, indices/lengths are consumed locally but never stored as a JS value),
;; so this is a total, unambiguous slot in the value domain (§3.1).
(defun js-bigint-p     (v) (integerp v))
(defun js-string-p     (v) (stringp v))

(defun js-boolean (generalized-boolean)
  "The JS boolean for a CL generalized boolean."
  (if generalized-boolean +true+ +false+))

;;; ToPrimitive treats every non-Object type as already primitive; only Objects
;;; convert. In Phase 01 all values are primitive, so this is total.
(defun js-primitive-p (v)
  (not (js-object-p v)))

(defun js-type (v)
  "The ECMA-262 §6.1 Type of V, as a keyword (for internal dispatch, not `typeof`)."
  (typecase v
    (double-float :number)
    (integer :bigint)
    (string :string)
    (js-symbol :symbol)
    (js-object :object)
    (t (cond ((js-boolean-p v) :boolean)
             ((js-undefined-p v) :undefined)
             ((js-null-p v) :null)
             (t (error "not a JS value: ~s" v))))))
