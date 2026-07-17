;;;; builtins-tests.lisp — Phase 04 stdlib end-to-end tests. Beyond a broad sanity
;;;; sweep, every case flagged by the Phase 04 adversarial review panel is locked
;;;; here as a regression (see DECISIONS.md 2026-07-11).

(in-package :clun-test)

(define-test builtins/math
  (is eql 3d0 (ev "Math.max(1,2,3)"))
  (is eql 1d0 (ev "Math.min(1,2,3)"))
  (is eql 1024d0 (ev "Math.pow(2,10)"))
  (is eql 4d0 (ev "Math.floor(4.7)"))
  (is eql 5d0 (ev "Math.round(4.5)"))
  (is eq eng:+true+ (ev "Number.isNaN(Math.sqrt(-1))"))
  (is eq eng:+true+ (ev "Math.abs(-0) === 0"))
  ;; panel: clz32 near 2^32 must be 0..32, never -1
  (is eql 0d0 (ev "Math.clz32(4294967295)"))
  (is eql 31d0 (ev "Math.clz32(1)"))
  (is eql 32d0 (ev "Math.clz32(0)"))
  ;; panel: log10 exact powers of ten
  (is eql 3d0 (ev "Math.log10(1000)"))
  (is eq eng:+true+ (ev "Math.log10(1000) === 3")))

(define-test builtins/json-roundtrip
  (is string= "{\"a\":1,\"b\":[2,3]}" (ev "JSON.stringify({a:1,b:[2,3]})"))
  (is eql 2d0 (ev "JSON.parse('{\"x\":[1,2,3]}').x[1]"))
  (is string= "[1,2,3]" (ev "JSON.stringify([1,2,3])"))
  (is string= "null" (ev "JSON.stringify(NaN)"))
  ;; panel: empty replacer array = whitelist of no keys
  (is string= "{}" (ev "JSON.stringify({a:1,b:2},[])"))
  (is string= "{\"a\":1}" (ev "JSON.stringify({a:1,b:2},['a'])")))

(define-test builtins/json-parse-eof-is-syntaxerror
  ;; panel: truncated literal/escape at EOF must be a catchable SyntaxError, not a host crash
  (dolist (src '("JSON.parse('tru')" "JSON.parse('nul')" "JSON.parse('fals')"
                 "JSON.parse('\"\\\\')" "JSON.parse('\"\\\\u12')"))
    (true (ev-throws src)))
  (is eq eng:+true+ (ev "(function(){ try { JSON.parse('tru') } catch(e) { return e instanceof SyntaxError } })()")))

(define-test builtins/number-formatting
  (is string= "3.14" (ev "(3.14159).toFixed(2)"))
  (is string= "ff" (ev "(255).toString(16)"))
  (is string= "1010" (ev "(10).toString(2)"))
  ;; panel: toExponential / toPrecision round ties away from zero ("pick larger n")
  (is string= "3e+0" (ev "(2.5).toExponential(0)"))
  (is string= "1.3e+1" (ev "(12.5).toExponential(1)"))
  (is string= "5" (ev "(4.5).toPrecision(1)"))
  (is string= "1.3" (ev "(1.25).toPrecision(2)"))
  (is string= "13" (ev "(12.5).toPrecision(2)"))
  (is string= "3" (ev "(2.5).toPrecision(1)")))

(define-test builtins/string-methods
  (is string= "HELLO" (ev "'Hello'.toUpperCase()"))
  (is string= "hi" (ev "'  hi  '.trim()"))
  (is string= "xxxab" (ev "'ab'.padStart(5,'x')"))
  (is eql 3d0 (ev "'a-b-c'.split('-').length"))
  (is string= "bbb" (ev "'aaa'.replaceAll('a','b')"))
  (is string= "abcabc" (ev "'abc'.repeat(2)"))
  ;; panel: lastIndexOf honors the position argument
  (is eql 1d0 (ev "'canal'.lastIndexOf('a',2)"))
  (is eql 3d0 (ev "'abcabcabc'.lastIndexOf('abc',4)"))
  (is eql 3d0 (ev "'canal'.lastIndexOf('a')")))

