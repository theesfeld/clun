;;;; async-generator-queue-tests.lisp -- Phase 25b m6 request serialization.

(in-package :clun-test)

(define-test async-generator/queued-next-fifo
  (is string= "first:1,second:2,third:undefined:true"
      (evj "var out=[];
            async function* values(){yield Promise.resolve(1);yield 2}
            var iterator=values(),first=iterator.next(),second=iterator.next(),third=iterator.next();
            first.then(result=>out.push('first:'+result.value));
            second.then(result=>out.push('second:'+result.value));
            third.then(result=>out.push('third:'+result.value+':'+result.done));out")))

(define-test async-generator/reentrant-request-is-serialized
  (is string= "outer:1,inner:2"
      (evj "var out=[],iterator;
            async function* values(){
              iterator.next().then(result=>out.push('inner:'+result.value));
              yield 1;yield 2
            }
            iterator=values();
            iterator.next().then(result=>out.push('outer:'+result.value));out")))

(define-test async-generator/yield-adopts-and-rejection-resumes-as-throw
  (is string= "4,false"
      (evj "var out=[];(async function*(){yield Promise.resolve(4)})().next()
              .then(result=>out.push(result.value,result.done));out"))
  (is string= "caught:reason,false"
      (evj "var out=[];
            (async function*(){try{yield Promise.reject('reason')}catch(error){yield 'caught:'+error}})()
              .next().then(result=>out.push(result.value,result.done));out"))
  (is string= "reason,true"
      (evj "var out=[],iterator=(async function*(){yield Promise.reject('reason')})();
            iterator.next().then(()=>out.push('fulfilled'),error=>out.push(error));
            iterator.next().then(result=>out.push(result.done));out"))
  (is string= "get constructor,5"
      (evj "var out=[],promise=Promise.resolve(5);
            Object.defineProperty(promise,'constructor',{get(){out.push('get constructor');return Promise}});
            (async function*(){yield promise})().next().then(result=>out.push(result.value));out")))

(define-test async-generator/abrupt-promise-resolve-setup-is-synchronous
  (is string= "get,catch,qm,tick"
      (evj "var out=[],promise=Promise.resolve(1);
            Object.defineProperty(promise,'constructor',{get:function(){
              out.push('get');queueMicrotask(function(){out.push('qm')});throw new Error('broken')
            }});
            async function f(){try{await promise}catch(error){out.push('catch')}}
            f();Promise.resolve().then(function(){out.push('tick')});out"))
  (is string= "get,catch,qm,tick"
      (evj "var out=[],promise=Promise.resolve(1);
            Object.defineProperty(promise,'constructor',{get:function(){
              out.push('get');queueMicrotask(function(){out.push('qm')});throw new Error('broken')
            }});
            var iterator=(async function*(){try{yield promise}catch(error){out.push('catch')}})();
            iterator.next();Promise.resolve().then(function(){out.push('tick')});out")))

(define-test async-generator/incompatible-receiver-rejects-promise
  (is string= "true,false,true"
      (evj "var prototype=Object.getPrototypeOf(async function*(){}).prototype;
            var promise,synchronous=false,out=[];
            try{promise=prototype.next.call({})}catch(error){synchronous=true}
            out.push(promise instanceof Promise,synchronous);
            promise.then(()=>out.push(false),error=>out.push(error instanceof TypeError));out")))

(define-test async-generator/return-awaits-suspended-start-and-completed
  (is string= "start:7:true,closed:8:true"
      (evj "var out=[],iterator=(async function*(){throw 'must not run'})();
            iterator.return(Promise.resolve(7)).then(result=>out.push('start:'+result.value+':'+result.done));
            iterator.return(Promise.resolve(8)).then(result=>out.push('closed:'+result.value+':'+result.done));out"))
  (is string= "reason"
      (evj "var out=[],iterator=(async function*(){})();iterator.next();
            iterator.return(Promise.reject('reason')).then(()=>out.push('fulfilled'),error=>out.push(error));out")))

(define-test async-generator/return-broken-constructor-drains-reentrant-queue-synchronously
  (is string= "get,qm,reentrant-next,return-catch,tick"
      (evj "var out=[],iterator=(async function*(){})();
            iterator.next().then(function(){
              var broken=Promise.resolve(42);
              Object.defineProperty(broken,'constructor',{get:function(){
                out.push('get');
                iterator.next().then(function(){out.push('reentrant-next')});
                queueMicrotask(function(){out.push('qm')});
                throw new Error('broken')
              }});
              iterator.return(broken).catch(function(){out.push('return-catch')});
              Promise.resolve().then(function(){out.push('tick')})
            });out")))

(define-test async-generator/return-through-finally-keeps-queue-order
  (is string= "next:1:false,return:cleanup:false,after:9:true,done:true"
      (evj "var out=[];
            async function* values(){try{yield 1;yield 'unreachable'}finally{yield 'cleanup'}}
            var iterator=values();
            iterator.next().then(result=>out.push('next:'+result.value+':'+result.done));
            iterator.return(Promise.resolve(9)).then(result=>out.push('return:'+result.value+':'+result.done));
            iterator.next().then(result=>out.push('after:'+result.value+':'+result.done));
            iterator.next().then(result=>out.push('done:'+result.done));out")))

(define-test async-generator/queued-throw-does-not-overtake-next
  ;; The next request is resolved before throw drives, but its reaction remains a
  ;; job; synchronous generator-side catch effects therefore happen first.
  (is string= "caught:boom,first:1,done:true"
      (evj "var out=[];
            async function* values(){try{yield 1;yield 2}catch(error){out.push('caught:'+error)}}
            var iterator=values();
            iterator.next().then(result=>out.push('first:'+result.value));
            iterator.throw('boom').then(result=>out.push('done:'+result.done));out")))
