;;;; clun.asd — system definitions for clun (Bun, in pure Common Lisp).
;;;; Systems are located via scripts/registry.lisp (repo root + vendor/*/ on
;;;; asdf:*central-registry*); see the Makefile targets and PLAN.md §3.7.

(defsystem "clun"
  :description "Bun, rewritten in pure Common Lisp — a scoped JS/TS runtime and toolkit."
  :author "TJ Theesfeld"
  :license "MIT"
  ;; ASDF wants dotted integers; the user-facing string is src/version.lisp's
  ;; *clun-version* = "0.0.1-dev".
  :version "0.0.1"
  ;; No :depends-on yet — cl-ppcre lands with the RegExp phase (PLAN.md Phase 10).
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "packages")
                             (:file "version")
                             (:module "engine"
                              :serial t
                              :components ((:file "values")
                                           (:file "conditions")
                                           (:file "strings")
                                           (:file "numbers")
                                           (:file "coercions")
                                           (:file "lexer")
                                           (:file "ast")
                                           (:file "parser")
                                           (:file "analyzer")
                                           (:file "ast-printer")
                                           (:file "objects")
                                           (:file "environment")
                                           (:file "operators")
                                           (:file "functions")
                                           (:file "realm")
                                           (:file "realm-builtins")
                                           (:file "emitter")
                                           (:file "eval")))
                             (:file "main")))))

(defsystem "clun/tests"
  :description "Parachute-driven CL test suites mirroring src/ (PLAN.md §3.7 tests/lisp)."
  :license "MIT"
  :depends-on ("clun" "parachute")
  :serial t
  :components ((:module "tests"
                :components ((:module "lisp"
                              :serial t
                              :components ((:file "package")
                                           (:file "smoke")
                                           (:module "engine"
                                            :serial t
                                            :components ((:file "values-tests")
                                                         (:file "conditions-tests")
                                                         (:file "strings-tests")
                                                         (:file "numbers-tests")
                                                         (:file "coercions-tests")
                                                         (:file "lexer-tests")
                                                         (:file "parser-tests")
                                                         (:file "objects-tests")
                                                         (:file "eval-tests")))))))))