(define-test builtins/string-length-guard
  ;; panel: oversized pad/repeat throws RangeError instead of exhausting the heap
  (true (ev-throws "'5'.padStart(1e9,'0')"))
  (true (ev-throws "'5'.padStart(Infinity,'0')"))
  (true (ev-throws "'ab'.repeat(1e9)"))
  (is eq eng:+true+ (ev "(function(){ try { '5'.padStart(1e9,'0') } catch(e) { return e instanceof RangeError } })()")))

(define-test builtins/string-well-formed
  (is string= "true,false,false,true"
      (ev "['abc'.isWellFormed(),'\\uD800'.isWellFormed(),'\\uDC00'.isWellFormed(),'\\uD83D\\uDE00'.isWellFormed()].join(',')"))
  (is string= "65533,65,65533,2"
      (ev "var a='\\uD800A'.toWellFormed(),b='\\uDC00'.toWellFormed(),p='\\uD83D\\uDE00'.toWellFormed();[a.charCodeAt(0),a.charCodeAt(1),b.charCodeAt(0),p.length].join(',')"))
  (is string= "isWellFormed,0,toWellFormed,0"
      (ev "[String.prototype.isWellFormed.name,String.prototype.isWellFormed.length,String.prototype.toWellFormed.name,String.prototype.toWellFormed.length].join(',')"))
  (is eq eng:+true+
      (ev "(()=>{var marker={},o={toString(){throw marker}};try{String.prototype.toWellFormed.call(o)}catch(e){return e===marker}})()")))

(define-test builtins/array-methods
  (is string= "1,2,3" (ev "[3,1,2].sort().join(',')"))
  (is string= "2,4" (ev "[1,2,3,4].filter(x=>x%2==0).join(',')"))
  (is eql 6d0 (ev "[1,2,3].reduce((a,b)=>a+b,0)"))
  (is eql 7d0 (ev "var a=[];a.length=5;a[3]=7;a.reduce((a,b)=>a+b)"))
  (is string= "321" (ev "[1,2,3].reduceRight((a,b)=>a+String(b),'')"))
  (true (ev-throws "[].reduce((a,b)=>a+b)"))
  (is string= "2,3" (ev "[1,2,3,4,5].splice(1,2).join(',')"))
  (is string= "1,2,3" (ev "[[1],[2,[3]]].flat(2).join(',')"))
  (is eql 3d0 (ev "Array.from('abc').length"))
  (is eq eng:+true+ (ev "Array.isArray([])")))

(define-test builtins/array-copy-by-change
  (is string= "3,undefined,1,true,true"
      (ev "var a=[1,,3],b=a.toReversed();[b[0],String(b[1]),b[2],1 in b,a!==b].join(',')"))
  (is string= "3,1,2,undefined,undefined"
      (ev "var a=[{k:1,n:1},{k:1,n:2},{k:0,n:3},undefined,,];a.toSorted((x,y)=>x.k-y.k).map(x=>x===undefined?'undefined':x.n).join(',')"))
  (is string= "0,a,b,3:0,1,2,3"
      (ev "var a=[0,1,2,3],b=a.toSpliced(1,2,'a','b');b.join(',')+':'+a.join(',')"))
  (is string= "0,1,9:0,1,2"
      (ev "var a=[0,1,2],b=a.with(-1,9);b.join(',')+':'+a.join(',')"))
  (is string= "type"
      (ev "var log=[],o={get length(){log.push('length');return 0}};try{Array.prototype.toSorted.call(o,{})}catch(e){log.push(e instanceof TypeError?'type':'bad')}log.join(',')"))
  (is string= "RangeError,0"
      (ev "var reads=0,o={length:2**32,get 0(){reads++}};var name;try{Array.prototype.toReversed.call(o)}catch(e){name=e.name}[name,reads].join(',')"))
  (is string= "true,true,true,true"
      (ev "var speciesGets=0,a=[1,2];a.constructor={[Symbol.species]:function(){speciesGets++}};[a.toReversed() instanceof Array,a.toSorted() instanceof Array,a.toSpliced() instanceof Array,a.with(0,3) instanceof Array].join(',')"))
  (is eql 0d0 (ev "var speciesGets=0,a=[1,2];Object.defineProperty(a,'constructor',{get(){speciesGets++;return {}}});a.toReversed();a.toSorted();a.toSpliced();a.with(0,3);speciesGets"))
  (is string= "b,a:length,1,0"
      (ev "var log=[],p=new Proxy({0:'a',1:'b',length:2},{get(t,k){log.push(k);return Reflect.get(t,k)}});Array.prototype.toReversed.call(p).join(',')+':'+log.join(',')")))

