;;;; clun.asd — system definitions for clun (Bun, in pure Common Lisp).
;;;; Systems are located via scripts/registry.lisp (repo root + vendor/*/ on
;;;; asdf:*central-registry*); see the Makefile targets and PLAN.md §3.7.

(defsystem "clun"
  :description "Bun, rewritten in pure Common Lisp — a scoped JS/TS runtime and toolkit."
  :author "TJ Theesfeld"
  :license "GPL-3.0-or-later"
  ;; ASDF wants dotted integers; the user-facing prerelease is defined in
  ;; src/version.lisp and may advance independently within this core.
  :version "0.1.0"
  ;; SBCL contribs for the event loop (Phase 05); cl-ppcre is the RegExp backend
  ;; (Phase 10, vendored + pure). sb-thread is built in (feature :sb-thread).
  :depends-on ((:require "sb-posix") (:require "sb-concurrency") (:require "sb-bsd-sockets")
               ;; pure-tls (Phase 20) brings HTTPS into the binary: fetch("https://…") over
               ;; the vendored TLS 1.3 stack (ironclad + the Phase-19 closure come with it).
               ;; flexi-streams (in pure-tls's closure) gives an in-memory octet input stream for
               ;; the Phase-22 bounded gzip inflate (chipz decompressing stream).
               "cl-ppcre" "chipz" "salza2" "pure-tls" "flexi-streams" "ironclad")
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
                             ;; Phase 30 matcher substrate: immutable and engine-free.
                             (:module "glob"
                              :serial t
                              :components ((:file "matcher")
                                           (:file "walker")))
                             ;; Unicode-pinned string width substrate (Phase 33):
                             ;; generated tables must load before the scanner.
                             (:module "text"
                              :serial t
                              :components ((:file "unicode-width-tables")
                                           (:file "string-width")))
                             ;; CSS Color 4/5 parser and conversion substrate (Phase 34).
                             ;; It is engine-independent so future CSS tooling can reuse it.
                             (:module "color"
                              :serial t
                              :components ((:file "named-colors")
                                           (:file "color")))
                             ;; Phase 31 YAML graph parser: pure substrate shared by
                             ;; Clun.YAML and the .yaml/.yml module loader.
                             (:module "yaml"
                              :serial t
                              :components ((:file "yaml")))
                             ;; Phase 75 Markdown substrate (engine-free).
                             (:module "markdown"
                              :serial t
                              :components ((:file "markdown")))
                             ;; Phase 75 HTMLRewriter substrate (engine-free).
                             (:module "html"
                              :serial t
                              :components ((:file "rewriter")))
                             ;; Security substrate (Phase 35): engine-free CSRF token
                             ;; encoding/authentication over vendored crypto primitives.
                             (:module "security"
                              :serial t
                              :components ((:file "csrf")
                                           (:file "password")
                                           (:file "noncrypto-hash")
                                           (:file "secrets")))
                             ;; FULL PORT #184 pure-CL Redis RESP client + embedded peer.
                             (:module "redis"
                              :serial t
                              :components ((:file "resp")
                                           (:file "server")
                                           (:file "client")))
                             ;; FULL PORT #183 pure-CL SQL drivers (PG/MySQL/SQLite).
                             (:module "sql"
                              :serial t
                              :components ((:file "errors")
                                           (:file "url")
                                           (:file "wire")
                                           (:file "query")
                                           (:file "sqlite")
                                           (:file "postgres")
                                           (:file "mysql")
                                           (:file "pool")
                                           (:file "client")))
                             ;; Cookie parsing/serialization is engine-free so HTTP
                             ;; transport and runtime bindings share one contract.
                             (:module "http"
                              :serial t
                              :components ((:file "cookies")))
                             ;; the Node resolver is pure substrate too (depends only
                             ;; on clun.sys, no engine — §3.6) and loads before the
                             ;; engine, whose loader hooks + CJS require both call it.
                             (:module "resolver"
                              :serial t
                              :components ((:file "conditions")
                                           (:file "package-json")
                                           (:file "resolve")))
                             ;; FULL PORT #181 pure-CL single-file executables
                             ;; (needs resolver for module graph collection).
                             (:module "sfe"
                              :serial t
                              :components ((:file "format")
                                           (:file "targets")
                                           (:file "bundle")
                                           (:file "sign")
                                           (:file "compile")))
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
                                           (:file "dns")
                                           (:file "http-parser")
                                           (:file "http-client")
                                           (:file "tls12-client")
                                           (:file "tls-client")
                                           (:file "websocket"))) ; Phase 51
                             ;; cloud (Phase 53 / #185): pure-CL S3-compatible client.
                             (:module "cloud"
                              :serial t
                              :components ((:file "s3")))
                             ;; install (Phase 21): pure-CL package-manager substrate.
                             ;; It has no engine dependency, so the public runtime can
                             ;; reuse the one SemVer implementation without a late bind.
                             (:module "install"
                              :serial t
                              :components ((:file "semver")
                                           (:file "registry")
                                           (:file "integrity")
                                           (:file "tarball")
                                           (:file "resolver")
                                           (:file "linker")
                                           (:file "lockfile")
                                           (:file "installer")
                                           (:file "workspaces")))
                             ;; Phase 74: pure-CL compress + ustar/zip (Clun.Archive / gzipSync).
                             (:module "archive"
                              :serial t
                              :components ((:file "compress")
                                           (:file "tar-write")
                                           (:file "zip")))
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
                                           (:file "proxy")
                                           (:file "arguments")
                                           (:file "realm-builtins")
                                           (:file "iterator-operations")
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
                                           (:file "coverage")
                                           (:file "emitter")
                                           (:file "compile-source")
                                           (:file "eval")
                                           ;; module system (Phase 07): records +
                                           ;; ESM compile + CJS require + loader.
                                           (:module "modules"
                                            :serial t
                                            :components ((:file "module-record")
                                                         (:file "yaml")
                                                         (:file "module-compile")
                                                         (:file "plugin")
                                                         (:file "require")
                                                         (:file "module-loader")))))
                             ;; TypeScript type-stripping (Phase 09): shares the
                             ;; engine lexer; installs the loader's *ts-strip-hook*.
                             (:module "transpiler"
                              :serial t
                              :components ((:file "conditions")
                                           (:file "ts-type")
                                           (:file "ts-emit")
                                           (:file "ts-scan")
                                           (:file "jsx")
                                           (:file "strip")))
                             ;; tooling.bundler FULL PORT (#180): pure-CL Bun.build-class bundler.
                             (:module "bundler"
                              :serial t
                              :components ((:file "core")))
                             ;; runtime globals (Phase 08): console/process/Clun,
                             ;; installed onto a realm by the CLI (not by make-realm).
                             (:module "runtime"
                              :serial t
                              :components ((:file "install")
                                           (:file "console")
                                           (:file "process")
                                           (:file "spawn")     ; Clun.spawnSync (Phase 24) — before clun-global
                                           (:file "shell")     ; Clun.$ cross-platform shell — before clun-global
                                           (:file "clun-semver"); Clun.semver (Phase 29) — before clun-global
                                           (:file "clun-csrf")  ; Clun.CSRF (Phase 35) — before clun-global
                                           (:file "clun-password-hash") ; Clun.password/hash (Phase 36)
                                           (:file "clun-secrets") ; Clun.secrets pure-CL vault (#179)
                                           (:file "clun-plugin")  ; Clun.plugin / Bun.plugin (Issue #187)
                                           (:file "clun-redis") ; Clun.redis pure-CL (#184)
                                           (:file "clun-s3") ; Clun.s3 pure-CL (#185)
                                           (:file "clun-sql") ; Clun.SQL pure-CL (#183)
                                           (:file "clun-build") ; Clun.build bundler (#180) + SFE compile (#181)
                                           (:file "clun-string-width") ; Clun.stringWidth (Phase 33) — before clun-global
                                           (:file "clun-glob") ; Clun.Glob (Phase 30) — before clun-global
                                           (:file "clun-filesystem-router") ; Clun.FileSystemRouter (Phase 50)
                                           (:file "clun-color") ; Clun.color (Phase 34) — before clun-global
                                           (:file "clun-yaml") ; Clun.YAML (Phase 31) — before clun-global
                                           (:file "clun-cron") ; Clun.cron (Phase 76) — before clun-global
                                           (:file "clun-markdown") ; Clun.markdown (Phase 75) — before clun-global
                                           (:file "clun-global")
                                           (:file "clun-archive") ; gzip/deflate/zip + Archive (Phase 74); needs %async
                                           (:file "abort")     ; AbortController/AbortSignal (Phase 14)
                                           (:file "globals")   ; structuredClone, crypto (Phase 12)
                                           (:file "web-http")  ; Headers/Request/Response (Phase 17)
                                           (:file "html-rewriter") ; HTMLRewriter global (Phase 75)
                                           (:file "web-cookies") ; Clun.Cookie/CookieMap (Phase 32)
                                           (:file "clun-router") ; Clun.serve route table (Phase 50)
                                           (:file "clun-serve"); Clun.serve HTTP server (Phase 17)
                                           (:file "hot-reload"); --hot/--watch state-preserving reload (#188)
                                           (:file "frontend-dev-server") ; HTML entry + HMR (#189)
                                           (:file "web-url")   ; URL/URLSearchParams (Phase 18)
                                           (:file "web-proxy") ; fetch proxy selection/auth/bypass (Phase 28)
                                           (:file "web-fetch") ; fetch (Phase 18)
                                           (:file "websocket-client") ; Phase 51 client WebSocket
                                           ;; node builtin modules (Phase 12): registry +
                                           ;; one file per module; each self-registers.
                                           (:module "node"
                                            :serial t
                                            :components ((:file "registry")
                                                         (:file "path")
                                                         (:file "os")
                                                         (:file "querystring")
                                                         (:file "url")      ; node:url legacy (Phase 47 residual)
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
                                           (:file "fake-timers")
                                           (:file "mock")
                                           (:file "snapshot")
                                           (:file "expect")
                                           (:file "scheduler")
                                           (:file "reporter")
                                           (:file "discovery")
                                           (:file "coverage")
                                           (:file "config")
                                           (:file "runner")))
                             ;; CLI (Phase 08): arg parsing, .env, dispatch.
                             (:module "cli"
                              :serial t
                              :components ((:file "dotenv")
                                           (:file "args")))
                             (:file "main")))))

(defsystem "clun/tests"
  :description "Parachute-driven CL test suites mirroring src/ (PLAN.md §3.7 tests/lisp)."
  :license "GPL-3.0-or-later"
  ;; ironclad (sha512/crc32) + cl-base64 back the Phase-21 registry fixture: the fixture
  ;; server computes each tarball's dist.integrity from bytes + gzips metadata (stored blocks).
  :depends-on ("clun" "parachute" "ironclad" "cl-base64")
  :serial t
  :components ((:module "tests"
                :components ((:module "lisp"
                              :serial t
                              :components ((:file "package")
                                           (:file "smoke")
                                           (:module "sys"
                                            :serial t
                                            :components ((:file "sys-tests")))
                                           (:module "security"
                                            :serial t
                                            :components ((:file "csrf-tests")
                                                         (:file "password-hash-tests")
                                                         (:file "secrets-tests")))
                                           (:module "redis"
                                            :serial t
                                            :components ((:file "redis-tests")))
                                           (:module "sfe"
                                            :serial t
                                            :components ((:file "sfe-tests")))
                                           (:module "sql"
                                            :serial t
                                            :components ((:file "sql-tests")))
                                           (:module "cloud"
                                            :serial t
                                            :components ((:file "s3-tests")))
                                           (:module "http"
                                            :serial t
                                            :components ((:file "cookies-tests")))
                                           (:module "text"
                                            :serial t
                                            :components ((:file "string-width-tests")))
                                           (:module "glob"
                                            :serial t
                                            :components ((:file "matcher-tests")
                                                         (:file "walker-tests")))
                                           (:module "color"
                                            :serial t
                                            :components ((:file "color-tests")))
                                           (:module "yaml"
                                            :serial t
                                            :components ((:file "yaml-tests")))
                                           (:module "markdown"
                                            :serial t
                                            :components ((:file "markdown-tests")))
                                           (:module "html"
                                            :serial t
                                            :components ((:file "rewriter-tests")))
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
                                                         (:file "proxy-tests")
                                                         (:file "eval-tests")
                                                         (:file "arguments-tests")
                                                         (:file "compile-source-tests")
                                                         (:file "builtins-tests")
                                                         (:file "async-tests")
                                                         (:file "async-generator-queue-tests")
                                                         (:file "async-iteration-tests")
                                                         (:file "modules-tests")
                                                         (:file "plugin-tests")
                                                         (:file "inspect-tests")
                                                         (:file "regexp-tests")
                                                         (:file "binary-tests")))
                                           (:module "runtime"
                                            :serial t
                                            :components ((:file "runtime-tests")
                                                         (:file "glob-tests")
                                                         (:file "url-tests")
                                                         (:file "spawn-tests")
                                                         (:file "shell-tests")
                                                         (:file "scripts-tests")
                                                         (:file "cron-tests")
                                                         (:file "hot-reload-tests")
                                                         (:file "frontend-dev-server-tests")))
                                           (:module "transpiler"
                                            :serial t
                                            :components ((:file "ts-strip-tests")
                                                         (:file "jsx-tests")))
                                           (:module "bundler"
                                            :serial t
                                            :components ((:file "bundler-tests")))
                                           (:module "loop"
                                            :serial t
                                            :components ((:file "loop-tests")))
                                           (:module "net"
                                            :serial t
                                            :components ((:file "dns-tests")
                                                         (:file "sockets-tests")
                                                         (:file "http-parser-tests")
                                                         (:file "http-server-tests")
                                                         (:file "router-tests")
                                                         (:file "fetch-tests")
                                                         (:file "tls12-tests")
                                                         (:file "websocket-tests")
                                                         (:file "web-streams-tests")
                                                         (:file "https-tests")))
                                           (:module "install"
                                            :serial t
                                            :components ((:file "semver-tests")
                                                         (:file "registry-fixture")
                                                         (:file "registry-tests")
                                                         (:file "tarball-tests")
                                                         (:file "resolver-tests")
                                                         (:file "install-tests")
                                                         (:file "cli-tests")
                                                         (:file "workspace-tests")))
                                           (:module "archive"
                                            :serial t
                                            :components ((:file "compress-tests")
                                                         (:file "archive-tests")))))))))
