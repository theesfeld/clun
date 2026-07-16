;;;; arguments-tests.lisp -- focused mapped/unmapped arguments-object tests.

(in-package :clun-test)

(define-test arguments/mapped-aliasing
  (is string= "1,2,3,4,4"
      (ev "(function(a,b){var before=arguments[0]+','+arguments[1];a=3;var p=arguments[0];arguments[1]=4;return before+','+p+','+b+','+arguments[1]})(1,2)"))
  (is string= "2,8,7"
      (ev "(function(a,a){arguments[0]=7;var before=a;arguments[1]=8;return before+','+a+','+arguments[0]})(1,2)"))
  (is string= "false,1"
      (ev "(function(a,b){b=9;return arguments.hasOwnProperty('1')+','+arguments.length})(1)")))

(define-test arguments/mapped-definition-and-detachment
  (is string= "2,3"
      (ev "(function(a){delete arguments[0];a=2;arguments[0]=3;return a+','+arguments[0]})(1)"))
  (is string= "6,5"
      (ev "(function(a){Object.defineProperty(arguments,'0',{value:5,writable:false});a=6;return a+','+arguments[0]})(1)"))
  (is string= "8,7"
      (ev "(function(a){Object.defineProperty(arguments,'0',{get:function(){return 7},configurable:true});a=8;return a+','+arguments[0]})(1)"))
  (is string= "2,false"
      (ev "(function(a){Object.defineProperty(arguments,'0',{configurable:false});a=2;return arguments[0]+','+Object.getOwnPropertyDescriptor(arguments,'0').configurable})(1)"))
  (is eql 4d0
      (ev "(function(a){Object.defineProperty(arguments,'0',{configurable:false});try{Object.defineProperty(arguments,'0',{configurable:true})}catch(e){}a=4;return arguments[0]})(1)")))

(define-test arguments/unmapped-strict-and-nonsimple
  (is string= "2,3"
      (ev "(function(a){'use strict';a=2;arguments[0]=3;return a+','+arguments[0]})(1)"))
  (is string= "2,3"
      (ev "(function(a=1){a=2;arguments[0]=3;return a+','+arguments[0]})(1)"))
  (is string= "2,3"
      (ev "(function(...a){a[0]=2;arguments[0]=3;return a[0]+','+arguments[0]})(1)"))
  (is eq eng:+true+
      (ev "(function(a=1){try{arguments.callee}catch(e){return e instanceof TypeError}return false})()")))

(define-test arguments/descriptors-and-callee
  (is eq eng:+true+
      (ev "function f(){var c=Object.getOwnPropertyDescriptor(arguments,'callee'),l=Object.getOwnPropertyDescriptor(arguments,'length'),i=Object.getOwnPropertyDescriptor(arguments,Symbol.iterator);return c.value===f&&c.writable&&!c.enumerable&&c.configurable&&l.value===1&&l.writable&&!l.enumerable&&l.configurable&&i.value===Array.prototype.values&&i.writable&&!i.enumerable&&i.configurable&&Object.getOwnPropertyDescriptor(arguments,'caller')===undefined}f(1)"))
  (is eq eng:+true+
      (ev "(function(){'use strict';var d=Object.getOwnPropertyDescriptor(arguments,'callee'),g=false,s=false;try{arguments.callee}catch(e){g=e instanceof TypeError}try{arguments.callee=1}catch(e){s=e instanceof TypeError}return d.get===d.set&&!d.enumerable&&!d.configurable&&g&&s&&Object.getOwnPropertyDescriptor(arguments,'caller')===undefined})()"))
  (is eq eng:+false+ (ev "(function(){return delete arguments})()")))
