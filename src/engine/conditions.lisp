;;;; conditions.lisp — JS-exception <-> CL-condition bridge (PLAN.md Phase 01, §6).
;;;; A JS `throw x` of any value becomes a CL condition carrying that value; an
;;;; uncaught one is rendered at the top level (Phase 08). Engine-internal throws
;;;; (TypeError, RangeError, ...) use the throw-* helpers; real JS Error objects
;;;; land in Phase 04, at which point these constructors build them without any
;;;; call site changing — this bridge is the seam.

(in-package :clun.engine)

(define-condition js-condition (error)
  ((value :initarg :value :reader js-condition-value
          :documentation "The thrown JS value."))
  (:report (lambda (c stream)
             (format stream "uncaught JS exception: ~s" (js-condition-value c))))
  (:documentation "A JS `throw` crossing CL control flow."))

(define-condition js-native-error (js-condition)
  ((kind :initarg :kind :reader js-native-error-kind
         :documentation "One of :type-error :range-error :syntax-error :reference-error :error.")
   (message :initarg :message :initform "" :reader js-native-error-message))
  (:report (lambda (c stream)
             (format stream "~a: ~a"
                     (js-native-error-name (js-native-error-kind c))
                     (js-native-error-message c))))
  (:documentation "An engine-raised error before real JS Error objects exist (Phase 04)."))

(defun js-native-error-name (kind)
  (ecase kind
    (:type-error "TypeError")
    (:range-error "RangeError")
    (:syntax-error "SyntaxError")
    (:reference-error "ReferenceError")
    (:error "Error")))

(defun throw-js-value (value)
  "Propagate a JS `throw VALUE` as a CL condition."
  (error 'js-condition :value value))

(defvar *make-error-object* nil
  "Installed by realm.lisp (Phase 03): (kind message) -> a real JS Error object.")

(defun throw-native-error (kind message)
  ;; With a realm, throw a real Error object wrapped in a js-condition; before the
  ;; realm exists (early bootstrap / unit tests) fall back to the js-native-error.
  (if *make-error-object*
      (error 'js-condition :value (funcall *make-error-object* kind message))
      (error 'js-native-error :kind kind :message message :value message)))

(defun throw-type-error (message)      (throw-native-error :type-error message))
(defun throw-range-error (message)     (throw-native-error :range-error message))
(defun throw-syntax-error (message)    (throw-native-error :syntax-error message))
(defun throw-reference-error (message) (throw-native-error :reference-error message))
