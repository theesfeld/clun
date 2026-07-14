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

(define-test shapes/pshape-cap-bounds-the-tree
  ;; Phase 25: the global shape transition tree is hard-capped so a long-lived process can't exhaust
  ;; the heap. Past the cap, objects run dict-mode (shape NIL) but stay fully correct.
  (let* ((base eng::*pshape-count*)
         (eng::*pshape-cap* (+ base 5)))
    (let ((last nil))
      (dotimes (i 30)                                   ; 30 distinct first-key layouts; only 5 can mint
        (let ((o (eng:js-make-object))
              (k (format nil "cap~d" (+ base i))))
          (eng:create-data-property o k (coerce i 'double-float))
          (setf last o)
          (is eql (coerce i 'double-float) (eng:js-get o k))))   ; reads back regardless of mode
      (true (<= eng::*pshape-count* eng::*pshape-cap*) "pshape count never exceeds the cap")
      ;; `last` is past the cap → dict-mode (shape NIL) → still supports add/get/set
      (eng:create-data-property last "extra" 7d0)
      (is eql 7d0 (eng:js-get last "extra"))
      (eng:js-set last "extra" 8d0 t)
      (is eql 8d0 (eng:js-get last "extra")))))

(define-test shapes/inline-cache-hit-path-and-invalidation
  ;; exercise the READ IC over REPEATED access (first miss caches, then hits) + invalidation
  (is eq eng:+true+ (ev "function C(){this.x=1;} C.prototype.m=function(){return this.x;};
                         var o=new C(),s=0; for(var i=0;i<5;i++)s+=o.m(); o.x=10;
                         for(var i=0;i<5;i++)s+=o.m(); s===55"))          ; own-field + proto-method IC
  (is eq eng:+true+ (ev "function C(){this.x=1;} C.prototype.foo=function(){return 'p';};
                         var o=new C(); var a=o.foo(); o.foo=function(){return 'o';}; var b=o.foo();
                         a==='p'&&b==='o'"))                               ; own-add shadows a cached proto hit
  (is eq eng:+true+ (ev "var p1={v:1},p2={v:2},o=Object.create(p1); o.own=0; var a=o.v;
                         Object.setPrototypeOf(o,p2); var b=o.v; a===1&&b===2"))  ; setPrototypeOf invalidates
  (is eq eng:+true+ (ev "var proto={k:1}; var o=Object.create(proto); o.own=0; var a=o.k;
                         proto.k=9; var b=o.k; delete proto.k; var c=o.k; a===1&&b===9&&c===undefined")))
