;;;; async-iteration-tests.lisp -- focused Phase 25b m6 iterator semantics.

(in-package :clun-test)

(define-test async-iteration/get-async-iterator-preference
  (is string= "async,false"
      (evj "var out=[],syncRead=false;
            var source={
              get [Symbol.iterator](){syncRead=true;throw 'sync'},
              [Symbol.asyncIterator](){var done=false;return {next(){
                if(done)return Promise.resolve({done:true});done=true;
                return Promise.resolve({value:'async',done:false})}}}
            };
            (async()=>{for await(const value of source)out.push(value,syncRead)})();out")))

(define-test async-iteration/async-from-sync-adoption
  ;; AsyncFromSync adopts a synchronous result's value and creates a fresh
  ;; iterator result. Native async delegation preserves its already-settled
  ;; value without an additional adoption.
  (is string= "7,false"
      (evj "var raw={value:Promise.resolve(7),done:false};
            var source={[Symbol.iterator](){return {next(){return raw}}}};
            var out=[];(async function*(){yield* source})().next().then(r=>{
              out.push(r.value,r===raw)});out"))
  (is string= "true"
      (evj "var value=Promise.resolve(7),done=false;
            var source={[Symbol.asyncIterator](){return {next(){
              if(done)return Promise.resolve({done:true});done=true;
              return Promise.resolve({value:value,done:false})}}}};
            var out=[];(async function*(){yield* source})().next()
              .then(r=>out.push(r.value===value));out")))

(define-test async-iteration/async-from-sync-argument-presence
  (is string= "next:1:true,next:1:7,throw:1:8,return:1:9,9,true"
      (evj "var out=[];
            var source={[Symbol.iterator](){return {
              next(value){out.push('next:'+arguments.length+':'+(value===undefined));
                if(value!==undefined)out[out.length-1]='next:'+arguments.length+':'+value;
                return {value:1,done:false}},
              throw(value){out.push('throw:'+arguments.length+':'+value);
                return {value:2,done:false}},
              return(value){out.push('return:'+arguments.length+':'+value);
                return {value:value,done:true}}
            }}};
            var iterator=(async function*(){return yield* source})();
            iterator.next().then(()=>iterator.next(7))
              .then(()=>iterator.throw(8)).then(()=>iterator.return(9))
              .then(result=>out.push(result.value,result.done));out"))
  (is string= "0"
      (evj "var out=[];
            var source={[Symbol.iterator](){return {next(){
              out.push(arguments.length);return {done:true}}}}};
            (async()=>{for await(const value of source){out.push(value)}})();out")))

(define-test async-iteration/async-from-sync-invalid-and-poisoned-results
  (is string= "true,true,true"
      (evj "var out=[],doneError={},valueError={};
            function probe(kind){
              var source={[Symbol.iterator](){return {next(){
                if(kind==='primitive')return 1;
                if(kind==='done')return {get done(){throw doneError},value:1};
                return {done:false,get value(){throw valueError}}
              }}}};
              return (async function*(){yield* source})().next().then(
                ()=>out.push(false),error=>out.push(kind==='primitive'
                  ?error instanceof TypeError
                  :error===(kind==='done'?doneError:valueError)))
            }
            probe('primitive').then(()=>probe('done')).then(()=>probe('value'));out"))
  (is string= "true,true"
      (evj "var out=[];
            function source(method){return {[Symbol.iterator](){return {
              next(){return {value:1,done:false}},
              return(){return method==='return'?1:{done:true}},
              throw(){return method==='throw'?1:{done:true}}
            }}}}
            var returned=(async function*(){yield* source('return')})();
            returned.next().then(()=>returned.return()).then(
              ()=>out.push(false),error=>out.push(error instanceof TypeError))
              .then(function(){var thrown=(async function*(){yield* source('throw')})();
                return thrown.next().then(()=>thrown.throw()).then(
                  ()=>out.push(false),error=>out.push(error instanceof TypeError))});out"))
  (is string= "true,1"
      (evj "var out=[],original={},closeError={},closed=0;
            var poisoned=Promise.resolve(1);
            Object.defineProperty(poisoned,'constructor',{get(){throw original}});
            var source={[Symbol.iterator](){return {
              next(){return {value:poisoned,done:false}},
              return(){closed++;throw closeError}
            }}};
            (async function*(){yield* source})().next().then(
              ()=>out.push(false),error=>out.push(error===original,closed));out")))

(define-test async-iteration/yield-star-return-and-throw
  (is string= "42,true"
      (evj "var out=[];
            var source={[Symbol.iterator](){return {
              next(){return {value:1,done:false}},
              return(){return {value:Promise.resolve(42),done:true}}
            }}};
            var it=(async function*(){return yield* source})();
            it.next().then(()=>it.return(9)).then(r=>out.push(r.value,r.done));out"))
  (is string= "true,1"
      (evj "var out=[],closed=0;
            var source={[Symbol.iterator](){return {
              next(){return {value:1,done:false}},
              return(){closed++;return {done:true}}
            }}};
            var it=(async function*(){yield* source})();
            it.next().then(()=>it.throw('boom')).then(
              ()=>out.push(false),e=>out.push(e instanceof TypeError,closed));out")))

(define-test async-iteration/yield-star-native-done-throw-await
  ;; A native async delegate's completed throw result performs a distinct Await
  ;; on `value` after awaiting the iterator result itself.
  (is string= "inner,get then,tick 1,call then,tick 2,body:settled,result:outer:true"
      (evj "var out=[];
            var value={get then(){out.push('get then');return function(resolve){
              out.push('call then');resolve('settled')}}};
            var source={[Symbol.asyncIterator](){return {
              next(){return {value:1,done:false}},
              throw(){out.push('inner');return {value:value,done:true}}
            }}};
            var iterator=(async function*(){var result=yield* source;
              out.push('body:'+result);return 'outer'})();
            iterator.next().then(function(){
              iterator.throw('sent').then(function(result){
                out.push('result:'+result.value+':'+result.done)});
              Promise.resolve().then(function(){out.push('tick 1')})
                .then(function(){out.push('tick 2')})
            });out"))
  (is string= "true,handled,true"
      (evj "var out=[],reason={};
            var source={[Symbol.asyncIterator](){return {
              next(){return {value:1,done:false}},
              throw(){return {done:true,value:{then(resolve,reject){reject(reason)}}}}
            }}};
            var iterator=(async function*(){try{yield* source;out.push(false)}
              catch(error){out.push(error===reason);return 'handled'}})();
            iterator.next().then(()=>iterator.throw('sent')).then(
              result=>out.push(result.value,result.done));out")))

(define-test async-iteration/yield-star-native-done-return-await
  ;; Return resumption first awaits the caller's value, then a completed native
  ;; delegate result separately awaits its own value before preserving return.
  (is string= "inner:sent,tick 1,get then,tick 2,call then,tick 3,finally,result:settled:true"
      (evj "var out=[];
            var value={get then(){out.push('get then');return function(resolve){
              out.push('call then');resolve('settled')}}};
            var source={[Symbol.asyncIterator](){return {
              next(){return {value:1,done:false}},
              return(value){out.push('inner:'+value);return {value:valueObject,done:true}}
            }}};
            var valueObject=value;
            var iterator=(async function*(){try{yield* source}finally{out.push('finally')}})();
            iterator.next().then(function(){
              iterator.return('sent').then(function(result){
                out.push('result:'+result.value+':'+result.done)});
              Promise.resolve().then(function(){out.push('tick 1')})
                .then(function(){out.push('tick 2')})
                .then(function(){out.push('tick 3')})
            });out"))
  (is string= "true,handled,true"
      (evj "var out=[],reason={};
            var source={[Symbol.asyncIterator](){return {
              next(){return {value:1,done:false}},
              return(){return {done:true,value:{then(resolve,reject){reject(reason)}}}}
            }}};
            var iterator=(async function*(){try{yield* source;out.push(false)}
              catch(error){out.push(error===reason);return 'handled'}})();
            iterator.next().then(()=>iterator.return('sent')).then(
              result=>out.push(result.value,result.done));out")))

(define-test async-iteration/for-await-close-precedence
  ;; A non-throw completion is replaced by close failure.
  (is string= "true,1"
      (evj "var out=[],closeError={},closed=0;
            var source={[Symbol.asyncIterator](){return {
              next(){return Promise.resolve({value:1,done:false})},
              return(){closed++;return Promise.reject(closeError)}
            }}};
            (async()=>{try{for await(const x of source){break}}
              catch(e){out.push(e===closeError,closed)}})();out"))
  ;; An in-flight throw retains precedence over every close failure.
  (is string= "true,1"
      (evj "var out=[],bodyError={},closeError={},gets=0;
            var source={[Symbol.asyncIterator](){var iterator={
              next(){return Promise.resolve({value:1,done:false})}};
              Object.defineProperty(iterator,'return',{get(){gets++;throw closeError}});
              return iterator}};
            (async()=>{try{for await(const x of source){throw bodyError}}
              catch(e){out.push(e===bodyError,gets)}})();out")))

(define-test async-iteration/for-await-close-boundary
  (is string= "0"
      (evj "var out=[],closed=0;
            var source={[Symbol.asyncIterator](){return {
              next(){return Promise.resolve({done:true})},
              return(){closed++;return Promise.resolve({done:true})}
            }}};(async()=>{for await(const x of source){}out.push(closed)})();out"))
  (is string= "true"
      (evj "var out=[];
            var source={[Symbol.asyncIterator](){return {
              next(){return Promise.resolve({value:1,done:false})},return:1
            }}};(async()=>{try{for await(const x of source){break}}
              catch(e){out.push(e instanceof TypeError)}})();out")))

(define-test async-iteration/for-await-continue-break-return-order
  (is string= "1,2,0"
      (evj "var out=[],closed=0,index=0;
            var source={[Symbol.asyncIterator](){return {
              next(){index++;return index<3?{value:index,done:false}:{done:true}},
              return(){closed++;return {done:true}}
            }}};
            (async()=>{for await(const value of source){out.push(value);continue}
              out.push(closed)})();out"))
  (is string= "body,return,after,1"
      (evj "var out=[],closed=0;
            var source={[Symbol.asyncIterator](){return {
              next(){return {value:1,done:false}},
              return(){closed++;out.push('return');return {done:true}}
            }}};
            (async()=>{for await(const value of source){out.push('body');break}
              out.push('after',closed)})();out"))
  (is string=
      "next,body,return,tick 1,return then,tick 2,finally,tick 3,settled:done"
      (evj "var out=[];
            var source={[Symbol.asyncIterator](){return {
              next(){out.push('next');return {value:1,done:false}},
              return(){out.push('return');return {then(resolve){
                out.push('return then');resolve({done:true})}}}
            }}};
            async function run(){try{for await(const value of source){
              out.push('body');return 'done'}}finally{out.push('finally')}}
            run().then(value=>out.push('settled:'+value));
            Promise.resolve().then(()=>out.push('tick 1'))
              .then(()=>out.push('tick 2')).then(()=>out.push('tick 3'));out")))

(define-test async-iteration/bounded-async-teardown
  (let* ((realm (eng:make-realm))
         (eng::*realm* realm)
         (source
           "var iterator=(async function*(){try{yield 1}finally{yield 2}})();
            iterator.next();")
         (coroutine nil)
         (thread nil))
    (unwind-protect
         (progn
           (eng::run-program (eng:parse-program source) realm)
           (setf coroutine
                 (eng::js-async-generator-coroutine
                  (eng:js-get (eng:realm-global realm) "iterator"))
                 thread (eng::coro-thread coroutine))
           (true (sb-thread:thread-alive-p thread))
           (eng::teardown-coroutines realm)
           (false (sb-thread:thread-alive-p thread))
           (is = 0 (length (eng::realm-coroutines realm))))
      (eng::teardown-coroutines realm))))

(define-test async-iteration/suspended-start-completion-unregisters
  (flet ((registered-coroutines-after (source)
           (let* ((realm (eng:make-realm))
                  (eng::*realm* realm))
             (unwind-protect
                  (progn
                    (eng::run-program (eng:parse-program source) realm)
                    (let ((iterator (eng::js-get (eng::realm-global realm) "iterator")))
                      (values
                       (length (eng::realm-coroutines realm))
                       (and (eng::js-async-generator-p iterator)
                            (eng::js-async-generator-coroutine iterator)))))
               (eng::teardown-coroutines realm)))))
    (multiple-value-bind (registered coroutine)
        (registered-coroutines-after
         "var iterator=(async function*(){throw 'must not run'})();
          iterator.return(1);")
      (is = 0 registered)
      (is eq :completed (eng::coro-state coroutine))
      (false (eng::coro-thread coroutine)))
    (multiple-value-bind (registered coroutine)
        (registered-coroutines-after
         "var iterator=(async function*(){throw 'must not run'})();
          iterator.throw('stop').catch(function(){});")
      (is = 0 registered)
      (is eq :completed (eng::coro-state coroutine))
      (false (eng::coro-thread coroutine)))
    (is = 0
        (registered-coroutines-after
         "var generators=[];
          for(var i=0;i<32;i++){
            var returned=(async function*(){throw 'must not run'})();
            var thrown=(async function*(){throw 'must not run'})();
            returned.return(i);
            thrown.throw(i).catch(function(){});
            generators.push(returned,thrown)
          }"))))
