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

(define-test objects/object-prototype-immutable-prototype
  (is eq eng:+true+
      (ev "(function(){try{Object.setPrototypeOf(Object.prototype,{})}
             catch(e){return e instanceof TypeError&&Object.getPrototypeOf(Object.prototype)===null}
             return false})()"))
  (is eq eng:+true+
      (ev "Reflect.setPrototypeOf(Object.prototype,{})===false&&
           Object.getPrototypeOf(Object.prototype)===null"))
  (is eq eng:+true+
      (ev "Object.setPrototypeOf(Object.prototype,null)===Object.prototype&&
           Reflect.setPrototypeOf(Object.prototype,null)===true"))
  ;; The Annex B setter propagates a rejected [[SetPrototypeOf]] as TypeError.
  (is eq eng:+true+
      (ev "(function(){try{Object.prototype.__proto__={}}
             catch(e){return e instanceof TypeError&&Object.getPrototypeOf(Object.prototype)===null}
             return false})()"))
  (is eq eng:+true+
      (ev "(Object.prototype.__proto__=null)===null&&
           Object.getPrototypeOf(Object.prototype)===null"))
  ;; Only the realm's Object.prototype is exotic. An ordinary null-prototype
  ;; object remains freely mutable through the same internal method.
  (is eq eng:+true+
      (ev "var o={__proto__:null},p={};
           Object.getPrototypeOf(o)===null&&Reflect.setPrototypeOf(o,p)&&
           Object.getPrototypeOf(o)===p")))

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

(define-test objects/seal-and-is-sealed
  (is eq eng:+true+
      (ev "(function(){var o={a:1},before=Object.isSealed(o),same=Object.seal(o)===o;
             var d=Object.getOwnPropertyDescriptor(o,'a');
             return !before&&same&&Object.isSealed(o)&&!Object.isExtensible(o)&&
                    d.value===1&&d.writable===true&&d.enumerable===true&&d.configurable===false;
           })()"))
  (is eq eng:+true+
      (ev "(function(){var get=function(){return 3},set=function(v){};
             var o={},sym=Symbol('sealed'),p={inherited:1};Object.setPrototypeOf(o,p);
             Object.defineProperty(o,'x',{get:get,set:set,enumerable:false,configurable:true});
             Object.defineProperty(o,sym,{value:4,writable:true,enumerable:false,configurable:true});
             Object.seal(o);var x=Object.getOwnPropertyDescriptor(o,'x');
             var s=Object.getOwnPropertyDescriptor(o,sym);
             return x.get===get&&x.set===set&&!x.enumerable&&!x.configurable&&
                    s.value===4&&s.writable&&!s.enumerable&&!s.configurable&&
                    Object.getOwnPropertyDescriptor(p,'inherited').configurable;
           })()"))
  (is eq eng:+true+
      (ev "(function(){var o={x:1};Object.preventExtensions(o);
             var before=!Object.isSealed(o);Object.seal(o);
             return before&&Object.isSealed(o)&&Object.seal(7)===7&&Object.isSealed(null);
           })()"))
  (is eq eng:+true+
      (ev "(function(){var a=new Int8Array(1),threw=false;
             try{Object.seal(a)}catch(e){threw=e instanceof TypeError}
             return threw&&!Object.isExtensible(a);
           })()"))
  (is eq eng:+true+
      (ev "(function(){var o={x:1};Object.seal(o);return (delete o.x)===false})()"))
  (is eq eng:+true+
      (evs "(function(){var o={},s=Symbol('x');o[s]=1;Object.seal(o);
              try{delete o[s]}catch(e){return e instanceof TypeError}return false;
            })()"))
  (dolist (evaluate (list #'ev #'evs))
    (is eq eng:+true+
        (funcall evaluate
                 "(function(){var sideEffect=0;
                    try{delete null[(sideEffect=1)]}
                    catch(e){return sideEffect===1&&e instanceof TypeError}
                    return false})()"))
    (is eq eng:+true+
        (funcall evaluate
                 "(function(){var coerced=0,key={toString:function(){coerced++;return 'x'}};
                    try{delete null[key]}
                    catch(e){return coerced===0&&e instanceof TypeError}
                    return false})()"))))

(define-test objects/legacy-accessor-definition-methods
  (is eq eng:+true+
      (ev "(function(){var o={},get=function(){return 1},set=function(v){},sym=Symbol('x');
             o.__defineSetter__('x',set);o.__defineGetter__('x',get);o.__defineGetter__(sym,get);
             var d=Object.getOwnPropertyDescriptor(o,'x'),s=Object.getOwnPropertyDescriptor(o,sym);
             return d.get===get&&d.set===set&&d.enumerable&&d.configurable&&
                    s.get===get&&s.set===undefined&&s.enumerable&&s.configurable;
           })()"))
  (is eq eng:+true+
      (ev "(function(){var o={},set=function(v){};Object.defineProperty(o,'x',{value:1,configurable:true});
             o.__defineSetter__('x',set);var d=Object.getOwnPropertyDescriptor(o,'x');
             return d.get===undefined&&d.set===set&&d.value===undefined&&d.enumerable;
           })()"))
  (is eq eng:+true+
      (ev "(function(){var count=0,key={toString:function(){count++;return 'x'}};
             try{({}).__defineGetter__(key,1)}catch(e){return e instanceof TypeError&&count===0}
             return false;
           })()"))
  (is eq eng:+true+
      (ev "(function(){var f=Object.prototype.__defineGetter__,count=0;
             var key={toString:function(){count++;return 'x'}};
             try{f.call(null,key,function(){})}catch(e){return e instanceof TypeError&&count===0}
             return false;
           })()"))
  (is eq eng:+true+
      (ev "(function(){var o={};Object.defineProperty(o,'x',{configurable:false});
             try{o.__defineGetter__('x',function(){})}catch(e){return e instanceof TypeError}
             return false;
           })()"))
  (is eq eng:+true+
      (ev "(function(){var o={};Object.preventExtensions(o);
             try{o.__defineSetter__('x',function(v){})}catch(e){return e instanceof TypeError}
             return false;
           })()"))
  (is eq eng:+true+
      (ev "(function(){var a=new Int8Array(1),getFailed=false,setFailed=false;
             try{a.__defineGetter__('0',function(){})}catch(e){getFailed=e instanceof TypeError}
             try{a.__defineSetter__('0',function(v){})}catch(e){setFailed=e instanceof TypeError}
             a.__defineSetter__('named',function(v){});
             var d=Object.getOwnPropertyDescriptor(a,'named');
             return getFailed&&setFailed&&typeof d.set==='function'&&d.configurable&&d.enumerable;
           })()")))

(define-test objects/legacy-accessor-lookup-methods
  (is eq eng:+true+
      (ev "(function(){var calls=0,get=function(){calls++;return 1},set=function(v){};
             var root={},mid=Object.create(root),o=Object.create(mid),sym=Symbol('x');
             root.__defineGetter__('x',get);mid.__defineSetter__(sym,set);
             return o.__lookupGetter__('x')===get&&calls===0&&
                    o.__lookupSetter__(sym)===set&&o.__lookupGetter__('missing')===undefined;
           })()"))
  (is eq eng:+true+
      (ev "(function(){var get=function(){return 1},set=function(v){},p={};p.__defineGetter__('x',get);
             var data=Object.create(p);Object.defineProperty(data,'x',{value:1});
             var opposite=Object.create(p);opposite.__defineSetter__('x',set);
             return data.__lookupGetter__('x')===undefined&&opposite.__lookupGetter__('x')===undefined;
           })()"))
  (is eq eng:+true+
      (ev "Object.prototype.__defineGetter__.length===2&&
           Object.prototype.__defineSetter__.length===2&&
           Object.prototype.__lookupGetter__.length===1&&
           Object.prototype.__lookupSetter__.length===1")))

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
