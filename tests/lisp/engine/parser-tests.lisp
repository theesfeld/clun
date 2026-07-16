;;;; parser-tests.lisp — parser structural + early-error coverage (Phase 02).

(in-package :clun-test)

(defun sx (src &optional (goal :script))
  "Parse SRC and return the program body as an S-expression."
  (eng:ast->sexp (eng:program-body (eng:parse-program src :source-type goal))))

(defun parses? (src &optional (goal :script))
  (handler-case (progn (eng:parse-program src :source-type goal) t)
    (eng:js-native-error () nil)))

(define-test parser/expressions
  (is equal '((:expr (:binary "+" (:num 1d0) (:binary "*" (:num 2d0) (:num 3d0)))))
      (sx "1 + 2 * 3;"))
  (is equal '((:expr (:binary "**" (:num 2d0) (:binary "**" (:num 3d0) (:num 4d0)))))
      (sx "2 ** 3 ** 4;"))                    ; ** is right-associative
  (is equal '((:expr (:cond (:id "a") (:id "b") (:id "c")))) (sx "a ? b : c;"))
  (is equal '((:expr (:logical "||" (:logical "&&" (:id "a") (:id "b")) (:id "c"))))
      (sx "a && b || c;")))                   ; && binds tighter than ||: (a&&b)||c

(define-test parser/member-call-new
  (is equal '((:expr (:call (:member :dot (:id "a") (:id "b")) ((:num 1d0)))))
      (sx "a.b(1);"))
  (is equal '((:expr (:new (:id "A") ((:num 1d0))))) (sx "new A(1);"))
  (is equal '((:expr (:member :computed (:id "a") (:str "k")))) (sx "a['k'];")))

(define-test parser/functions-and-arrows
  (is equal '((:function "f" ((:id "a") (:default (:id "b") (:num 1d0)) (:rest (:id "r")))
                         (:block ((:return (:id "a"))))))
      (sx "function f(a, b = 1, ...r) { return a; }"))
  (is equal '((:expr (:arrow ((:id "x")) (:binary "+" (:id "x") (:num 1d0)))))
      (sx "x => x + 1;"))
  (is equal '((:expr (:arrow :async ((:id "x")) (:await (:id "x")))))
      (sx "async x => await x;")))

(define-test parser/destructuring
  (is equal '((:var-decl :const
               ((:declarator (:object-pat ((:prop :init (:id "a") (:id "a"))
                                           (:prop :init (:id "b")
                                                  (:array-pat ((:id "c") (:rest (:id "d")))))))
                            (:id "o")))))
      (sx "const {a, b: [c, ...d]} = o;")))

(define-test parser/template-and-regexp
  (is equal '((:expr (:template ((:quasi "a") (:quasi "b") (:quasi "c"))
                                ((:num 1d0) (:num 2d0)))))
      (sx "`a${1}b${2}c`;"))
  (is equal '((:expr (:call (:member :dot (:regexp "ab+c" "g") (:id "test")) ((:id "s")))))
      (sx "/ab+c/g.test(s);")))

(define-test parser/classes-modules
  (true (parses? "class A extends B { constructor(){ super(); } static m(){} get x(){return 1;} }"))
  (true (parses? "import a, {b, c as d} from 'm'; export {a}; export default 1;" :module))
  (true (parses? "export const x = 1; export * from 'm';" :module)))

(define-test parser/asi
  ;; postfix ++ can't cross a newline -> `a; ++b;` (two statements), not `(a++) b`
  (is equal '((:expr (:id "a")) (:expr (:update "++" :pre (:id "b"))))
      (sx (format nil "a~%++b"))))

(define-test parser/negative-basic
  (dolist (bad '("if (x) else y;" "return 1;" "var 1;" "-a ** b;" "for (;) {}"
                 "{ let x; let x; }" "const x;" "break;" "1 = 2;"
                 "function f(){ continue; }" "for (let x = 1 of y) {}"
                 "for (let a, b in y) {}" "'\\x';"))
    (false (parses? bad))))

