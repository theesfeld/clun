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
                "typeof void delete x.y;" "new.target;" "yield;"))
    (true (parses? ok))))

(define-test parser/strict-mode-errors
  (false (parses? "'use strict'; with (o) {}"))
  (false (parses? "'use strict'; var eval = 1;"))
  (false (parses? "'use strict'; 0755;"))
  (true (parses? "0755;"))                    ; legacy octal OK in sloppy
  (true (parses? "with (o) {}")))             ; with OK in sloppy
