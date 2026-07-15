;;;; async-tests.lisp — Phase 06 generators/promises/async end-to-end via eval-source.
;;;; Generators run on thread-coroutines (see src/engine/async/); these lock the hard
;;;; cases (return/throw injection, try/finally × yield, yield* delegation).

(in-package :clun-test)

(defun evj (src)
  "eval-source in a fresh realm, then ToString the result WITH that realm bound (an
object/array result reaches its prototype's toString only inside its realm)."
  (let* ((realm (eng:make-realm))
         (v (eng:eval-source src :realm realm)))
    (let ((eng::*realm* realm)) (eng:to-string v))))

(define-test gen/basic-iteration
  (is string= "1,2,3" (evj "function* g(){ yield 1; yield 2; yield 3; } [...g()].join(',')"))
  (is string= "6" (evj "var s=0; for (const x of (function*(){ yield 1; yield 2; yield 3; })()) s+=x; s"))
  (is string= "true" (evj "var it=(function*(){ yield 1; })(); it.next(); it.next().done"))
  (is string= "object" (evj "typeof (function*(){}).prototype")))

(define-test gen/next-value-threading
  (is string= "15" (evj "function* g(){ var x = yield 1; yield x+10; } var it=g(); it.next(); it.next(5).value"))
  (is string= "1,9,true" (evj "function* g(){ yield 1; return 9; } var it=g(); it.next().value+','+it.next().value+','+it.next().done")))

