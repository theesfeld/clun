;;;; coercions-tests.lisp — ECMA-262 §7.1 abstract operations on primitives.

(in-package :clun-test)

(define-test coercions/to-boolean
  (is eq eng:+false+ (eng:to-boolean eng:+undefined+))
  (is eq eng:+false+ (eng:to-boolean eng:+null+))
  (is eq eng:+false+ (eng:to-boolean eng:+false+))
  (is eq eng:+true+  (eng:to-boolean eng:+true+))
  (is eq eng:+false+ (eng:to-boolean 0d0))
  (is eq eng:+false+ (eng:to-boolean -0d0))
  (is eq eng:+false+ (eng:to-boolean eng:*js-nan*))
  (is eq eng:+true+  (eng:to-boolean 1d0))
  (is eq eng:+true+  (eng:to-boolean eng:+js-infinity+))
  (is eq eng:+false+ (eng:to-boolean ""))
  (is eq eng:+true+  (eng:to-boolean "0"))          ; non-empty string is truthy
  (is eq eng:+true+  (eng:to-boolean "false")))

(define-test coercions/js-truthy-cl-boolean
  (true (eng:js-truthy 1d0))
  (false (eng:js-truthy 0d0))
  (false (eng:js-truthy eng:+null+))
  (true (eng:js-truthy "x")))

(define-test coercions/to-number
  (true (eng:js-nan-p (eng:to-number eng:+undefined+)))
  (is eql 0d0 (eng:to-number eng:+null+))
  (is eql 1d0 (eng:to-number eng:+true+))
  (is eql 0d0 (eng:to-number eng:+false+))
  (is eql 3.5d0 (eng:to-number 3.5d0))
  (is eql 42d0 (eng:to-number "42"))
  (is eql 16d0 (eng:to-number "0x10"))
  (is eql 0d0 (eng:to-number ""))
  (true (eng:js-nan-p (eng:to-number "abc"))))

(define-test coercions/to-string
  (is string= "undefined" (eng:to-string eng:+undefined+))
  (is string= "null" (eng:to-string eng:+null+))
  (is string= "true" (eng:to-string eng:+true+))
  (is string= "false" (eng:to-string eng:+false+))
  (is string= "3.5" (eng:to-string 3.5d0))
  (is string= "NaN" (eng:to-string eng:*js-nan*))
  (is string= "abc" (eng:to-string "abc"))          ; string -> itself
  (is string= "0" (eng:to-string -0d0)))

(define-test coercions/to-primitive-identity-on-primitives
  ;; Phase 01: every value is primitive, so ToPrimitive is identity
  (is eq eng:+undefined+ (eng:to-primitive eng:+undefined+))
  (is eql 5d0 (eng:to-primitive 5d0))
  (is string= "s" (eng:to-primitive "s"))
  (is eq eng:+true+ (eng:to-primitive eng:+true+ :number)))

(define-test coercions/to-primitive-object-hook-absent
  ;; without the Phase 03/04 hook, an object input errors loudly (not silently)
  (fail (eng:to-primitive (eng:make-js-object)) error))
