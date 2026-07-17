;;;; eval-tests.lisp — end-to-end evaluator tests (Phase 03).

(in-package :clun-test)

(defun ev (src) (eng:eval-source src))
(defun evs (src) (eng:eval-source src :strict t))
(defun ev-throws (src)
  "T if SRC throws an uncaught JS exception."
  (handler-case (progn (eng:eval-source src) nil)
    (eng:js-condition () t)))

(defun ev-error-name (src)
  "The native Error constructor name thrown by SRC, or NIL."
  (let ((realm (eng:make-realm)))
    (let ((eng:*realm* realm))
      (handler-case (progn (eng:eval-source src :realm realm) nil)
        (eng:js-condition (condition)
          (if (typep condition 'eng:js-native-error)
              (eng:js-native-error-name (eng:js-native-error-kind condition))
              (let ((value (eng:js-condition-value condition)))
                (and (eng:js-object-p value)
                     (eng:to-string (eng:js-get value "name"))))))))))

(define-test eval/arithmetic
  (is eql 7d0 (ev "1 + 2 * 3"))
  (is eql 6d0 (ev "2 ** 3 - 2"))
  (is eql 1d0 (ev "7 % 3"))
  (is eql 4d0 (ev "let x = 2; x *= 2; x"))
  (is eql -5d0 (ev "-(2 + 3)"))
  (is eql 8d0 (ev "1 << 3"))
  (is eql 5d0 (ev "0b101"))
  (is eql 3d0 (ev "typeof x === 'undefined' ? 3 : 4")))

(define-test eval/strings-and-coercion
  (is string= "hello world" (ev "'hello' + ' ' + 'world'"))
  (is string= "3 apples" (ev "3 + ' apples'"))
  (is eql 42d0 (ev "+'42'"))
  (is string= "number" (ev "typeof 42"))
  (is eq eng:+true+ (ev "1 == '1'"))
  (is eq eng:+false+ (ev "1 === '1'"))
  (is eq eng:+true+ (ev "null == undefined")))

(define-test eval/tagged-templates
  (is string= "a|b|c:1,2"
      (ev "function tag(strings,a,b){return strings.join('|')+':'+a+','+b}tag`a${1}b${2}c`"))
  (is string= "true,true,true,false|false,true,true,false"
      (ev "var first;function tag(strings){if(!first)first=strings;return [first===strings,Object.isFrozen(strings),Object.isFrozen(strings.raw),Object.getOwnPropertyDescriptor(strings,'raw').enumerable].join(',')}var a=tag`x${1}y`;var b=tag`x${2}y`;[a,b].join('|')")
      "each syntactic site has a distinct template object")
  (is string= "true,true,true,false"
      (ev "var seen;function tag(strings){if(!seen)seen=strings;return [seen===strings,Object.isFrozen(strings),Object.isFrozen(strings.raw),Object.getOwnPropertyDescriptor(strings,'raw').enumerable].join(',')}function run(x){return tag`x${x}y`}run(1);run(2)"))
  (is string= "receiver:a,b:7"
      (ev "var object={name:'receiver',tag:function(strings,value){return this.name+':'+strings.join(',')+':'+value}};object.tag`a${7}b`"))
  (is string= "derived:x,y:8"
      (ev "class Base{tag(strings,value){return this.name+':'+strings.join(',')+':'+value}}class Derived extends Base{constructor(){super();this.name='derived'}run(){return super.tag`x${8}y`}}new Derived().run()"))
  (is string= "key,get,sub,call"
      (ev "var log=[];var object={get tag(){log.push('get');return function(strings,value){log.push('call');return log.join(',')}}};function key(){log.push('key');return 'tag'}function sub(){log.push('sub');return 1}object[key()]`x${sub()}y`"))
  (is string= "undefined:true"
      (ev "function tag(strings){var raw=strings.raw[0];return String(strings[0])+':'+(raw.length===2&&raw.charCodeAt(0)===92&&raw.charCodeAt(1)===120)}tag`\\x`"))
  (is string= "TypeError:0"
      (ev "var hit=0,name='';try{({tag:1}).tag`x${hit++}y`}catch(error){name=error.name}name+':'+hit")))

(define-test eval/functions-and-closures
  (is eql 7d0 (ev "function add(a,b){ return a+b; } add(3,4)"))
  (is eql 120d0 (ev "function f(n){ return n<=1 ? 1 : n*f(n-1); } f(5)"))
  (is eql 3d0 (ev "var g = (a,b)=>a+b; g(1,2)"))
  (is eql 11d0 (ev "function mk(){ var c=0; return function(){ return ++c; }; } var i=mk(); i(); i(); i()+8"))
  (is eql 6d0 (ev "(function(a,b,c){ return a+b+c; })(1,2,3)"))
  (is eql 3d0 (ev "function f(){ return arguments.length; } f(1,2,3)"))
  (is eql 15d0 (ev "function sum(){ var t=0; for (var i=0;i<arguments.length;i++) t+=arguments[i]; return t; } sum(1,2,3,4,5)")))

(define-test eval/objects
  (is eql 3d0 (ev "var o={a:1,b:2}; o.a + o.b"))
  (is eql 9d0 (ev "var o={x:4}; o.x=9; o.x"))
  (is eq eng:+true+ (ev "var o={a:1}; 'a' in o"))
  (is eq eng:+false+ (ev "var o={a:1}; 'b' in o"))
  (is string= "value" (ev "var o={}; o['key']='value'; o['key']"))
  (is eql 5d0 (ev "var o={get x(){ return 5; }}; o.x"))
  (is eql 42d0 (ev "var v; var o={set x(n){ v=n; }}; o.x=42; v"))
  (is eql 2d0 (ev "var o={a:1}; var p=Object.create(o); p.a=2; p.a"))
  (is eql 1d0 (ev "var o={a:1}; var p=Object.create(o); p.a")))

(define-test eval/arrays
  (is eql 3d0 (ev "[1,2,3].length"))
  (is string= "2,4,6" (ev "[1,2,3].map(function(x){return x*2;}).join(',')"))
  (is eql 1d0 (ev "[1,2,3].indexOf(2)"))
  (is eql 6d0 (ev "var t=0; [1,2,3].forEach(function(x){t+=x;}); t"))
  (is eql 4d0 (ev "var a=[1,2]; a.push(3,4); a.length"))
  (is eql 3d0 (ev "var a=[1,2,3]; a.pop()"))
  (is eq eng:+true+ (ev "Array.isArray([1,2,3])"))
  (is eq eng:+false+ (ev "Array.isArray({})"))
  (is string= "b,c" (ev "[1,2,3,'a','b','c'].slice(4).join(',')")))

(define-test eval/control-flow
  (is eql 10d0 (ev "var s=0; for(var i=0;i<5;i++) s+=i; s"))
  (is eql 15d0 (ev "var s=0,i=0; while(i<6){ s+=i; i++; } s"))
  (is eql 6d0 (ev "var s=0; for(var i=0;i<10;i++){ if(i>3) break; s+=i; } s"))
  (is eql 20d0 (ev "var s=0; for(var i=0;i<10;i++){ if(i%2) continue; s+=i; } s"))
  (is string= "two" (ev "var x=2; var r; switch(x){ case 1: r='one'; break; case 2: r='two'; break; default: r='?'; } r"))
  (is eql 6d0 (ev "var s=0; outer: for(var i=0;i<3;i++){ for(var j=0;j<3;j++){ if(j===2) continue outer; s+=1; } } s"))
  (is eql 3d0 (ev "var s=0; for(var k of [1,1,1]) s+=k; s")))

(define-test eval/exceptions
  (is string= "caught" (ev "try { throw 'x'; } catch(e){ } 'caught'"))
  (is string= "oops" (ev "var r; try { throw new Error('oops'); } catch(e){ r=e.message; } r"))
  (is eq eng:+true+ (ev "var ok=false; try { null.x; } catch(e){ ok = e instanceof TypeError; } ok"))
  (is string= "finally" (ev "var r=''; try { r+='t'; } finally { r+='f'; } r==='tf' ? 'finally' : 'no'"))
  (true (ev-throws "undefinedVariable"))
  (true (ev-throws "null.foo"))
  (true (ev-throws "'use strict'; x = 1")))

(define-test eval/destructuring-and-spread
  (is eql 3d0 (ev "var [a,b]=[1,2]; a+b"))
  (is eql 5d0 (ev "var {x,y}={x:2,y:3}; x+y"))
  (is eql 5d0 (ev "var [a,...rest]=[1,2,3,4]; rest.length + rest[0]"))
  (is eql 6d0 (ev "function f(...nums){ var t=0; for(var i=0;i<nums.length;i++) t+=nums[i]; return t; } f(1,2,3)"))
  (is eql 10d0 (ev "var a=[1,2]; var b=[3,4]; [...a,...b].reduce ? 10 : 10")))

(define-test eval/iterator-record-basics
  (is string= "1,3,2"
      (ev "var gets=0,calls=0; var src={ [Symbol.iterator]: function(){ return { get next(){ gets++; return function(){ calls++; return calls<3 ? {value:calls,done:false}:{done:true}; }; } }; } }; var a=[...src]; [gets,calls,a.length].join(',')"))
  (is eql 7d0
      (ev "var a=[1,2]; a[Symbol.iterator]=function(){ var done=false; return {next:function(){ if(done)return {done:true}; done=true; return {value:7,done:false}; }}; }; [...a][0]"))
  (true (ev-throws "var x={ [Symbol.iterator]: function(){ return {next:function(){return 1;}}; } }; [...x]"))
  (is string= "iter,return,ok"
      (ev "var log=[];var src={ [Symbol.iterator]:function(){log.push('iter');return {next:1,return:function(){log.push('return');return {}}}}};try{var []=src;log.push('ok')}catch(e){log.push(e.name)};log.join(',')"))
  (is string= "TypeError,0"
      (ev "var closed=0,name='';var src={ [Symbol.iterator]:function(){return {next:1,return:function(){closed++;return {}}}}};try{var [x]=src}catch(e){name=e.name};name+','+closed")))

(define-test eval/iterator-done-coercion
  (is eql 0d0
      (ev "var body=0;var src={ [Symbol.iterator]:function(){return {next:function(){return {done:Symbol('done'),value:1}}}}};for(var x of src){body++};body")))

(define-test eval/iterator-close-and-for-of
  (is string= "1,1"
      (ev "var n=0,c=0;var src={ [Symbol.iterator]:function(){return {next:function(){n++;return {value:n,done:false}},return:function(){c++;return {done:true}}}}};for(var x of src){break};[n,c].join(',')"))
  (is eql 7d0
      (ev "var caught=0;var src={ [Symbol.iterator]:function(){return {next:function(){return {value:1,done:false}},return:function(){throw 8}}}};try{for(var x of src){throw 7}}catch(e){caught=e};caught"))
  (is eql 8d0
      (ev "var caught=0;var src={ [Symbol.iterator]:function(){return {next:function(){return {value:1,done:false}},return:function(){throw 8}}}};try{for(var x of src){break}}catch(e){caught=e};caught"))
  (is eql 9d0
      (ev "var caught=0;var src={ [Symbol.iterator]:function(){return {next:function(){return {value:1,done:false}},return:function(){throw 9}}}};try{for(var x of src){try{throw 1}finally{break}}}catch(e){caught=e};caught"))
  (is eql 2d0
      (ev "var caught=0;var src={ [Symbol.iterator]:function(){return {next:function(){return {value:1,done:false}},return:function(){throw 9}}}};try{for(var x of src){try{break}finally{throw 2}}}catch(e){caught=e};caught"))
  (is string= "3,0"
      (ev "var n=0,c=0;var src={ [Symbol.iterator]:function(){return {next:function(){n++;return n<3?{value:n,done:false}:{done:true}},return:function(){c++;return {done:true}}}}};for(var x of src){continue};[n,c].join(',')"))
  (is eql 1d0
      (ev "var c=0;var src={ [Symbol.iterator]:function(){return {next:function(){return {value:1,done:false}},return:function(){c++;return {done:true}}}}};outer:for(var i=0;i<1;i++){for(var x of src){continue outer}};c"))
  (is eql 0d0
      (ev "var c=0;var src={ [Symbol.iterator]:function(){return {next:function(){return {done:false,get value(){throw 4}}},return:function(){c++;return {done:true}}}}};try{for(var x of src){}}catch(e){};c")))

(define-test eval/lazy-array-patterns
  (is string= "0,1"
      (ev "var n=0,c=0;var src={ [Symbol.iterator]:function(){return {next:function(){n++;return {done:true}},return:function(){c++;return {done:true}}}}};var []=src;[n,c].join(',')"))
  (is string= "2,2,1,1"
      (ev "var n=0,v=0,c=0;var src={ [Symbol.iterator]:function(){return {next:function(){n++;var q=n;return {done:false,get value(){v++;return q}}},return:function(){c++;return {done:true}}}}};var [,x]=src;[x,n,v,c].join(',')"))
  (is string= "1:2,3"
      (ev "var a,b;[a,...b]=[1,2,3];[a,b.join(',')].join(':')"))
  (is eql 1d0
      (ev "var hit=0;[{}=(hit=1,{})]=[];hit"))
  (is string= "key,next"
      (ev "var log=[];var o={};var src={ [Symbol.iterator]:function(){return {next:function(){log.push('next');return {value:3,done:false}},return:function(){return {done:true}}}}};[o[(log.push('key'),'x')]]=src;log.join(',')"))
  (is eql 1d0
      (ev "var c=0;var o={set x(v){throw 6}};var src={ [Symbol.iterator]:function(){return {next:function(){return {value:1,done:false}},return:function(){c++;return {done:true}}}}};try{[o.x]=src}catch(e){};c"))
  (is eql 0d0
      (ev "var c=0;var o={set x(v){throw 6}};var src={ [Symbol.iterator]:function(){var n=0;return {next:function(){n++;return n<2?{value:1,done:false}:{done:true}},return:function(){c++;return {done:true}}}}};try{[...o.x]=src}catch(e){};c")))

(define-test eval/parameter-binding-semantics
  (is eql 1d0
      (ev "function f(a=b,b=1){};var hit=0;try{f()}catch(e){hit=1};hit"))
  (is eql 1d0 (ev "function f(a=1,b=a){return b};f()"))
  (is eql 2d0 (ev "function f(a,{b},c=1,d){};f.length"))
  (is string= "x,y"
      (ev "function f({x=function(){},y=class {}}={}){return x.name+','+y.name};f()"))
  (is string= "1,2,3" (ev "function f(){return [...arguments].join(',')};f(1,2,3)"))
  (is eql 1d0
      (ev "var hit=0;try{try{throw []}catch([x=x]){hit=2}}catch(e){hit=1};hit")))

(define-test eval/non-simple-parameter-environments
  (is string= "1,1"
      (ev "function f(a=1,b=a){return a+','+b}f()"))
  (is string= "ReferenceError"
      (ev-error-name "function f(a=a){}f()"))
  (is string= "ReferenceError"
      (ev-error-name "var b=9;function f(a=b,b=2){}f()"))
  (is string= "parameter:outer|body-var:body-function"
      (ev "var outer='outer';function f(parameter='parameter',read=()=>parameter+':'+outer){var parameter='body-var';function outer(){return 'body-function'}return read()+'|'+parameter+':'+outer()}f()"))
  (is string= "default,given"
      (ev "function f(arguments='default'){return arguments}f()+','+f('given')"))
  (is string= "true,body"
      (ev "var arguments='outer';function f(read=()=>arguments){let arguments='body';var value=read();return (typeof value==='object'&&value.length===0)+','+arguments}f()")))

(define-test eval/named-function-expression-environment
  (is string= "true,outer"
      (ev "var Named='outer';var fn=function Named(value=Named){Named='ignored';return value===fn&&Named===fn};[fn(),Named].join(',')"))
  (is string= "TypeError,outer"
      (ev "var Named='outer';var fn=function Named(){'use strict';Named=1};var error;try{fn()}catch(e){error=e.name}[error,Named].join(',')")))

(define-test eval/non-simple-coroutine-and-method-environments
  (let* ((realm (eng:make-realm))
         (log
           (eng:eval-source
            "var body=0,log=[];async function f(value=(function(){throw 'boom'})()){body++}var promise=f();log.push(promise instanceof Promise);promise.catch(function(error){log.push(error+':'+body)});log"
            :realm realm)))
    (let ((eng:*realm* realm))
      (is string= "true,boom:0" (eng:to-string log))))
  (is eql 2d0
      (ev "function* g(value=2){yield value}g().next().value"))
  (is eql 3d0
      (ev "class A{m(value){return value+1}}class B extends A{m(value=2){return super.m(value)}}new B().m()"))
  (is eql 4d0
      (ev "var base={m(value){return value+2}};var object={__proto__:base,m(value=2){return super.m(value)}};object.m()"))
  (is eql 5d0
      (ev "class A{constructor(value){this.value=value}}class B extends A{constructor(value=5){super(value)}}new B().value")))

(define-test eval/function-environment-off-eager-parity
  (dolist (case
           (list
            (cons "parameter/body split"
                  "var outer='outer';function f(parameter='parameter',read=()=>parameter+':'+outer){var parameter='body-var';function outer(){return 'body-function'}return read()+'|'+parameter+':'+outer()}f()")
            (cons "named-expression binding"
                  "var Named='outer';var fn=function Named(value=Named){Named='ignored';return value===fn&&Named===fn};[fn(),Named].join(',')")))
    (let ((off (let ((eng::*compile-tier-mode* :off)) (ev (cdr case))))
          (eager (let ((eng::*compile-tier-mode* :eager)) (ev (cdr case)))))
      (is equal off eager "off/eager parity for ~a" (car case)))))

(define-test eval/function-final-regressions
  (is string= "first,second,body"
      (ev "var log=[];var first={toString(){log.push('first');return 'a'}},second={toString(){log.push('second');return 'b'}},body={toString(){log.push('body');return 'return a+b'}};Function(first,second,body);log.join(',')"))
  (is string= "SyntaxError"
      (ev-error-name "Function('eval','\"use strict\";')"))
  (is string= "SyntaxError"
      (ev-error-name "Function('arguments','\"use strict\";')"))
  (dolist (source '("'use strict';eval=1"
                    "'use strict';arguments=1"
                    "'use strict';eval++"
                    "'use strict';++arguments"
                    "'use strict';[eval]=[1]"
                    "'use strict';({value:arguments}={value:1})"))
    (is string= "SyntaxError" (ev-error-name source)))
  (is eq eng:+false+
      (ev "Function.prototype[Symbol.hasInstance].call({}, {})"))
  (is string= "TypeError"
      (ev-error-name "({}) instanceof ({})"))
  (is string= "true,TypeError"
      (ev "function sloppy(){}function strict(){'use strict'}var error='none';try{strict.caller}catch(e){error=e.name}[sloppy.caller===undefined,error].join(',')"))
  (is string= "function /* a */ f /* b */ ( /* c */ x /* d */ , /* e */ y /* f */ ) /* g */ { /* h */ ; /* i */ ; /* j */ }"
      (ev "function /* a */ f /* b */ ( /* c */ x /* d */ , /* e */ y /* f */ ) /* g */ { /* h */ ; /* i */ ; /* j */ }f.toString()"))
  (is string= "( /* a */ a /* b */ , /* c */ b /* d */ ) /* e */ => /* f */ { /* g */ ; /* h */ }"
      (ev "var f=( /* a */ a /* b */ , /* c */ b /* d */ ) /* e */ => /* f */ { /* g */ ; /* h */ };f.toString()"))
  (is string= "[ /* a */ \"f\" /* b */ ] /* c */ ( /* d */ ) /* e */ { /* f */ }"
      (ev "var f={ [ /* a */ \"f\" /* b */ ] /* c */ ( /* d */ ) /* e */ { /* f */ } }.f;f.toString()"))
  (is string= "f /* a */ ( /* b */ ) /* c */ { /* d */ }"
      (ev "class F { f /* a */ ( /* b */ ) /* c */ { /* d */ } }F.prototype.f.toString()")))

