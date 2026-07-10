;;;; packages.lisp — package skeleton for clun's subsystems (PLAN.md §3.7).
;;;; Each subsystem gets a namespace home now so later phases have somewhere to
;;;; land; per §6 nothing :use-s beyond :cl. Sub-packages (engine lexer/parser/…)
;;;; are added when their phase arrives.

(in-package :cl-user)

(defpackage :clun
  (:use :cl)
  (:documentation "Toplevel: argv dispatch, version, condition->exit-code.")
  (:export #:main))

(defpackage :clun.sys
  (:use :cl)
  (:documentation "Path discipline, JSON, errors, sbcl-compat, platform."))

(defpackage :clun.cli
  (:use :cl)
  (:documentation "Per-command argument parsing, help/version, .env loader."))

(defpackage :clun.engine
  (:use :cl)
  (:documentation "From-scratch ECMAScript engine: lexer, parser, analyzer, emitter, objects, stdlib.")
  ;; Phase 01 — value substrate & coercions.
  (:export
   ;; values
   #:+undefined+ #:+null+ #:+true+ #:+false+ #:js-object #:js-object-p #:make-js-object
   #:js-undefined-p #:js-null-p #:js-nullish-p #:js-boolean-p #:js-number-p
   #:js-string-p #:js-primitive-p #:js-boolean #:js-type
   ;; conditions
   #:js-condition #:js-condition-value #:js-native-error #:js-native-error-kind
   #:js-native-error-message #:js-native-error-name #:throw-js-value
   #:throw-native-error #:throw-type-error #:throw-range-error
   #:throw-syntax-error #:throw-reference-error
   ;; strings (WTF-8 boundary)
   #:code-units->utf8 #:utf8->code-units #:high-surrogate-p #:low-surrogate-p
   ;; numbers
   #:with-js-floats #:+js-infinity+ #:+js-neg-infinity+ #:*js-nan*
   #:js-nan-p #:js-infinite-p #:js-finite-p #:js-neg-zero-p #:js-zero-p
   #:double->int32 #:double->uint32 #:number->js-string #:js-string->number
   ;; coercions
   #:to-primitive #:to-boolean #:to-number #:to-string #:to-int32 #:to-uint32
   #:js-truthy #:*ordinary-to-primitive*
   ;; lexer (Phase 02)
   #:make-lexer #:next-token #:lex-all #:reread-regexp #:reread-template
   #:lexer #:lexer-p #:lexer-pos #:lexer-comments #:lexer-line #:lexer-src
   #:token #:token-p #:token-type #:token-value #:token-raw #:token-start
   #:token-end #:token-line #:token-col #:token-nl-before #:token-tmpl-part
   ;; parser / AST (Phase 02)
   #:parse-program #:make-parser #:parse-assignment #:parse-statement
   #:node #:node-p #:node-start #:node-end
   #:program #:program-p #:program-body #:program-source-type
   #:identifier #:identifier-p #:identifier-name #:literal #:literal-p #:literal-value
   #:literal-kind #:analyze #:ast->sexp #:binding-bound-names
   ;; evaluator / object kernel (Phase 03)
   #:make-realm #:run-source #:run-program #:eval-source #:*realm*
   #:js-make-object #:js-get #:js-set #:has-property #:has-own-property
   #:create-data-property #:jm-get #:jm-own-property-keys #:callable-p
   #:js-call #:js-symbol-p #:js-array-p #:js-condition #:js-condition-value))

(defpackage :clun.loop
  (:use :cl)
  (:documentation "Event loop: reactor, timers, mailbox, handles, signals, workers."))

(defpackage :clun.resolver
  (:use :cl)
  (:documentation "Pure-CL Node module resolution (no engine dependency)."))

(defpackage :clun.transpiler
  (:use :cl)
  (:documentation "TypeScript type-stripping (shares the engine lexer)."))

(defpackage :clun.runtime
  (:use :cl)
  (:documentation "Globals wiring: console/inspector, process, timers, Clun global, node/ modules."))

(defpackage :clun.net
  (:use :cl)
  (:documentation "Sockets, HTTP parser/server/client, fetch, TLS integration."))

(defpackage :clun.test-runner
  (:use :cl)
  (:documentation "clun test: discovery, scheduler, matchers, diff, reporter."))

(defpackage :clun.install
  (:use :cl)
  (:documentation "clun install: semver, registry, tarball, integrity, linker, lockfile, cache."))
