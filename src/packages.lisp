;;;; packages.lisp — package skeleton for clun's subsystems (PLAN.md §3.7).
;;;; Each subsystem gets a namespace home now so later phases have somewhere to
;;;; land; per §6 nothing :use-s beyond :cl. Sub-packages (engine lexer/parser/…)
;;;; are added when their phase arrives.

(in-package :cl-user)

;; NOTE: packages with :local-nicknames must be defined AFTER their targets, so the
;; base layer (sys/loop/engine/resolver) comes first, then the dependents
;; (runtime/cli/clun). Do not reorder without preserving that invariant.

(defpackage :clun.sys
  (:use :cl)
  (:documentation "Path discipline, JSON, errors, sbcl-compat, platform.")
  ;; Phase 05 — quarantined internal-SBCL bits (§3.2/§6): self-pipe + poll probe.
  (:export #:make-self-pipe #:self-pipe #:self-pipe-p #:self-pipe-read-fd
           #:self-pipe-wake #:self-pipe-drain #:self-pipe-close #:poll-backend-p
           ;; Phase 07 — path discipline (parse-native-namestring boundary, §3.2)
           #:native->pathname #:pathname->native #:path-join #:path-dirname
           #:path-basename #:path-extension #:absolute-path-p #:normalize-path
           ;; Phase 07 — filesystem primitives (engine-free)
           #:path-exists-p #:file-p #:directory-p #:realpath #:read-file-string
           #:read-directory
           ;; Phase 07 — JSON reader (hand-rolled, engine-free; §3.5)
           #:parse-json #:json-error #:json-null #:json-false #:json-true
           #:jget #:jobject-p
           ;; Phase 08 — platform primitives for the runtime (process/console)
           #:stream-fd #:tty-p #:environ-alist #:getenv #:getpid
           #:current-directory #:change-directory #:machine-arch #:platform-name
           #:monotonic-nanoseconds #:heap-bytes-used #:bytes-consed
           ;; Phase 12 — OS info + CSPRNG bytes for node:os / crypto
           #:os-random-bytes #:hostname #:os-release #:os-type #:tmpdir #:homedir
           #:total-memory #:free-memory #:uptime-seconds #:cpu-count
           ;; Phase 13 — filesystem primitives + errno-carrying condition for node:fs
           #:fs-error #:fs-error-code #:fs-error-errno #:fs-error-syscall #:fs-error-path
           #:fs-code-message
           #:stat* #:fstat #:fstat-dev #:fstat-ino #:fstat-mode #:fstat-nlink #:fstat-uid
           #:fstat-gid #:fstat-rdev #:fstat-size #:fstat-atime-ns #:fstat-mtime-ns #:fstat-ctime-ns
           #:fstat-file-p #:fstat-dir-p #:fstat-symlink-p
           #:make-directory #:remove-directory #:remove-file #:rename-path #:make-symlink
           #:read-symlink #:change-mode #:truncate-file #:make-temp-dir #:check-access
           #:remove-recursive #:read-file-octets #:write-file-octets #:copy-file*))

;; Defined before clun.engine so the engine's :lp local-nickname can target it.
(defpackage :clun.loop
  (:use :cl)
  (:documentation "Event loop: reactor, timers, mailbox, handles, signals, workers.")
  (:export
   ;; loop lifecycle
   #:event-loop #:event-loop-p #:make-event-loop #:destroy-event-loop
   #:run-loop #:loop-post #:loop-stop #:el-ref-count #:now-ms
   #:loop-on-thread-p #:run-on-loop #:*on-foreign-thread*
   ;; queues (stub in P05; JS jobs wire in P06)
   #:enqueue-task #:enqueue-microtask #:enqueue-next-tick #:drain-microtasks
   ;; handles / refcount
   #:make-handle #:handle #:handle-p #:handle-ref #:handle-unref
   #:handle-activate #:handle-deactivate
   ;; timers
   #:set-timer #:clear-timer #:timer #:timer-p #:next-timer-delay
   #:timer-ref #:timer-unref #:timer-refd-p
   ;; reactor (sockets land in P16)
   #:reactor-add #:reactor-remove
   ;; signals
   #:install-signal-handler #:remove-signal-handler
   ;; workers
   #:worker-submit))

(defpackage :clun.engine
  (:use :cl)
  ;; :lp (not :loop — that shadows the CL macro) reaches the Phase 05 event loop that
  ;; the async engine (Phase 06) feeds jobs into. :pp = cl-ppcre (RegExp backend, P10).
  (:local-nicknames (:lp :clun.loop) (:pp :cl-ppcre))
  (:documentation "From-scratch ECMAScript engine: lexer, parser, analyzer, emitter, objects, stdlib.")
  ;; Phase 01 — value substrate & coercions.
  (:export
   ;; values
   #:+undefined+ #:+null+ #:+true+ #:+false+ #:js-object #:js-object-p #:make-js-object
   #:js-undefined-p #:js-null-p #:js-nullish-p #:js-boolean-p #:js-number-p
   #:js-bigint-p #:js-string-p #:js-primitive-p #:js-boolean #:js-type
   ;; conditions
   #:js-condition #:js-condition-value #:js-native-error #:js-native-error-kind
   #:js-native-error-message #:js-native-error-name #:throw-js-value
   #:throw-native-error #:throw-type-error #:throw-range-error
   #:throw-syntax-error #:throw-reference-error
   ;; strings (WTF-8 boundary)
   #:code-units->utf8 #:utf8->code-units #:ta-subview #:high-surrogate-p #:low-surrogate-p
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
   #:js-call #:js-symbol-p #:js-array-p #:js-condition #:js-condition-value
   ;; inspector (Phase 08) — the one shared value renderer
   #:inspect-value #:*inspect-defaults*
   ;; runtime hooks (Phase 08): completion capture for -p, error introspection,
   ;; realm accessors the runtime/CLI need
   #:run-module-file #:run-module-source #:eval-source #:realm-global
   #:teardown-realm #:run-callback-to-settlement #:drive-jobs #:current-loop
   #:js-promise-p #:js-promise-pstate #:js-promise-value #:to-string #:js-object-class
   #:make-native-function #:install-method #:install-getter #:install-accessor #:data-prop #:hidden-prop
   #:new-object #:new-array #:throw-type-error #:js-undefined-p #:js-truthy #:js-boolean
   #:to-number #:arg #:intrinsic #:function-name #:js-function-p #:js-native-function-p
   #:js-nullish-p #:array-like->list #:array-length
   ;; object-API surface for node builtin modules (Phase 12)
   #:js-getv #:to-object #:to-boolean #:to-integer-or-infinity #:js-strict-eq
   #:js-same-value #:js-typeof #:make-error-object #:well-known #:length-of-array-like
   #:js-null-p #:js-number-p #:js-string-p #:js-deep-equal #:*builtin-module-builder*
   #:js-construct #:obj-own-desc #:pd-value #:pd-enumerable #:crypto-fill-random
   #:js-loose-eq #:js-instanceof #:throw-js-value #:js-object-class
   #:js-typed-array-p #:make-u8-array #:u8-from-octets #:ta-octets #:u8-over-arraybuffer #:js-array-buffer-bytes #:js-array-buffer-p
   #:code-units->utf8 #:utf8->code-units #:ta-subview
   ;; TS strip hook (Phase 09): the loader applies this to .ts/.mts/.cts source
   ;; before parse-program; the transpiler installs it (engine stays dep-free).
   #:*ts-strip-hook* #:make-lexer #:next-token #:reread-regexp #:reread-template
   #:lexer-pos #:lexer-src #:token-type #:token-value #:token-start #:token-end
   #:token-line #:token-col #:token-nl-before #:token-tmpl-part #:token-escaped
   #:line-terminator-p))

(defpackage :clun.resolver
  (:use :cl)
  (:local-nicknames (:sys :clun.sys))
  (:documentation "Pure-CL Node module resolution (no engine dependency).")
  (:export
   ;; entry point + result
   #:resolve #:*default-conditions*
   ;; conditions (engine maps these to JS errors at the boundary)
   #:resolution-error #:resolution-error-specifier #:resolution-error-referrer
   #:module-not-found #:package-path-not-exported #:invalid-package-target
   #:invalid-package-specifier #:unsupported-directory-import
   ;; package.json access (reused by the loader for import.meta/type)
   #:read-package-json #:nearest-package-json #:package-type))

;; clun.net (Phase 16/17): sockets + HTTP — base layer (needs only loop + sys), so it
;; must be defined before clun.runtime, which local-nicknames it as :net.
(defpackage :clun.net
  (:use :cl)
  (:local-nicknames (:lp :clun.loop) (:sys :clun.sys))
  (:documentation "Sockets, HTTP parser/server/client, fetch, TLS integration.")
  (:export ;; Phase 16 — TCP handle layer on the reactor
   #:tcp-listen #:tcp-connect #:tcp-write #:tcp-close #:tcp-shutdown
   #:tcp #:tcp-p #:tcp-state #:tcp-queued-bytes #:tcp-peer #:tcp-local
   #:tcp-on-data #:tcp-on-close #:tcp-on-error #:tcp-on-drain
   #:listener #:listener-p #:listener-port #:listener-close #:listener-address
   #:socket-error-code #:socket-open-error #:socket-open-error-code #:*default-read-size*
   ;; Phase 17 — incremental HTTP/1.1 request parser
   #:make-http-parser #:parser-feed #:http-request #:http-request-p
   #:hr-method #:hr-target #:hr-version #:hr-headers #:hr-body #:hr-keep-alive
   #:*max-header-bytes* #:*max-body-bytes*
   #:make-http-response-parser #:response-finish #:http-response #:http-response-p
   #:hres-status #:hres-reason #:hres-version #:hres-headers #:hres-body #:hres-keep-alive
   ;; Phase 18 — reactor HTTP client
   #:http-request-async #:resolve-hostname #:%header
   ;; TLS client (Phase 20): blocking HTTPS request for the worker pool + error mapping.
   #:https-request #:tls-error-message))

;; --- dependent layer (local-nicknames into the base packages above) ---------

(defpackage :clun.cli
  (:use :cl)
  (:local-nicknames (:eng :clun.engine) (:sys :clun.sys))
  (:documentation "Per-command argument parsing, help/version, .env loader.")
  (:export #:parse-cli-args #:cli-action #:cli-get #:load-dotenv))

(defpackage :clun.runtime
  (:use :cl)
  (:local-nicknames (:eng :clun.engine) (:sys :clun.sys) (:lp :clun.loop) (:net :clun.net))
  (:documentation "Globals wiring: console/inspector, process, timers, Clun global, node/ modules.")
  (:export #:install-runtime #:process-exit #:process-exit-code
           #:run-exit-handlers #:*runtime* #:runtime-exit-code #:format-log-args
           #:safe-integer))

(defpackage :clun
  (:use :cl)
  (:local-nicknames (:eng :clun.engine) (:sys :clun.sys) (:cli :clun.cli) (:rt :clun.runtime))
  (:documentation "Toplevel: argv dispatch, version, condition->exit-code.")
  (:export #:main))

(defpackage :clun.transpiler
  (:use :cl)
  (:local-nicknames (:eng :clun.engine) (:sys :clun.sys))
  (:documentation "TypeScript type-stripping (shares the engine lexer).")
  (:export #:strip-types #:unsupported-ts-syntax #:uts-message #:uts-line #:uts-col
           #:uts-path #:ts-source-p #:tsx-path-p))

(defpackage :clun.test-runner
  (:use :cl)
  (:local-nicknames (:eng :clun.engine) (:sys :clun.sys) (:rt :clun.runtime))
  (:documentation "clun test: discovery, scheduler, matchers, diff, reporter.")
  (:export #:run-test-command))

(defpackage :clun.install
  (:use :cl)
  (:documentation "clun install: semver, registry, tarball, integrity, linker, lockfile, cache."))
