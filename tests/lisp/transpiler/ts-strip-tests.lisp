;;;; ts-strip-tests.lisp — parachute unit tests for the TS type-stripper (Phase 09).
;;;; Fast, in-image. Asserts: (1) length is always preserved, (2) the stripped code,
;;;; with whitespace runs collapsed, equals the expected JS (robust to exact space
;;;; counts — the tests/ts/strip corpus checks byte-exactness), (3) the error catalog.

(in-package :clun-test)

(defun strip (src) (clun.transpiler:strip-types src "t.ts"))

(defun collapse-ws (s)
  "Collapse runs of spaces/tabs to one space and trim, for whitespace-robust compare
(newlines kept as-is so structural line breaks still matter)."
  (string-trim '(#\Space)
               (with-output-to-string (o)
                 (let ((prev-space nil))
                   (loop for c across s do
                     (cond ((member c '(#\Space #\Tab))
                            (unless prev-space (write-char #\Space o)) (setf prev-space t))
                           (t (write-char c o) (setf prev-space nil))))))))

(defun strip~ (want src)
  "Stripping SRC preserves length AND (whitespace-collapsed) equals WANT."
  (let ((got (strip src)))
    (and (= (length got) (length src))
         (string= (collapse-ws got) (collapse-ws want)))))

(defun strip-errs (src)
  (handler-case (progn (strip src) nil)
    (clun.transpiler:unsupported-ts-syntax (e) (clun.transpiler:uts-message e))
    (error (e) (format nil "OTHER:~a" e))))

(define-test ts/annotations
  (true (strip~ "let x = 1;" "let x: number = 1;"))
  (true (strip~ "function f(a , b ) {}" "function f(a: string, b?: number): void {}"))
  (true (strip~ "const p = [1, 2];" "const p: [number, string] = [1, 2];"))
  (true (strip~ "for (let i = 0; i < 3; i++) {}" "for (let i: number = 0; i < 3; i++) {}")))

(define-test ts/arrows-and-generics
  (true (strip~ "const f = (x ) => x;" "const f = (x: T): T => x;"))
  (true (strip~ "const id = (x ) => x;" "const id = <T,>(x: T): T => x;"))
  (true (strip~ "foo (1);" "foo<Bar>(1);"))
  (true (strip~ "new Map ();" "new Map<string, number>();"))
  ;; comparisons are NOT type args (byte-exact: unchanged)
  (is equal "const c = a < b && c > d;" (strip "const c = a < b && c > d;")))

(define-test ts/expressions
  (true (strip~ "const y = x ;" "const y = x as Foo;"))
  (true (strip~ "const y = x ;" "const y = x satisfies Record;"))
  (is equal "const z = a .b .c;" (strip "const z = a!.b!.c;")))

(define-test ts/statements
  (is equal "" (collapse-ws (strip "interface P { a: number; b(): void; }")))
  (is equal "" (collapse-ws (strip "type T = A | B<C> | { x: 1 };")))
  (is equal "" (collapse-ws (strip "declare const g: number;")))
  (is equal "" (collapse-ws (strip "import type { A } from \"m\";")))
  (true (strip~ "import { B, } from \"n\";" "import { type A, B, type C } from \"n\";"))
  (true (strip~ "class C extends D { }" "class C extends D implements I, J { }")))

(define-test ts/position-preserved
  ;; newlines survive so line/column are byte-identical
  (let* ((src (format nil "let x:~%  T = 1;")) (out (strip src)))
    (is eql (length src) (length out))
    (is eql (position #\Newline src) (position #\Newline out))))

(define-test ts/error-catalog
  (is equal "TypeScript enum is not supported in strip-only mode" (strip-errs "enum E { A }"))
  (is equal "TypeScript enum is not supported in strip-only mode" (strip-errs "const enum E { A }"))
  (true (search "parameter property" (or (strip-errs "class C { constructor(private x: number) {} }") "")))
  (true (search "import =" (or (strip-errs "import x = require(\"y\");") "")))
  (true (search "export =" (or (strip-errs "export = foo;") "")))
  (true (search "decorators" (or (strip-errs "class C { @dec m() {} }") "")))
  (true (search "namespace" (or (strip-errs "namespace N { const x = 1; }") "")))
  ;; a type-only namespace is erased, not an error
  (is equal "" (collapse-ws (strip "namespace T { export interface X { a: number; } }"))))
