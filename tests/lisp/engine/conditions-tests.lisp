;;;; conditions-tests.lisp — the JS-exception <-> CL-condition bridge.

(in-package :clun-test)

(define-test conditions/throw-js-value
  ;; a thrown JS value propagates as a js-condition carrying that value
  (let ((c (handler-case (eng:throw-js-value "boom")
             (eng:js-condition (e) e))))
    (of-type eng:js-condition c)
    (is string= "boom" (eng:js-condition-value c))))

(define-test conditions/native-errors
  (dolist (spec '((:type-error "TypeError" throw-type-error)
                  (:range-error "RangeError" throw-range-error)
                  (:syntax-error "SyntaxError" throw-syntax-error)
                  (:reference-error "ReferenceError" throw-reference-error)))
    (destructuring-bind (kind name thrower) spec
      (let ((c (handler-case (funcall (find-symbol (string thrower) :clun.engine) "msg")
                 (eng:js-native-error (e) e))))
        (of-type eng:js-native-error c)
        (is eq kind (eng:js-native-error-kind c))
        (is string= "msg" (eng:js-native-error-message c))
        (is string= name (eng:js-native-error-name kind))))))

(define-test conditions/native-is-a-js-condition
  ;; native errors are catchable as js-condition too (subtype)
  (true (handler-case (eng:throw-type-error "x")
          (eng:js-condition () t)
          (:no-error (&rest _) (declare (ignore _)) nil))))