(define-test builtins/object-has-own-and-error-brand
  (is string= "true,false,true,false"
      (ev "var s=Symbol(),o=Object.create({x:1});o[s]=2;[Object.hasOwn(o,s),Object.hasOwn(o,'x'),Object.hasOwn({x:1},'x'),Object.hasOwn({},'x')].join(',')"))
  (is eql 0d0
      (ev "var calls=0,key={toString(){calls++;return 'x'}};try{Object.hasOwn(null,key)}catch(e){}calls"))
  (is string= "true,false,x:y"
      (ev "var log=[],p=new Proxy({x:1},{getOwnPropertyDescriptor(t,k){log.push(k);return Reflect.getOwnPropertyDescriptor(t,k)}});[Object.hasOwn(p,'x'),Object.hasOwn(p,'y'),log.join(':')].join(',')"))
  (is string= "true,true,false,false,false"
      (ev "var e=new Error(),p=new Proxy(e,{}),r=Proxy.revocable(e,{});r.revoke();[Error.isError(e),Error.isError(new TypeError()),Error.isError({name:'Error'}),Error.isError(p),Error.isError(r.proxy)].join(',')"))
  (is string= "hasOwn,2,isError,1"
      (ev "[Object.hasOwn.name,Object.hasOwn.length,Error.isError.name,Error.isError.length].join(',')")))

(define-test builtins/array-reduce-near-integer-limit
  ;; Both directions must start immediately without materializing every possible index.
  (is eq eng:+true+
      (ev "(function(){var marker={};var o={0:1,length:Number.MAX_SAFE_INTEGER};try{Array.prototype.reduce.call(o,function(){throw marker;},0);}catch(e){return e===marker;}return false;})()"))
  (is eq eng:+true+
      (ev "(function(){var o={length:Number.MAX_SAFE_INTEGER};var m=Number.MAX_SAFE_INTEGER;o[m-1]=1;o[m-3]=3;var seen=[];try{Array.prototype.reduceRight.call(o,function(a,v,i){a.push([v,i]);if(v===3)throw a;return a;},seen);}catch(a){return a.length===2&&a[0][0]===1&&a[0][1]===m-1&&a[1][0]===3&&a[1][1]===m-3;}})()")))

(define-test builtins/collections
  (is eql 1d0 (ev "var m=new Map();m.set('x',1);m.get('x')"))
  (is eql 3d0 (ev "new Set([1,2,2,3]).size"))
  (is string= "1,2" (ev "[...new Set([1,1,2])].join(',')"))
  (is eql 5d0 (ev "var wm=new WeakMap();var k={};wm.set(k,5);wm.get(k)"))
  ;; panel: Set canonicalizes -0 to +0 (SameValueZero) in the stored element
  (is eq eng:+true+ (ev "var s=new Set();s.add(-0);1/[...s.values()][0] === Infinity"))
  (is eq eng:+true+ (ev "var e=[...new Set([-0]).entries()][0]; 1/e[0]===Infinity && 1/e[1]===Infinity")))

(define-test builtins/date-utc
  (is string= "1970-01-01T00:00:00.000Z" (ev "new Date(0).toISOString()"))
  (is eql 2020d0 (ev "new Date('2020-01-15T12:30:00Z').getUTCFullYear()"))
  (is eql 946684800000d0 (ev "Date.UTC(2000,0,1)"))
  (is eql 1582934400000d0 (ev "Date.parse('2020-02-29')"))       ; valid leap day
  ;; panel: calendar-invalid days and hour-24-with-nonzero fields are NaN
  (is eq eng:+true+ (ev "Number.isNaN(Date.parse('2021-02-29'))"))
  (is eq eng:+true+ (ev "Number.isNaN(Date.parse('2021-04-31'))"))
  (is eq eng:+true+ (ev "Number.isNaN(Date.parse('2021-01-01T24:30:00Z'))"))
  (is eql 1609545600000d0 (ev "Date.parse('2021-01-01T24:00:00Z')")))  ; 24:00:00 is valid

