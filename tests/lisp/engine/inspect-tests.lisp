;;;; inspect-tests.lisp — the shared inspector (Phase 08). Asserts exact Bun-flavored
;;;; strings for each value kind (double-quoted strings, multiline objects + trailing
;;;; comma, inline arrays, [Object ...] at depth, [Circular], wrappers, Promise).

(in-package :clun-test)

(defun insp (src)
  "Eval SRC in a fresh realm and inspect the completion value in that realm."
  (let* ((realm (eng:make-realm))
         (v (eng:eval-source src :realm realm)))
    (let ((eng::*realm* realm)) (eng:inspect-value v))))

(define-test inspect/primitives
  (is equal "123" (insp "123"))
  (is equal "-0" (insp "-0"))
  (is equal "123.567" (insp "123.567"))
  (is equal "true" (insp "true"))
  (is equal "false" (insp "false"))
  (is equal "null" (insp "null"))
  (is equal "undefined" (insp "undefined"))
  (is equal "Infinity" (insp "1/0"))
  (is equal "-Infinity" (insp "-1/0"))
  (is equal "NaN" (insp "0/0"))
  (is equal "\"hi\"" (insp "'hi'"))
  (is equal "\"a\\nb\"" (insp "'a\\nb'"))
  (is equal "Symbol(desc)" (insp "Symbol('desc')")))

(define-test inspect/arrays-inline
  (is equal "[ 123, 456, 789 ]" (insp "[123,456,789]"))
  (is equal "[]" (insp "[]"))
  (is equal "[ 1, \"two\", true ]" (insp "[1,'two',true]"))
  ;; holes coalesce
  (is equal "[ <2 empty items>, 5 ]" (insp "var a=[]; a[2]=5; a")))

(define-test inspect/objects-multiline
  (is equal (format nil "{~%  a: \"\",~%}") (insp "({a:''})"))
  (is equal (format nil "{~%  name: \"foo\",~%}") (insp "({name:'foo'})"))
  (is equal (format nil "{~%  a: 123,~%  b: 456,~%}") (insp "({a:123,b:456})"))
  (is equal "{}" (insp "({})"))
  ;; quoted keys when non-identifier
  (is equal (format nil "{~%  \"a-b\": 1,~%}") (insp "({'a-b':1})")))

(define-test inspect/nested-and-depth
  (is equal (format nil "{~%  a: {~%    b: 1,~%  },~%}") (insp "({a:{b:1}})"))
  ;; default depth is 2 → level3 collapses to [Object ...]
  (is equal (format nil "{~%  l1: {~%    l2: {~%      l3: [Object ...],~%    },~%  },~%}")
      (insp "({l1:{l2:{l3:{x:1}}}})")))

(define-test inspect/functions-and-wrappers
  (is equal "[Function: foo]" (insp "(function foo(){})"))
  (is equal "[Function]" (insp "(function(){})"))
  (is equal "[Number: 5]" (insp "new Number(5)"))
  (is equal "[String: \"hi\"]" (insp "new String('hi')"))
  (is equal "[Boolean: true]" (insp "new Boolean(true)")))

(define-test inspect/promise-map-set
  (is equal "Promise { <pending> }" (insp "new Promise(()=>{})"))
  (is equal "Promise { 5 }" (insp "Promise.resolve(5)"))
  (is equal "Map(2) { \"a\": 1, \"b\": 2 }" (insp "new Map([['a',1],['b',2]])"))
  (is equal "Set(2) { 1, 2 }" (insp "new Set([1,2])")))

(define-test inspect/accessors-and-class-name
  ;; getter-only / setter-only / both — not always [Getter/Setter] (review #1)
  (is equal (format nil "{~%  x: [Getter],~%}") (insp "({get x(){return 1}})"))
  (is equal (format nil "{~%  y: [Setter],~%}") (insp "({set y(v){}})"))
  (is equal (format nil "{~%  z: [Getter/Setter],~%}") (insp "({get z(){return 1},set z(v){}})"))
  ;; class instance keeps its name even with an explicit constructor (review #2)
  (is equal (format nil "P {~%  p: 1,~%}") (insp "class P{constructor(){this.p=1}}; new P()"))
  (is equal "Bar {}" (insp "class Bar{}; new Bar()")))

(define-test inspect/circular
  ;; a self-referential object shows [Circular]; shared-but-acyclic renders fully
  (is equal (format nil "{~%  self: [Circular],~%}") (insp "var o={}; o.self=o; o"))
  (is equal (format nil "{~%  x: {~%    n: 1,~%  },~%  y: {~%    n: 1,~%  },~%}")
      (insp "var c={n:1}; ({x:c,y:c})")))
