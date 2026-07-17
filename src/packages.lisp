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
           #:select-fd-limit
           ;; Phase 07 — path discipline (parse-native-namestring boundary, §3.2)
           #:native->pathname #:pathname->native #:path-join #:path-dirname
           #:path-basename #:path-extension #:absolute-path-p #:normalize-path
           ;; Phase 07 — filesystem primitives (engine-free)
           #:path-exists-p #:file-p #:directory-p #:realpath #:read-file-string
           #:read-directory #:map-directory-entries
           ;; Phase 07 — JSON reader (hand-rolled, engine-free; §3.5)
           #:parse-json #:write-json #:json-error #:json-null #:json-false #:json-true
           #:jget #:jobject-p #:set-nonblocking
           ;; Phase 08 — platform primitives for the runtime (process/console)
           #:stream-fd #:tty-p #:environ-alist #:getenv #:getpid
           #:current-directory #:change-directory #:machine-arch #:platform-name
           #:monotonic-nanoseconds #:unix-milliseconds #:heap-bytes-used
           #:resident-set-bytes #:bytes-consed
           ;; Phase 12 — OS info + CSPRNG bytes for node:os / crypto
           #:os-random-bytes #:hostname #:os-release #:os-type #:tmpdir #:homedir
           #:total-memory #:free-memory #:uptime-seconds #:cpu-count
           ;; Phase 13 — filesystem primitives + errno-carrying condition for node:fs
           #:fs-error #:fs-error-code #:fs-error-errno #:fs-error-syscall #:fs-error-path
           #:fs-code-message
           #:stat* #:stat-at* #:fstat #:fstat-dev #:fstat-ino #:fstat-mode #:fstat-nlink #:fstat-uid
           #:fstat-gid #:fstat-rdev #:fstat-size #:fstat-atime-ns #:fstat-mtime-ns #:fstat-ctime-ns
           #:fstat-file-p #:fstat-dir-p #:fstat-symlink-p
           #:open-regular-file-stream
           #:make-directory #:remove-directory #:remove-file #:rename-path #:make-symlink
           #:read-symlink #:change-mode #:truncate-file #:make-temp-dir #:check-access
           #:touch-file #:remove-recursive #:read-file-octets #:write-file-octets
           #:write-fd-octets #:copy-file* #:copy-file-stream))