(define-test eval/dynamic-function-segment-boundaries
  ;; FormalParameters and FunctionBody are distinct parse goals. An unterminated
  ;; parameter comment cannot consume the wrapper boundary and close in the body.
  (is string= "SyntaxError"
      (ev-error-name "Function('/*','*/ ) {')"))
  (is eql 7d0
      (ev "Function('/* parameter */ value','/* body */ return value')(7)"))
  ;; Keep the existing observable order: parameter conversions, body conversion,
  ;; then newTarget.prototype. Abrupt conversion prevents later observations.
  (is string= "parameter,body,prototype,true"
      (ev "var log=[],parameter={toString(){log.push('parameter');return 'value'}},body={toString(){log.push('body');return 'return value'}};var NT=(function(){}).bind(null);Object.defineProperty(NT,'prototype',{get(){log.push('prototype');return Function.prototype}});var fn=Reflect.construct(Function,[parameter,body],NT);log.push(Object.getPrototypeOf(fn)===Function.prototype);log.join(',')"))
  (is string= "parameter,true"
      (ev "var marker={},log=[],parameter={toString(){log.push('parameter');throw marker}},body={toString(){log.push('body');return ''}};var NT=(function(){}).bind(null);Object.defineProperty(NT,'prototype',{get(){log.push('prototype');return Function.prototype}});try{Reflect.construct(Function,[parameter,body],NT)}catch(e){log.push(e===marker)}log.join(',')")))

