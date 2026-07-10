;;;; objects-tests.lisp — object kernel: descriptors, internal methods, arrays.

(in-package :clun-test)

(define-test objects/data-properties
  (let ((o (eng:js-make-object)))
    (eng:create-data-property o "x" 42d0)
    (is eql 42d0 (eng:js-get o "x"))
    (true (eng:has-own-property o "x"))
    (false (eng:has-own-property o "y"))
    (is equal '("x") (eng:jm-own-property-keys o))))

(define-test objects/prototype-chain
  (let* ((proto (eng:js-make-object)) (o (eng:js-make-object proto)))
    (eng:create-data-property proto "p" "inherited")
    (is string= "inherited" (eng:js-get o "p"))
    (false (eng:has-own-property o "p"))
    (true (eng:has-property o "p"))))

(define-test objects/key-ordering
  ;; integer indices ascending, then strings in insertion order
  (let ((o (eng:js-make-object)))
    (dolist (k '("b" "2" "a" "10" "1")) (eng:create-data-property o k 0d0))
    (is equal '("1" "2" "10" "b" "a") (eng:jm-own-property-keys o))))

(define-test objects/array-length
  (let* ((r (eng:make-realm)) (eng::*realm* r))
    (let ((a (eng::new-array (list 1d0 2d0 3d0))))
      (is eql 3d0 (eng:js-get a "length"))
      (is eql 2d0 (eng:js-get a "1"))
      (true (eng:js-array-p a)))))

(define-test objects/via-eval
  ;; exercise the kernel through executed JS
  (is eq eng:+true+ (ev "var o={}; Object.defineProperty(o,'x',{value:5,writable:false}); o.x===5"))
  (is eq eng:+false+ (ev "var o={}; Object.defineProperty(o,'x',{value:5,writable:false,configurable:true}); var d=Object.getOwnPropertyDescriptor(o,'x'); d.writable"))
  (is eq eng:+true+ (ev "var o={a:1,b:2}; Object.keys(o).length===2"))
  (is eq eng:+true+ (ev "var o={}; Object.defineProperty(o,'y',{value:1,enumerable:false}); Object.keys(o).length===0"))
  (is eq eng:+true+ (ev "var o=Object.freeze({a:1}); o.a=2; o.a===1"))
  (is eq eng:+true+ (ev "Object.getPrototypeOf([]) === Array.prototype")))
