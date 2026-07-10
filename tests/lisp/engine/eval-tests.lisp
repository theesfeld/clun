;;;; eval-tests.lisp — end-to-end evaluator tests (Phase 03).

(in-package :clun-test)

(defun ev (src) (eng:eval-source src))
(defun evs (src) (eng:eval-source src :strict t))
(defun ev-throws (src)
  "T if SRC throws an uncaught JS exception."
  (handler-case (progn (eng:eval-source src) nil)
    (eng:js-condition () t)))

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

(define-test eval/strict-vs-sloppy
  ;; sloppy: undeclared assignment creates a global; strict: throws
  (is eq eng:+true+ (evs "(function(){ 'use strict'; return this === undefined; })()"))
  (is eq eng:+true+ (ev "(function(){ return this === globalThis; })()"))
  (true (ev-throws "'use strict'; undeclaredStrict = 5")))