(define-test parser/positive-should-parse
  (dolist (ok '("var x, y = 1;" "label: for(;;) break label;"
                "try {} catch {} " "try {} catch (e) {}" "do x; while (y);"
                "switch(x){ case 1: break; default: }" "with(o){}"
                "a, b, c;" "!function(){}();" "({a, b} = c);" "[a, b] = c;"
                "[{} = value] = source;" "[{a} = value] = source;"
                "typeof void delete x.y;" "function f(){ new.target; }" "yield;"))
    (true (parses? ok))))

(define-test parser/early-errors
  ;; these must all be rejected (parser-level early errors)
  (dolist (bad '("(a, a) => {}" "(x = 0, x) => {}" "'use strict'; function f(a, a){}"
                 "let let = 1;" "let x; var x;" "var x; let x;"
                 "({ get x(a){} })" "({ set x(){} })" "({ *a })"
                 "class C { constructor(){} constructor(){} }"
                 "class C { get constructor(){} }" "class C { static prototype(){} }"
                 "async function f(a = await x){}" "function* g(a = yield){}"
                 "[...a, b] = c;" "new.target;" "`\\x`"
                 "switch(x){ case 1: let y; default: let y; }"))
    (false (parses? bad)))
  ;; these must still parse (guard against over-rejection)
  (dolist (ok '("function f(a, a){}" "({ get x(){}, set x(v){} })" "class C { m(){} m(){} }"
                "class C { *['constructor'](){} }" "[a, ...b] = c;" "tag`\\x`;"
                "function f(){ new.target; }" "l\\u0065t; var a;"))
    (true (parses? ok))))

(define-test parser/context-early-errors
  (dolist (bad '("super.x;" "function f(){ super.x; }" "super();"
                 "class C { constructor(){ super(); } }"
                 "class C { constructor(){ (() => super())(); } }"
                 "class C extends B { m(){ super(); } }"
                 "class C extends B { static m(){ super(); } }"
                 "class C extends B { ['constructor'](){ super(); } }"
                 "class C extends B { constructor(){ function f(){ super(); } } }"
                 "class C extends B { constructor(){ function f(){ super.x; } } }"
                 "class C extends B { constructor(){ new super(); } }"
                 "({ m(){ super(); } })"
                 "({ m(){ return () => super(); } })"
                 "x: y: x: ;" "break foo;" "continue bar;"
                 "for (a + b in c);"))
    (false (parses? bad)))
  (dolist (ok '("class C { m(){ super.x; } }" "({ m(){ super.x; } })"
                "class C { constructor(){ super.x; } static m(){ super.x; } }"
                "class C extends B { constructor(x = super()){ } }"
                "class C extends D { constructor(){ super(); } }"
                "class C extends D { constructor(){ return () => super(); } }"
                "class C extends D { constructor(){ return async () => super(); } }"
                "class C extends D { constructor(){ return () => () => super(); } }"
                "class C extends D { constructor(){ new super.Factory(); super(); } }"
                "class C { m(){ return () => super.m(); } }"
                "({ m(x = super.x){ return () => super.m(); } })"
                "a: b: c: ;" "foo: for(;;) break foo;" "foo: { break foo; }"
                "l: function f(){ l: ; }"))
    (true (parses? ok))))