(define-test gen/return-injection-runs-finally
  ;; .return() unwinds the real CL stack through finally (the thread-coroutine payoff)
  (is string= "1,99,7" (evj "function* g(){ try { yield 1; } finally { yield 99; } }
                            var it=g(); it.next().value+','+it.return(7).value+','+it.next().value"))
  (is string= "true" (evj "function* g(){ yield 1; } var it=g(); it.next(); it.return(5); it.next().done")))

(define-test gen/throw-injection-caught-in-body
  (is string= "1,caught:X" (evj "function* g(){ try { yield 1; } catch(e){ yield 'caught:'+e; } }
                                var it=g(); it.next().value+','+it.throw('X').value"))
  (true (ev-throws "var it=(function*(){ yield 1; })(); it.next(); it.throw(new Error('boom'))")))

(define-test gen/delegation
  (is string= "1,a,b,2" (evj "function* inner(){ yield 'a'; yield 'b'; }
                             function* g(){ yield 1; yield* inner(); yield 2; } [...g()].join(',')"))
  ;; yield* returns the inner generator's return value
  (is string= "42" (evj "function* inner(){ yield 1; return 42; }
                        function* g(){ var v = yield* inner(); yield v; }
                        var it=g(); it.next(); it.next().value"))
  (is string= "1,1,true,true"
      (evj "var args,thisValue,calls=0;
            var iterator={next:function(){calls++;args=arguments;thisValue=this;return {done:true}}};
            var iterable={[Symbol.iterator]:function(){return iterator}};
            var it=(function*(){yield* iterable})();it.next(9876);
            [calls,args.length,args[0]===undefined,thisValue===iterator].join(',')"))
  (is string= "true,3333,5555,3333"
      (evj "var received,result,done;
            var iterable={[Symbol.iterator]:function(){return {next:function(value){received=value;return {done:done,value:3333}}}}};
            function* g(){result=yield* iterable}
            done=true;var first=g();first.next(4444);var firstReceived=received===undefined,firstResult=result;
            done=false;result=null;var second=g();second.next(2222);done=true;second.next(5555);
            [firstReceived,firstResult,received,result].join(',')")))

(define-test gen/realm-and-floats-in-coroutine
  ;; the coroutine thread rebinds *realm* (globals resolve) and re-enters the float mask
  (is string= "3" (evj "var n=3; function* g(){ yield n; } g().next().value"))
  (is string= "Infinity" (evj "function* g(){ yield 1/0; } g().next().value"))
  (is string= "NaN" (evj "function* g(){ yield 0/0; } String(g().next().value)")))

;;; --- promises (jobs drain before eval-source returns; callbacks fill an array) --

(define-test promise/then-and-chaining
  (is string= "2" (evj "var o=[]; Promise.resolve(1).then(x=>o.push(x*2)); o"))
  (is string= "2" (evj "var o=[]; Promise.resolve(1).then(x=>x+1).then(x=>o.push(x)); o"))
  (is string= "c:e" (evj "var o=[]; Promise.reject('e').catch(e=>o.push('c:'+e)); o"))
  (is string= "f,1" (evj "var o=[]; Promise.resolve(1).finally(()=>o.push('f')).then(v=>o.push(v)); o")))

(define-test promise/thenable-adoption-and-executor
  (is string= "42" (evj "var o=[]; Promise.resolve({then(r){r(42)}}).then(v=>o.push(v)); o"))
  (is string= "9" (evj "var o=[]; new Promise((res)=>res(9)).then(v=>o.push(v)); o"))
  (is string= "boom" (evj "var o=[]; new Promise((res,rej)=>rej('boom')).catch(e=>o.push(e)); o")))

(define-test promise/combinators
  (is string= "1-2-3" (evj "var o=[]; Promise.all([1,Promise.resolve(2),3]).then(a=>o.push(a.join('-'))); o"))
  (is string= "a" (evj "var o=[]; Promise.race([Promise.resolve('a'), new Promise(()=>{})]).then(v=>o.push(v)); o"))
  (is string= "fulfilled,rejected"
      (evj "var o=[]; Promise.allSettled([Promise.resolve(1),Promise.reject(2)]).then(a=>o.push(a.map(r=>r.status).join(','))); o"))
  (is string= "ok" (evj "var o=[]; Promise.any([Promise.reject(1),Promise.resolve('ok')]).then(v=>o.push(v)); o")))

(define-test promise/unhandled-rejection-is-fatal
  ;; an unhandled rejection surfaces as an uncaught error after the loop idles
  (true (ev-throws "Promise.reject('boom')"))
  (true (ev-throws "new Promise((res,rej)=>rej(new Error('x')))")))

(define-test promise/conformance-host-can-ignore-result-rejection
  (let ((realm (eng:make-realm)))
    (eng:run-source
     "var closed=0;Promise.resolve=function(){throw 3};var src={ [Symbol.iterator]:function(){return {next:function(){return {value:1,done:false}},return:function(){closed++;return {done:true}}}}};Promise.all(src);globalThis.result=closed;"
     :realm realm :report-unhandled-rejections-p nil)
    (let ((eng::*realm* realm))
      (is eql 1d0 (eng:js-get (eng::realm-global realm) "result")))))

(define-test loop/ordering-nexttick-microtask-timer
  ;; nextTick drains fully, then microtasks, then the timer macrotask (Node-faithful)
  (is string= "n,m,q,t"
      (evj "var log=[];
            setTimeout(()=>log.push('t'),0);
            Promise.resolve().then(()=>log.push('m'));
            queueMicrotask(()=>log.push('q'));
            process.nextTick(()=>log.push('n'));
            log"))
  ;; a microtask scheduled by a microtask runs before the timer
  (is string= "m1,m2,t"
      (evj "var log=[];
            setTimeout(()=>log.push('t'),0);
            Promise.resolve().then(()=>{ log.push('m1'); Promise.resolve().then(()=>log.push('m2')); });
            log")))

;;; --- async / await / for-await / async generators ----------------------------

(define-test async/function-and-await
  (is string= "42" (evj "var o=[]; async function f(){ return 42; } f().then(v=>o.push(v)); o"))
  (is string= "20" (evj "var o=[]; async function f(){ var x = await 10; o.push(x*2); } f(); o"))
  (is string= "3" (evj "var o=[]; async function f(){ var a=await 1, b=await 2; o.push(a+b); } f(); o"))
  (is string= "1,2" (evj "var o=[]; (async()=>{ o.push(await 1); o.push(await 2); })(); o")))

(define-test async/rejection-handling
  (is string= "c:E" (evj "var o=[]; async function f(){ try { await Promise.reject('E'); } catch(e){ o.push('c:'+e); } } f(); o"))
  (is string= "caught:boom" (evj "var o=[]; async function f(){ throw 'boom'; } f().catch(e=>o.push('caught:'+e)); o")))

(define-test async/for-await-of
  (is string= "1,2,3" (evj "var o=[]; async function f(){ for await (const x of [1,2,3]) o.push(x); } f(); o"))
  (is string= "1,2" (evj "var o=[]; async function* g(){ yield 1; yield 2; } (async()=>{ for await (const x of g()) o.push(x); })(); o"))
  (is string= "5,6" (evj "var o=[]; async function* g(){ yield await 5; yield 6; } (async()=>{ for await (const x of g()) o.push(x); })(); o"))
  ;; for-await over a sync iterable Awaits each value (async-from-sync)
  (is string= "1,2,done"
      (evj "var o=[]; async function f(){ for await (const x of [Promise.resolve(1),Promise.resolve(2)]) o.push(x); } f().then(()=>o.push('done')); o")))

;;; --- Phase 06 review-panel regressions ---------------------------------------

(define-test async/tostringtag-brand
  ;; Object.prototype.toString reads @@toStringTag (§20.1.3.6)
  (is string= "[object Generator]" (evj "Object.prototype.toString.call((function*(){})())"))
  (is string= "[object Map]" (evj "Object.prototype.toString.call(new Map())"))
  (is string= "[object Promise]" (evj "Object.prototype.toString.call(Promise.resolve())"))
  (is string= "[object Foo]" (evj "Object.prototype.toString.call({[Symbol.toStringTag]:'Foo'})"))
  (is string= "[object Array]" (evj "Object.prototype.toString.call([])")))

(define-test promise/finally-awaits-onfinally
  ;; finally awaits the promise onFinally returns, and propagates its rejection
  (is string= "rejFE" (evj "var o=[]; Promise.resolve('V').finally(()=>Promise.reject('FE')).then(v=>o.push('t'+v),e=>o.push('rej'+e)); o"))
  (is string= "V" (evj "var o=[]; Promise.resolve('V').finally(()=>Promise.resolve('ignored')).then(v=>o.push(v)); o")))

(define-test promise/aggregate-error-global
  (is string= "true:2" (evj "var o=[]; Promise.any([Promise.reject(1),Promise.reject(2)]).catch(e=>o.push((e instanceof AggregateError)+':'+e.errors.length)); o"))
  (is string= "function" (evj "typeof AggregateError")))

(define-test promise/subclass-is-real-promise
  ;; class extends Promise: derived default ctor binds `this` to super()'s Promise
  (is string= "true,t9" (evj "var o=[]; class P extends Promise{} var x=new P((res)=>res(9)); o.push(x instanceof P); x.then(v=>o.push('t'+v)); o"))
  (is eq eng:+true+ (ev "class P extends Promise{} (new P(r=>r(1))) instanceof Promise")))

(define-test class/subclass-builtins-honor-new-target
  ;; a derived class of a builtin is an instance of BOTH the subclass and the builtin
  ;; (builtin constructors honor new-target's prototype — OrdinaryCreateFromConstructor)
  (is string= "true,true,true" (evj "class S extends Array{} var a=new S(); (a instanceof S)+','+(a instanceof Array)+','+Array.isArray(a)"))
  (is string= "true,true" (evj "class S extends Number{} var n=new S(); (n instanceof S)+','+(n instanceof Number)"))
  (is string= "true,true,m" (evj "class S extends Error{} var e=new S('m'); (e instanceof S)+','+(e instanceof Error)+','+e.message"))
  (is string= "true,true" (evj "class S extends String{} var s=new S('x'); (s instanceof S)+','+(s instanceof String)"))
  (is string= "true,true" (evj "class S extends Object{} var o=new S(); (o instanceof S)+','+(o instanceof Object)")))

(define-test globals/timer-id-and-clamp
  ;; setTimeout returns an opaque object id (string-coercible, not a raw struct);
  ;; huge/Infinite delays clamp so the process never hangs
  (is string= "object" (evj "typeof setTimeout(()=>{},1000)"))
  (is string= "x" (evj "var o=[]; setTimeout(()=>o.push('x'), 1e21); o"))
  (is string= "x" (evj "var o=[]; setTimeout(()=>o.push('x'), Infinity); o")))
