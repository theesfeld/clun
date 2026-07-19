;;;; fmt-lint-tests.lisp — pure-CL formatter + linter suite (FULL PORT #190).

(in-package :clun-test)

(defun %fmt (src &key path)
  (clun.fmt:format-source src :path path))

(defun %idempotent-p (src &key path)
  (let* ((a (%fmt src :path path))
         (b (%fmt a :path path)))
    (string= a b)))

(define-test fmt/json-pretty
  (let ((out (%fmt "{\"a\":1,\"b\":[2,3]}" :path "x.json")))
    (true (search "\"a\"" out))
    (true (%idempotent-p out :path "x.json"))
    (true (char= (char out (1- (length out))) #\Newline))))

(define-test fmt/js-idempotent
  (let* ((src "const x=1;function f(a){return a+1;}")
         (out (%fmt src :path "a.js")))
    (true (search "const" out))
    (true (%idempotent-p src :path "a.js"))
    (true (%idempotent-p out :path "a.js"))))

(define-test fmt/js-semicolons-and-indent
  (let ((out (%fmt "let a=1
let b=2" :path "b.js")))
    (true (search "let a" out))
    (true (%idempotent-p out :path "b.js"))))

(define-test fmt/ts-structural
  (let* ((src "type T=number;const x:T=1;")
         (out (%fmt src :path "t.ts")))
    (true (search "type" out))
    (true (%idempotent-p out :path "t.ts"))))

(define-test fmt/css-braces
  (let ((out (%fmt "body{color:red;margin:0}" :path "s.css")))
    (true (search "body" out))
    (true (search "color" out))
    (true (%idempotent-p out :path "s.css"))))

(define-test fmt/yaml-trailing-ws
  (let ((out (%fmt (format nil "a: 1   ~%b: 2  ") :path "c.yaml")))
    (false (search "1   " out))
    (true (%idempotent-p out :path "c.yaml"))))

(define-test fmt/language-detect
  (is eq :js (clun.fmt:language-from-path "foo.js"))
  (is eq :ts (clun.fmt:language-from-path "foo.ts"))
  (is eq :json (clun.fmt:language-from-path "pkg.json"))
  (is eq :css (clun.fmt:language-from-path "app.css"))
  (is eq :yaml (clun.fmt:language-from-path "c.yml")))

(define-test fmt/comments-preserved-structural
  (let* ((src (format nil "// hello~%const x = 1;"))
         (out (%fmt src :path "c.js")))
    (true (search "hello" out))
    (true (search "const" out))))

(define-test lint/no-debugger
  (let* ((cfg (clun.lint:default-lint-config))
         (diags (clun.lint:lint-source "debugger;" :path "d.js" :config cfg)))
    (true (find "no-debugger" diags :key #'clun.lint:diag-rule :test #'string=))))

(define-test lint/eqeqeq
  (let* ((cfg (clun.lint:default-lint-config))
         (diags (clun.lint:lint-source "if (a == b) {}" :path "e.js" :config cfg)))
    (true (find "eqeqeq" diags :key #'clun.lint:diag-rule :test #'string=))))

(define-test lint/no-var
  (let* ((cfg (clun.lint:default-lint-config))
         (diags (clun.lint:lint-source "var x = 1;" :path "v.js" :config cfg)))
    (true (find "no-var" diags :key #'clun.lint:diag-rule :test #'string=))))

(define-test lint/no-undef
  (let* ((cfg (clun.lint:default-lint-config))
         (diags (clun.lint:lint-source "console.log(notDefined);" :path "u.js" :config cfg)))
    (true (find "no-undef" diags :key #'clun.lint:diag-rule :test #'string=))))

(define-test lint/clean-source
  (let* ((cfg (clun.lint:default-lint-config))
         (diags (clun.lint:lint-source
                 "const x = 1; console.log(x);"
                 :path "ok.js" :config cfg))
         (errs (remove-if-not
                (lambda (d) (eq (clun.lint:diag-severity d) :error))
                diags)))
    ;; console is a global; x is used — no errors expected
    (is = 0 (length errs))))

(define-test lint/safe-fix-eqeqeq
  (let* ((src "a == b")
         (cfg (clun.lint:default-lint-config))
         (diags (clun.lint:lint-source src :path "f.js" :config cfg))
         (fixed (clun.lint:apply-safe-fixes src diags)))
    (true (search "===" fixed))))

(define-test lint/recommended-rules-nonempty
  (true (plusp (length clun.lint:*recommended-rules*)))
  (true (assoc "eqeqeq" clun.lint:*recommended-rules* :test #'string=)))

(define-test fmt/check-paths-roundtrip
  (let* ((dir (sys:make-temp-dir "clun-fmt-"))
         (file (sys:path-join dir "sample.js")))
    (sys:write-file-octets
     file (sb-ext:string-to-octets "const x=1;" :external-format :utf-8))
    (multiple-value-bind (text changed)
        (clun.fmt:format-file file :write t)
      (true changed)
      (true (search "const" text))
      (multiple-value-bind (_ changed2)
          (clun.fmt:format-file file :write nil)
        (declare (ignore _))
        (false changed2)))
    (sys:remove-recursive dir)))
