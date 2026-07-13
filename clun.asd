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
  ;; SBCL contribs for the event loop (Phase 05); cl-ppcre is the RegExp backend
  ;; (Phase 10, vendored + pure). sb-thread is built in (feature :sb-thread).
  :depends-on ((:require "sb-posix") (:require "sb-concurrency") (:require "sb-bsd-sockets") "cl-ppcre")
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "packages")
                             (:file "version")
                             (:module "sys"
                              :serial t
                              :components ((:file "sbcl-compat")
                                           (:file "paths")
                                           (:file "fs")
                                           (:file "json")
                                           (:file "platform")))
                             ;; the Node resolver is pure substrate too (depends only
                             ;; on clun.sys, no engine — §3.6) and loads before the
                             ;; engine, whose loader hooks + CJS require both call it.
                             (:module "resolver"
                              :serial t
                              :components ((:file "conditions")
                                           (:file "package-json")
                                           (:file "resolve")))
                             ;; the event loop is pure substrate (no engine deps) and
                             ;; loads before the engine so the async files can call it.
                             (:module "loop"
                              :serial t
                              :components ((:file "loop-core")
                                           (:file "timers")
                                           (:file "reactor")
                                           (:file "signals")
                                           (:file "workers")
                                           (:file "event-loop")))
                             ;; net (Phase 16): TCP handle layer on the reactor.
                             (:module "net"
                              :serial t
                              :components ((:file "sockets")
                                           (:file "http-parser")))
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
                                           (:file "builtins-iterator")
                                           (:file "builtins-object")
                                           (:file "builtins-number")
                                           (:file "builtins-bigint")
                                           (:file "builtins-string")
                                           ;; RegExp (Phase 10): own JS parser → AST →
                                           ;; CL-PPCRE parse trees; RegExp object + String
                                           ;; delegation. Loads after String (delegation),
                                           ;; before Array.
                                           (:module "regex"
                                            :serial t
                                            :components ((:file "ast")
                                                         (:file "parser")
                                                         (:file "translate")
                                                         (:file "regexp-object")))
                                           (:file "builtins-array")
                                           (:file "builtins-symbol")
                                           (:file "builtins-collections")
                                           ;; binary data (Phase 11): ArrayBuffer, the 11
                                           ;; TypedArray exotics, DataView, TextEncoder/Decoder.
                                           ;; After collections (iterator protocol), before global.
                                           (:file "builtins-binary")
                                           (:file "builtins-date")
                                           (:file "builtins-math")
                                           (:file "builtins-json")
                                           (:file "builtins-global")
                                           (:module "async"
                                            :serial t
                                            :components ((:file "coroutine")
                                                         (:file "generator")
                                                         (:file "promise")
                                                         (:file "async-function")))
                                           (:file "inspect")
                                           (:file "emitter")
                                           (:file "eval")
                                           ;; module system (Phase 07): records +
                                           ;; ESM compile + CJS require + loader.
                                           (:module "modules"
                                            :serial t
                                            :components ((:file "module-record")
                                                         (:file "module-compile")
                                                         (:file "require")
                                                         (:file "module-loader")))))
                             ;; TypeScript type-stripping (Phase 09): shares the
                             ;; engine lexer; installs the loader's *ts-strip-hook*.
                             (:module "transpiler"
                              :serial t
                              :components ((:file "conditions")
                                           (:file "ts-type")
                                           (:file "ts-scan")
                                           (:file "strip")))
                             ;; runtime globals (Phase 08): console/process/Clun,
                             ;; installed onto a realm by the CLI (not by make-realm).
                             (:module "runtime"
                              :serial t
                              :components ((:file "install")
                                           (:file "console")
                                           (:file "process")
                                           (:file "clun-global")
                                           (:file "abort")     ; AbortController/AbortSignal (Phase 14)
                                           (:file "globals")   ; structuredClone, crypto (Phase 12)
                                           (:file "web-http")  ; Headers/Request/Response (Phase 17)
                                           (:file "clun-serve"); Clun.serve HTTP server (Phase 17)
                                           ;; node builtin modules (Phase 12): registry +
                                           ;; one file per module; each self-registers.
                                           (:module "node"
                                            :serial t
                                            :components ((:file "registry")
                                                         (:file "path")
                                                         (:file "os")
                                                         (:file "querystring")
                                                         (:file "util")
                                                         (:file "events")
                                                         (:file "assert")
                                                         (:file "buffer")
                                                         (:file "fs")
                                                         (:file "timers")))))
                             ;; test runner (Phase 15): clun test — discovery, tree +
                             ;; JS globals, matchers, diff, scheduler, reporter.
                             (:module "test-runner"
                              :serial t
                              :components ((:file "diff")
                                           (:file "registry")
                                           (:file "expect")
                                           (:file "scheduler")
                                           (:file "reporter")
                                           (:file "discovery")
                                           (:file "runner")))
                             ;; CLI (Phase 08): arg parsing, .env, dispatch.
                             (:module "cli"
                              :serial t
                              :components ((:file "dotenv")
                                           (:file "args")))
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
                                           (:module "sys"
                                            :serial t
                                            :components ((:file "sys-tests")))
                                           (:module "resolver"
                                            :serial t
                                            :components ((:file "resolver-tests")))
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
                                                         (:file "eval-tests")
                                                         (:file "builtins-tests")
                                                         (:file "async-tests")
                                                         (:file "modules-tests")
                                                         (:file "inspect-tests")
                                                         (:file "regexp-tests")
                                                         (:file "binary-tests")))
                                           (:module "runtime"
                                            :serial t
                                            :components ((:file "runtime-tests")))
                                           (:module "transpiler"
                                            :serial t
                                            :components ((:file "ts-strip-tests")))
                                           (:module "loop"
                                            :serial t
                                            :components ((:file "loop-tests")))
                                           (:module "net"
                                            :serial t
                                            :components ((:file "sockets-tests")
                                                         (:file "http-parser-tests")
                                                         (:file "http-server-tests")))))))))