(defpackage :clun.csrf
  (:use :cl)
  (:local-nicknames (:crypto :ironclad))
  (:documentation "Engine-free bounded CSRF token encoding, authentication, and expiry.")
  (:export #:core-generate #:core-verify))

(defpackage :clun.password
  (:use :cl)
  (:local-nicknames (:crypto :ironclad))
  (:documentation "Bounded password hashing, PHC/MCF encoding, and verification.")
  (:export
   #:password-error #:password-error-kind #:password-error-detail
   #:hash-password #:verify-password #:validate-encoded-password-hash
   #:+default-argon-memory-cost+ #:+default-argon-time-cost+
   #:+max-password-bytes+ #:+max-encoded-hash-bytes+))

(defpackage :clun.hash
  (:use :cl)
  (:documentation "Pure Common Lisp implementations of Clun.hash algorithms.")
  (:export
   #:hash-octets #:wyhash #:adler32 #:crc32 #:city-hash32 #:city-hash64
   #:xxhash32 #:xxhash64 #:xxhash3 #:murmur32v2 #:murmur32v3 #:murmur64v2
   #:rapidhash))

(defpackage :clun.text.string-width
  (:nicknames :clun.text)
  (:use :cl)
  (:documentation "Unicode-pinned terminal column measurement for Clun.stringWidth.")
  (:export #:+unicode-width-version+ #:codepoint-width #:string-width))

(defpackage :clun.cookies
  (:use :cl)
  (:documentation "Engine-free Cookie and Cookie header parsing/serialization core.")
  (:export
   ;; Conditions and validation boundaries.
   #:cookie-error #:cookie-error-message
   #:invalid-cookie-name #:invalid-cookie-path #:invalid-cookie-domain
   #:invalid-cookie-string
   #:validate-cookie-name #:validate-cookie-path #:validate-cookie-domain
   #:validate-cookie-field-value
   ;; Cookie state. Presence predicates distinguish an absent attribute from a
   ;; present false/zero value without leaking runtime-specific sentinels.
   #:cookie #:cookie-p #:make-cookie #:clone-cookie
   #:cookie-name #:cookie-value #:cookie-domain #:cookie-domain-present-p
   #:cookie-path #:cookie-expires-ms #:cookie-expires-present-p
   #:cookie-max-age #:cookie-max-age-text #:cookie-max-age-present-p
   #:cookie-secure-p #:cookie-http-only-p #:cookie-same-site
   #:cookie-partitioned-p
   #:update-cookie-value #:update-cookie-domain #:clear-cookie-domain
   #:update-cookie-path #:update-cookie-expires #:clear-cookie-expires
   #:update-cookie-max-age #:clear-cookie-max-age
   #:update-cookie-secure #:update-cookie-http-only
   #:update-cookie-same-site #:update-cookie-partitioned
   #:normalize-same-site #:cookie-expired-p #:make-cookie-tombstone
   ;; Wire formats.
   #:parse-set-cookie #:serialize-cookie
   #:parse-http-date #:format-http-date
   #:percent-encode-value #:forgiving-percent-decode
   #:cookie-pair #:cookie-pair-p #:make-cookie-pair
   #:cookie-pair-name #:cookie-pair-value
   #:parse-cookie-header #:parse-cookie-header-fields
   ;; Ordered CookieMap state shared by the runtime and server lifecycle.
   #:cookie-map-state #:cookie-map-state-p #:make-cookie-map-state
   #:make-cookie-map-state-from-header
   #:make-cookie-map-state-from-header-fields
   #:cookie-map-add-original
   #:cookie-map-get #:cookie-map-has #:cookie-map-size
   #:cookie-map-set-cookie #:cookie-map-delete
   #:cookie-map-entry-at #:cookie-map-response-fields
   #:cookie-map-modification-count))

(defpackage :clun.glob
  (:use :cl)
  (:documentation "Immutable, engine-free Glob matching and filesystem traversal.")
  (:export #:compile-glob #:compiled-glob #:compiled-glob-p #:glob-match-p
           #:glob-scan-options #:make-glob-scan-options
           #:glob-scan-options-cwd #:glob-scan-options-dot
           #:glob-scan-options-absolute #:glob-scan-options-follow-symlinks
           #:glob-scan-options-throw-error-on-broken-symlink
           #:glob-scan-options-only-files
           #:glob-accessor #:make-glob-accessor
           #:glob-scan-token #:make-glob-scan-token #:cancel-glob-scan
           #:glob-scan-cancelled #:glob-scan-cancelled-p #:glob-js-path-to-native
           #:glob-native-path-to-js #:scan-glob))

(defpackage :clun.color
  (:use :cl)
  (:documentation "Engine-independent CSS color parsing, conversion, and terminal palettes.")
  (:export #:color #:color-p #:color-space #:color-c1 #:color-c2 #:color-c3 #:color-alpha
           #:make-rgba-color #:parse-color #:color->srgb #:color->rgba-bytes
           #:color->hsl #:color->lab #:format-css-color #:format-color-number
           #:ansi256-index #:ansi16-index))

(defpackage :clun.yaml
  (:use :cl)
  (:documentation "Bounded engine-free YAML 1.2 graph parser for the runtime and module loader.")
  (:export
   #:parse-yaml #:yaml-error #:yaml-error-code #:yaml-error-reason
   #:yaml-error-line #:yaml-error-column #:yaml-error-offset #:yaml-error-document
   #:yaml-stream #:yaml-stream-p #:yaml-stream-documents
   #:yaml-node #:yaml-node-p #:yaml-node-kind #:yaml-node-value #:yaml-node-anchor
   #:yaml-node-tag #:yaml-node-line #:yaml-node-column #:yaml-node-offset #:yaml-node-style
   #:yaml-pair #:yaml-pair-p #:yaml-pair-key #:yaml-pair-value #:yaml-pair-merge-p
   #:+max-source-length+ #:+max-depth+ #:+max-documents+ #:+max-nodes+
   #:+max-edges+ #:+max-anchors+ #:+max-aliases+ #:+max-scalar-length+))

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
   #:register-loop-resource #:register-loop-handle-resource #:unregister-loop-resource
   ;; timers
   #:set-timer #:clear-timer #:timer #:timer-p #:next-timer-delay
   #:timer-ref #:timer-unref #:timer-refd-p
   ;; reactor (sockets land in P16)
   #:reactor-add #:reactor-remove
   ;; signals
   #:install-signal-handler #:remove-signal-handler
   ;; workers
   #:worker-submit #:worker-submit-cancellable #:cancel-worker-job
   #:worker-job #:worker-job-p #:worker-job-state
   #:worker-cancel-token #:worker-cancelled-p))

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
   #:code-units->utf8 #:code-units->utf8-replacing #:utf8->code-units
   #:ta-subview #:high-surrogate-p #:low-surrogate-p
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
   #:current-call-source-span
   #:js-make-object #:js-get #:js-set #:js-delete #:has-property #:has-own-property
   #:create-data-property #:jm-get #:jm-get-own-property #:jm-own-property-keys
   #:callable-p #:get-method #:get-iterator-record #:iterator-step-value
   #:call-with-iterator-close-on-abrupt
   #:js-call #:js-symbol-p #:js-array-p #:js-condition #:js-condition-value
   ;; inspector (Phase 08) — the one shared value renderer
   #:inspect-value #:*inspect-defaults*
   ;; runtime hooks (Phase 08): completion capture for -p, error introspection,
   ;; realm accessors the runtime/CLI need
   #:run-module-file #:run-module-source #:eval-source #:realm-global #:realm-clock-now-ms
   #:realm-coverage-session
   #:register-module-mock
   #:teardown-realm #:run-callback-to-settlement #:drive-jobs #:current-loop
   #:make-coverage-session #:call-with-coverage-session #:coverage-results
   #:promise-and-caps
   #:js-promise-p #:js-promise-pstate #:js-promise-value #:to-string #:js-object-class
   #:make-native-function #:install-method #:install-getter #:install-accessor
   #:data-prop #:fixed-data-prop #:nonconfigurable-data-prop #:hidden-prop
   #:new-object #:new-array #:throw-type-error #:js-undefined-p #:js-truthy #:js-boolean
   #:to-number #:arg #:intrinsic #:function-name #:js-function-p #:js-native-function-p
   #:make-producer-generator #:make-producer-async-generator
   #:async-generator-producer-ready #:async-generator-producer-failed
   #:async-generator-producer-cancelled
   #:js-nullish-p #:array-like->list #:array-length
   ;; object-API surface for node builtin modules (Phase 12)
   #:js-getv #:to-object #:to-boolean #:to-integer-or-infinity #:js-strict-eq
   #:js-same-value #:js-typeof #:make-error-object #:well-known #:length-of-array-like
   #:js-null-p #:js-number-p #:js-string-p #:js-deep-equal #:*builtin-module-builder*
   #:js-construct #:obj-own-desc #:pd-value #:pd-enumerable #:crypto-fill-random
   #:js-loose-eq #:js-instanceof #:throw-js-value #:js-object-class
   #:js-typed-array-p #:make-u8-array #:u8-from-octets #:ta-octets #:u8-over-arraybuffer #:js-array-buffer-bytes #:js-array-buffer-p
   #:buffer-source-octets
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
           #:safe-integer #:execute-shell-script))

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
  (:documentation "clun install: semver, registry, tarball, integrity, linker, lockfile, cache.")
  ;; Phase 21 — node-semver, ported to pure CL (no engine dependency). Versions are
  ;; structs; ranges are an OR of AND-ed comparator sets. Public surface below.
  (:export
   ;; version parsing + accessors
   #:parse-version #:version-valid-p #:semver #:semver-p
   #:semver-major #:semver-minor #:semver-patch #:semver-prerelease
   #:semver-build #:semver-version #:invalid-version #:invalid-range
   ;; comparison + equality + increment/truncate
   #:version-compare #:version-equal #:version-inc #:version-truncate
   ;; ranges: parse, render, satisfaction, outside, intersection
   #:parse-range #:range-valid-p #:range-to-string #:version-satisfies
   #:range-gtr #:range-ltr #:ranges-intersect #:comparators-intersect))

(defpackage :clun.registry
  (:use :cl)
  (:local-nicknames (:net :clun.net) (:sys :clun.sys) (:lp :clun.loop) (:sv :clun.install))
  (:documentation "clun install: the npm registry client — abbreviated metadata fetch over
the Phase-18 HTTP client, engine-free JSON parse, .npmrc-lite + --registry resolution.")
  (:export
   ;; conditions
   #:registry-error #:registry-error-message #:package-not-found #:package-not-found-name
   #:registry-status-error #:registry-status-error-status #:registry-status-error-name
   ;; configuration
   #:*default-registry* #:*abbreviated-accept*
   ;; metadata structs + accessors
   #:pkg-metadata #:pkg-metadata-p #:md-name #:md-dist-tags #:md-versions #:md-modified #:md-etag
   #:version-meta #:version-meta-p #:vm-version #:vm-dependencies #:vm-optional-dependencies
   #:vm-peer-dependencies #:vm-bin #:vm-engines #:vm-os #:vm-cpu #:vm-has-install-script
   #:vm-deprecated #:vm-dist-tarball #:vm-dist-shasum #:vm-dist-integrity
   #:metadata-version #:metadata-latest #:metadata-version-strings
   ;; URL + name encoding
   #:parse-registry-base #:encode-package-name #:metadata-path
   ;; .npmrc + registry resolution
   #:npmrc #:npmrc-p #:parse-npmrc #:npmrc-default-registry #:npmrc-scope-registries
   #:npmrc-auth-tokens #:package-scope #:resolve-registry #:auth-token-for
   ;; parse + fetch
   #:parse-metadata #:fetch-metadata-async))

(defpackage :clun.integrity
  (:use :cl)
  (:documentation "clun install: Subresource-Integrity (SRI) over package tarball bytes — parse
`algo-base64`, compute + verify sha512/256/1 digests (ironclad + cl-base64).")
  (:export
   #:integrity-error #:integrity-error-message
   #:sri #:sri-p #:sri-algorithm #:sri-digest
   #:parse-sri #:digest-bytes #:sri-string #:verify-integrity))

(defpackage :clun.tarball
  (:use :cl)
  (:local-nicknames (:sys :clun.sys) (:integ :clun.integrity))
  (:documentation "clun install: bounded gzip inflate, a read-only ustar/pax tar reader, and a
hardened verify-then-commit extractor + content-addressed cache.")
  (:export
   #:tarball-error #:tarball-error-message
   #:tar-entry #:tar-entry-p #:te-name #:te-mode #:te-size #:te-typeflag #:te-linkname #:te-data
   #:inflate-gzip #:read-tar-entries #:extract-package
   #:cache-root #:cache-path #:cache-store #:cache-fetch
   #:*max-inflated-bytes* #:*max-entry-size*))

(defpackage :clun.installer
  (:use :cl)
  (:local-nicknames (:sys :clun.sys) (:sv :clun.install) (:reg :clun.registry)
                    (:tb :clun.tarball) (:integ :clun.integrity) (:lp :clun.loop) (:net :clun.net))
  (:documentation "clun install: dependency resolution (breadth-first, highest-satisfying,
cycle-safe) + hoisted-layout placement over the Phase-21 registry client, feeding the Phase-22
extractor + cache and the clun.lock lockfile.")
  (:export
   ;; conditions
   #:install-error #:install-error-message #:lock-drift-error
   ;; resolution
   #:inst-node #:inst-node-p #:in-name #:in-version #:in-deps #:in-tarball #:in-integrity #:in-bin
   #:resolve-install #:pick-version
   ;; placement
   #:plan-layout
   ;; linker
   #:link-plan
   ;; lockfile
   #:write-lock #:read-lock #:lock->plan #:lock-value #:lock-satisfies-p #:name-from-physical
   ;; top-level install
   #:read-package-json #:root-deps #:install #:install-async
   ;; package.json editing (add / remove) + latest resolution
   #:add-dependencies #:remove-dependencies #:resolve-latest #:resolve-latest-async
   #:install-result #:install-result-p #:ir-source #:ir-plan #:ir-node-count #:ir-lifecycle-skipped))