(define-test eval/lexical-assignment-semantics
  (is eql 1d0
      (ev "var hit=0;try{0,[x]=[]}catch(e){hit=e.name==='ReferenceError'?1:2};let x;hit"))
  (is eql 1d0
      (ev "const c=null;var hit=0;try{[c]=[1]}catch(e){hit=e.name==='TypeError'?1:2};hit"))
  (is eql 1d0
      (ev "const x=1;function f(){return x};f()"))
  (is eql 1d0
      (ev "const x=1;{let x=2;x=3};x")))

(define-test eval/global-lexical-tdz-and-indirect-eval
  (is string= "ReferenceError" (ev-error-name "let x=x+1"))
  (is string= "ReferenceError" (ev-error-name "x;let x"))
  (is string= "ReferenceError" (ev-error-name "const x=x+1"))
  (is string= "ReferenceError" (ev-error-name "x;const x=1"))
  (is string= "outside,outside"
      (ev "var a,b;let x='outside';{let x='inside';a=(0,eval)('x');b=(0,eval)('\"use strict\";x')}[a,b].join(',')"))
  (is string= "outside,undefined"
      (ev "let x='outside';(0,eval)(\"let y='eval';[(0,eval)('x'),(0,eval)('typeof y')].join(',')\")")))

(define-test eval/top-level-function-captures-script-lexical
  (let ((realm (eng:make-realm)))
    (eng:eval-source "let x=7;function f(){return x}" :realm realm)
    (is eql 7d0 (eng:eval-source "f()" :realm realm))))

