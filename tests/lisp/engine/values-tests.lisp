;;;; values-tests.lisp — value domain: singletons, predicates, js-type.

(in-package :clun-test)

(define-test values/singletons-distinct
  (true (eng:js-undefined-p eng:+undefined+))
  (true (eng:js-null-p eng:+null+))
  (true (eng:js-boolean-p eng:+true+))
  (true (eng:js-boolean-p eng:+false+))
  (false (eng:js-undefined-p eng:+null+))
  (false (eng:js-null-p eng:+undefined+))
  (false (eng:js-boolean-p eng:+null+))
  (true (eng:js-nullish-p eng:+undefined+))
  (true (eng:js-nullish-p eng:+null+))
  (false (eng:js-nullish-p eng:+false+)))

(define-test values/predicates
  (true (eng:js-number-p 3.5d0))
  (false (eng:js-number-p 3))            ; only double-float is a JS number
  (false (eng:js-number-p "3"))
  (true (eng:js-string-p ""))
  (true (eng:js-string-p "abc"))
  (false (eng:js-string-p eng:+undefined+))
  ;; all Phase 01 values are primitive
  (true (eng:js-primitive-p 1d0))
  (true (eng:js-primitive-p "x"))
  (true (eng:js-primitive-p eng:+undefined+))
  (true (eng:js-primitive-p eng:+true+)))

(define-test values/js-boolean
  (is eq eng:+true+ (eng:js-boolean t))
  (is eq eng:+true+ (eng:js-boolean 42))
  (is eq eng:+false+ (eng:js-boolean nil)))

(define-test values/js-type
  (is eq :number (eng:js-type 1d0))
  (is eq :string (eng:js-type "s"))
  (is eq :boolean (eng:js-type eng:+true+))
  (is eq :boolean (eng:js-type eng:+false+))
  (is eq :undefined (eng:js-type eng:+undefined+))
  (is eq :null (eng:js-type eng:+null+))
  (is eq :object (eng:js-type (eng:make-js-object))))