(define-test lexer/regexp-flags-and-unicode
  (false (parses? "/a/gg;"))                   ; duplicate flag
  (false (parses? "/a/x;"))                    ; invalid flag
  (true (parses? "/a/gimsuy;"))
  ;; LS/PS (U+2028/2029) are allowed inside string literals (ES2019)
  (true (parses? (format nil "var s = '~a';" (code-char #x2028))))
  ;; a line separator between tokens is whitespace, not part of an identifier
  (true (parses? (format nil "var~ax~a=~a1;" (code-char #x2028) (code-char #x2028)
                         (code-char #x2028)))))

(define-test parser/review-panel-regressions
  ;; valid code that earlier early-error batches wrongly rejected (Phase 02 review panel)
  (dolist (ok '("0xFFn;" "0o17n;" "0b101n;"                 ; non-decimal BigInt
                "for (const [a, b] of pairs) {}" "for (let {x} of y) {}"
                "for (var [a] in obj) {}" "for (const [k, v] of Object.entries(o)) {}"
                "(-2) ** 3;" "(~2) ** 3;" "(typeof x) ** 2;" ; parenthesized ** base
                "async => async;" "var f = async => 1;"      ; `async` sole arrow param
                "for ((a in b);;) {}" "for ([a in b];;) {}" "f(a in b);" ; `in` in brackets
                "'a'; 'b'; 'c'; foo();"))                    ; directive prologue keeps all
    (true (parses? ok)))
  ;; must still reject:
  (dolist (bad '("-2 ** 3;"                                  ; bare unary ** base
                 "function* g(a, a){}" "async function h(a, a){}"  ; gen/async dup params
                 "for (const [a, a] of x) {}" "for (let [a, a] in y) {}")) ; dup for-binding
    (false (parses? bad)))
  ;; all 3 directives are retained (double-nreverse bug)
  (is = 3 (length (eng:program-body (eng:parse-program "'a';'b';'c';")))))

(define-test parser/strict-mode-errors
  (false (parses? "'use strict'; with (o) {}"))
  (false (parses? "'use strict'; var eval = 1;"))
  (false (parses? "'use strict'; 0755;"))
  (true (parses? "0755;"))                    ; legacy octal OK in sloppy
  (true (parses? "with (o) {}")))             ; with OK in sloppy

(define-test parser/strict-function-header-errors
  ;; An own use-strict directive is forbidden with a non-simple parameter list
  ;; for every function grammar that accepts a Directive Prologue.
  (dolist (bad '("function f(a=0){'use strict';}"
                 "(function f(...args){'use strict';})"
                 "async function f({value}){'use strict';}"
                 "function* f([value]){'use strict';}"
                 "(value=0)=>{'use strict';}"
                 "async (...values)=>{'use strict';}"
                 "({m(value=0){'use strict';}})"
                 "({*m(...values){'use strict';}})"
                 "class C {m({value}){'use strict';}}"
                 "class C {static async m(value=0){'use strict';}}"))
    (false (parses? bad)))
  ;; A strict directive also retroactively restricts header bindings parsed in
  ;; the surrounding sloppy lexical context.
  (dolist (bad '("function eval(){'use strict';}"
                 "(function arguments(){'use strict';})"
                 "function implements(){'use strict';}"
                 "function f(interface){'use strict';}"
                 "function f({value: package}){'use strict';}"
                 "protected=>{'use strict';}"
                 "({m(public){'use strict';}})"
                 "class C {m(private){}}"))
    (false (parses? bad)))
  ;; Inherited strictness alone does not trigger the non-simple/use-strict rule.
  (dolist (ok '("'use strict'; function f(value=0){}"
                "'use strict'; ({m({value}){return value;}})"
                "class C {m(...values){return values.length;} public(){return 1;}}"))
    (true (parses? ok))))

(define-test parser/parameter-body-lexical-conflicts
  (dolist (bad '("function f(value){let value;}"
                 "(function ({value}){const value=1;})"
                 "async function f(value){class value{}}"
                 "function* f(value){let value;}"
                 "async function* f(value){const value=1;}"
                 "value=>{let value;}"
                 "async ({value})=>{class value{}}"
                 "({m(value){let value;}})"
                 "({*m(value){const value=1;}})"
                 "({async m(value){class value{}}})"
                 "({set x(value){let value;}})"
                 "class C{m(value){let value;}}"
                 "class C{static async m(value){const value=1;}}"
                 "class C{*m(value){class value{}}}"
                 "class C{set x(value){let value;}}"))
    (false (parses? bad)))
  ;; Only declarations in the function body's own lexical scope conflict.
  (dolist (ok '("function f(value){{let value;}}"
                "value=>{if(true){const value=1;}}"
                "({m(value){for(let value=0;value<1;value++){}return value;}})"
                "class C{m(value){try{}catch(value){return value;}return value;}}"
                "function f(value){var value;function value(){}}"))
    (true (parses? ok))))