(define-test builtins/date-realm-clock-override
  (let ((realm (eng:make-realm)))
    (setf (eng:realm-clock-now-ms realm) 42d0)
    (is string= "42,42,1970-01-01T00:00:00.042Z"
        (eng:eval-source
         "[Date.now(),new Date().getTime(),new Date().toISOString()].join(',')"
         :realm realm))))

(define-test builtins/symbol-reflect-uri
  (is eq eng:+true+ (ev "Symbol.for('x') === Symbol.for('x')"))
  (is string= "desc" (ev "Symbol('desc').description"))
  (is string= "a%20b%26c" (ev "encodeURIComponent('a b&c')"))
  (is string= "a b" (ev "decodeURIComponent('a%20b')"))
  (is eql 5d0 (ev "Reflect.apply(function(a,b){return a+b},null,[2,3])"))
  (is eq eng:+true+ (ev "Reflect.has({a:1},'a')")))

(define-test builtins/function-callable-surface
  ;; Function.prototype's foundational properties precede the installed methods.
  (is string= "true,true,true"
      (ev "var p=Object.getOwnPropertyNames(Function.prototype);var l=Object.getOwnPropertyDescriptor(Function.prototype,'length');var n=Object.getOwnPropertyDescriptor(Function.prototype,'name');[p.indexOf('name')===p.indexOf('length')+1,l.value===0&&!l.writable&&!l.enumerable&&l.configurable,n.value===''&&!n.writable&&!n.enumerable&&n.configurable].join(',')"))
  (is string= "true,true,true"
      (ev "var c=Object.getOwnPropertyDescriptor(Function.prototype,'caller');var a=Object.getOwnPropertyDescriptor(Function.prototype,'arguments');[c.get===c.set,c.get===a.get,c.get===a.set].join(',')"))
  (true (ev-throws "Function.prototype.caller"))
  (true (ev-throws "Function.prototype.toString.call({})"))

  ;; Bound functions retain explicit target/this/argument state and metadata.
  (is string= "7:2:3"
      (ev "function f(a,b){return this.x+':'+a+':'+b};f.bind({x:7},2)(3)"))
  (is string= "bound f,1,false,false,true"
      (ev "function f(a,b){};var B=f.bind(null,1);var d=Object.getOwnPropertyDescriptor(B,'length');[B.name,B.length,d.writable,d.enumerable,d.configurable].join(',')"))
  ;; The observable bound name is not a valid NativeFunction property name and
  ;; therefore must not be copied into Function.prototype.toString's fallback.
  (is string= "function () { [native code] }"
      (ev "Function.prototype.toString.call(function f(){}.bind(null))"))
  (is string= "function max() { [native code] }"
      (ev "Function.prototype.toString.call(Math.max)"))
  (is string= "function [Symbol.hasInstance]() { [native code] }"
      (ev "Function.prototype.toString.call(Function.prototype[Symbol.hasInstance])"))
  (is eq eng:+true+
      (ev "function f(){};var p={};Object.setPrototypeOf(f,p);Object.getPrototypeOf(Function.prototype.bind.call(f,null))===p"))
  (true (ev-throws "Function.prototype.bind.call({})"))
  (is eq eng:+true+
      (ev "(function(){var marker={};var f=function(){};Object.defineProperty(f,'name',{get:function(){throw marker}});try{f.bind(null);return false}catch(e){return e===marker}})()"))

  ;; [[Construct]] and OrdinaryHasInstance delegate to a constructable target.
  (is string= "7,true,true"
      (ev "function C(x){this.x=x};var B=C.bind(null,7);var o=new B();[o.x,o instanceof C,o instanceof B].join(',')"))
  ;; Bound-function OrdinaryHasInstance must re-enter InstanceofOperator for
  ;; the target so a custom @@hasInstance wins over prototype-chain matching.
  (is eq eng:+true+
      (ev "function T(){};Object.defineProperty(T,Symbol.hasInstance,{value:function(){return true}});({}) instanceof T.bind(null)"))
  (is eq eng:+false+
      (ev "function F(){};var value=new F();Object.defineProperty(F,Symbol.hasInstance,{value:function(){return false}});value instanceof F.bind(null).bind(null)"))
  (true (ev-throws "new ((()=>{}).bind(null))"))
  (true (ev-throws "class M{m(){}};new ((new M()).m)()"))
  (is eql 1d0 (ev "class C{constructor(){this.x=1}};new C().x")))