(define-test eval/active-script-lexicals-restored
  (let ((realm (eng:make-realm)))
    (eng:eval-source
     "var seen;let x=1;Promise.resolve().then(function(){seen=(0,eval)('typeof x')})"
     :realm realm)
    (is string= "undefined" (eng:eval-source "seen" :realm realm))
    (is eq nil (eng::realm-active-script-lexical-environment realm))
    (is equal '() (eng::realm-active-script-lexical-scopes realm))
    (true
     (handler-case
         (progn (eng:eval-source "let x=1;throw new Error('boom')" :realm realm) nil)
       (eng:js-condition () t)))
    (is eq nil (eng::realm-active-script-lexical-environment realm))
    (is equal '() (eng::realm-active-script-lexical-scopes realm))))

(define-test eval/iterable-consumer-close
  (is eql 1d0
      (ev "var c=0;var src={ [Symbol.iterator]:function(){return {next:function(){return {value:1,done:false}},return:function(){c++;return {done:true}}}}};try{Array.from(src,function(){throw 2})}catch(e){};c"))
  (is eql 1d0
      (ev "var c=0;var src={ [Symbol.iterator]:function(){return {next:function(){return {value:1,done:false}},return:function(){c++;return {done:true}}}}};try{Object.fromEntries(src)}catch(e){};c"))
  (is eql 1d0
      (ev "var c=0;Map.prototype.set=function(){throw 3};var src={ [Symbol.iterator]:function(){return {next:function(){return {value:[1,2],done:false}},return:function(){c++;return {done:true}}}}};try{new Map(src)}catch(e){};c"))
  (is eql 1d0
      (ev "var c=0;Promise.resolve=function(){throw 3};var src={ [Symbol.iterator]:function(){return {next:function(){return {value:1,done:false}},return:function(){c++;return {done:true}}}}};Promise.all(src).catch(function(){});c"))
  (is eql 0d0
      (ev "var c=0;var src={ [Symbol.iterator]:function(){return {next:function(){throw 3},return:function(){c++;return {done:true}}}}};try{Array.from(src)}catch(e){};c"))
  (is string= "false,false,false"
      (ev "var d=Object.getOwnPropertyDescriptor(Symbol,'iterator');[d.writable,d.enumerable,d.configurable].join(',')"))
  (is string= "Symbol(x)" (ev "String(Symbol('x'))"))
  (is string= "4" (ev "String.prototype[Symbol.iterator].call(42).next().value")))

(define-test eval/prototype-and-instanceof
  (is eq eng:+true+ (ev "function C(){} var c=new C(); c instanceof C"))
  (is eql 42d0 (ev "function C(){ this.v=42; } new C().v"))
  (is eql 99d0 (ev "function C(){} C.prototype.m=function(){ return 99; }; new C().m()"))
  (is eq eng:+true+ (ev "[] instanceof Array"))
  (is eq eng:+true+ (ev "({}) instanceof Object")))

(define-test eval/classes
  (is eql 42d0 (ev "class C { constructor(){ this.v=42; } } new C().v"))
  (is eql 15d0 (ev "class C { add(a,b){ return a+b; } } new C().add(7,8)"))
  (is eql 7d0 (ev "class C { get x(){ return 7; } } new C().x"))
  (is eql 5d0 (ev "class A { m(){ return 5; } } class B extends A {} new B().m()")))

(define-test eval/class-constructor-semantics
  (is string= "TypeError" (ev-error-name "class C{};C()"))
  (is string= "TypeError,TypeError,TypeError"
      (ev "class C{m(){}get x(){}set x(v){}}var d=Object.getOwnPropertyDescriptor(C.prototype,'x'),r=[];for(var f of [C.prototype.m,d.get,d.set]){try{Reflect.construct(f,[]);r.push('no error')}catch(e){r.push(e.name)}}r.join(',')"))
  (is eql 1d0
      (ev "class C{constructor(){this.value=1;return 2}}new C().value"))
  (is eql 2d0
      (ev "class C{constructor(){return {value:2}}}new C().value"))
  (is eql 3d0
      (ev "class A{}class C extends A{constructor(){return {value:3}}}new C().value"))
  (is string= "TypeError"
      (ev-error-name "class A{}class C extends A{constructor(){return 1}}new C()"))
  (is string= "ReferenceError"
      (ev-error-name "class A{}class C extends A{constructor(){}}new C()"))
  (is string= "ReferenceError"
      (ev-error-name "class A{}class C extends A{constructor(){this.value=1;super()}}new C()"))
  (is string= "ReferenceError"
      (ev-error-name "class A{}class C extends A{constructor(){super();super()}}new C()"))
  (is eq eng:+true+
      (ev "var seen;class A{constructor(){seen=new.target}}class C extends A{}var value=new C();seen===C&&value instanceof C"))
  (is eq eng:+true+
      (ev "class A{constructor(){this.seen=new.target}}class C extends A{constructor(){super()}}function N(){}var value=Reflect.construct(C,[],N);value.seen===N&&Object.getPrototypeOf(value)===N.prototype")))

(define-test eval/class-super-property-semantics
  (is string= "4,b!,7,7,8,get:b|set:b:7|get:b|set:b:8"
      (ev "var log=[];class A{get x(){log.push('get:'+this.tag);return this._x}set x(v){log.push('set:'+this.tag+':'+v);this._x=v}m(v){return this.tag+v}}class B extends A{read(){return super.x}call(v){return super.m(v)}write(v){super.x=v;return this._x}bump(){return super.x++}}var b=new B();b.tag='b';b._x=4;[b.read(),b.call('!'),b.write(7),b.bump(),b._x,log.join('|')].join(',')"))
  (is string= "2,B,5,5,6"
      (ev "class A{static get x(){return this._x}static set x(v){this._x=v}static m(){return this.tag}}class B extends A{static read(){return super.x}static call(){return super.m()}static write(v){super.x=v;return this._x}static bump(){return super.x++}}B.tag='B';B._x=2;[B.read(),B.call(),B.write(5),B.bump(),B._x].join(',')"))
  (is eql 1d0
      (ev "var oldBase={x:1},newBase={x:2};class A{}class B extends A{read(key){return super[key]}}Object.setPrototypeOf(B.prototype,oldBase);var key={toString(){Object.setPrototypeOf(B.prototype,newBase);return 'x'}};new B().read(key)")))

(define-test eval/delete-super-semantics
  (is string= "ReferenceError"
      (ev-error-name "var object={m(){delete super.x}};object.m()"))
  ;; A null super base is not coerced before delete rejects the SuperReference.
  (is string= "ReferenceError"
      (ev-error-name "class C{static m(){delete super.x}}Object.setPrototypeOf(C,null);C.m()"))
  ;; GetThisBinding precedes the computed expression in a derived constructor.
  (is string= "ReferenceError,false"
      (ev "var ran=false;class C extends Object{constructor(){try{delete super[(ran=true,0)]}catch(error){return {name:error.name}}}}var value=new C();value.name+','+ran"))
  ;; The key expression is evaluated, but delete rejects before ToPropertyKey.
  (is string= "ReferenceError,1,0"
      (ev "var evaluated=0,coerced=0,key={toString(){coerced++;return 'x'}},object={m(){try{delete super[(evaluated++,key)]}catch(error){return error.name+','+evaluated+','+coerced}}};object.m()"))
  (is string= "TypeError"
      (ev-error-name "var object={m(){delete super[(function(){throw new TypeError()})()]}};object.m()")))

(define-test eval/class-name-and-heritage-semantics
  (is string= "ReferenceError"
      (ev-error-name "var D=Object;var C=class D extends D{}"))
  (is string= "TypeError"
      (ev-error-name "var C=class Inner{static mutate(){Inner=1}};C.mutate()"))
  (is eq eng:+true+
      (ev "var C=class Inner{static self(){return Inner}};C.self()===C&&typeof Inner==='undefined'"))
  (is string= "TypeError" (ev-error-name "class C extends 1{}"))
  (is string= "TypeError"
      (ev-error-name "function F(){}F.prototype=1;class C extends F{}"))
  (is eq eng:+true+
      (ev "class C extends null{}Object.getPrototypeOf(C.prototype)===null"))
  (is string= "TypeError"
      (ev-error-name "class C{static ['prototype'](){}}")))

(define-test eval/class-builtin-regressions
  (is string= "argument,TypeError"
      (ev "var log=[];class A{}class B extends A{constructor(){super(log.push('argument'))}}Object.setPrototypeOf(B,{});try{new B()}catch(e){log.push(e.name)}log.join(',')"))
  (is string= "|get |set "
      (ev "var method=Symbol(),accessor=Symbol();var object={[method](){},get [accessor](){},set [accessor](value){}};var descriptor=Object.getOwnPropertyDescriptor(object,accessor);[object[method].name,descriptor.get.name,descriptor.set.name].join('|')"))
  (is string= "[method]|get [accessor]|set [accessor]"
      (ev "var method=Symbol('method'),accessor=Symbol('accessor');var object={[method](){},get [accessor](){},set [accessor](value){}};var descriptor=Object.getOwnPropertyDescriptor(object,accessor);[object[method].name,descriptor.get.name,descriptor.set.name].join('|')"))
  (is eq eng:+true+
      (ev "class R extends RegExp{}var value=new R('a','g');Object.getPrototypeOf(value)===R.prototype&&value instanceof R&&value instanceof RegExp"))
  (is string= "true,TypeError"
      (ev "class C extends Symbol{}var error='none';try{new C()}catch(e){error=e.name}[(typeof C==='function'&&Object.getPrototypeOf(C)===Symbol),error].join(',')")))

(define-test eval/class-source-span-regressions
  (is string= "[ /* key */ \"f\" ] /* gap */(){ /* body */ }"
      (ev "class C { static /* omitted */ [ /* key */ \"f\" ] /* gap */(){ /* body */ } }C.f.toString()"))
  (is string= "async /* gap */ f /* args */(){ /* body */ }"
      (ev "class C { static /* omitted */ async /* gap */ f /* args */(){ /* body */ } }C.f.toString()"))
  (is string= "get /* gap */ f(){ /* body */ }"
      (ev "class C { static /* omitted */ get /* gap */ f(){ /* body */ } }Object.getOwnPropertyDescriptor(C,'f').get.toString()"))
  (is string= "set /* gap */ f(value){ /* body */ }"
      (ev "class C { static /* omitted */ set /* gap */ f(value){ /* body */ } }Object.getOwnPropertyDescriptor(C,'f').set.toString()"))
  (is string= "* /* gap */ f(){ /* body */ }"
      (ev "class C { static /* omitted */ * /* gap */ f(){ /* body */ } }C.f.toString()"))
  (is string= "class /* a */ C /* b */ extends /* c */ B /* d */ { /* e */ constructor /* f */(){ /* g */ } /* h */ m(){ /* i */ } }"
      (ev "function B(){}class /* a */ C /* b */ extends /* c */ B /* d */ { /* e */ constructor /* f */(){ /* g */ } /* h */ m(){ /* i */ } }C.toString()"))
  (is string= "class /* a */ Inner /* b */ { /* c */ constructor /* d */(){ /* e */ } /* f */ m(){ /* g */ } }"
      (ev "var C=class /* a */ Inner /* b */ { /* c */ constructor /* d */(){ /* e */ } /* f */ m(){ /* g */ } };C.toString()")))

(define-test eval/object-super-home-object
  (is string= "true,1,o,4,4,5,15,o2"
      (ev "var p1={get x(){return this._x},set x(v){this._x=v},m(){return this.tag}};var p2={get x(){return this._x+10},set x(v){this._x=v+10},m(){return this.tag+'2'}};var o={__proto__:p1,_x:1,tag:'o',read(){return super.x},call(){return super.m()},write(v){super.x=v;return this._x},bump(){return super.x++}};var first=[Object.getPrototypeOf(o)===p1,o.read(),o.call(),o.write(4),o.bump(),o._x];Object.setPrototypeOf(o,p2);first.concat([o.read(),o.call()]).join(',')")))

(define-test eval/strict-vs-sloppy
  ;; sloppy: undeclared assignment creates a global; strict: throws
  (is eq eng:+true+ (evs "(function(){ 'use strict'; return this === undefined; })()"))
  (is eq eng:+true+ (ev "(function(){ return this === globalThis; })()"))
  (true (ev-throws "'use strict'; undeclaredStrict = 5")))
