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
           #:make-hard-link #:read-symlink #:change-mode #:change-owner #:truncate-file
           #:set-times #:make-temp-dir #:check-access
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

(defpackage :clun.secrets
  (:use :cl)
  (:local-nicknames (:crypto :ironclad))
  (:documentation
   "Engine-free pure-CL encrypted secrets vault (Bun.secrets API + exceed surface).")
  (:export
   #:secrets-error #:secrets-error-kind #:secrets-error-detail #:secrets-error-code
   #:+not-available-code+ #:+not-available-message+
   #:+platform-error-code+ #:+access-denied-code+
   #:secrets-available-p #:os-secrets-available-p #:reject-os-secrets
   #:validate-service-name #:validate-set-value
   #:secrets-get #:secrets-set #:secrets-delete
   #:secrets-has #:secrets-list #:secrets-clear
   #:vault-path #:default-vault-path
   #:*vault-path-override* #:*master-key-override*))

(defpackage :clun.s3
  (:use :cl)
  (:local-nicknames (:crypto :ironclad))
  (:documentation
   "Pure-CL S3-compatible client (Bun.s3 / S3Client surface + exceed: copy, batch-delete, multipart).")
  (:export
   #:s3-error #:s3-error-kind #:s3-error-status #:s3-error-code
   #:s3-error-message #:s3-error-key #:s3-error-bucket #:s3-error-detail
   #:s3-options #:s3-options-p #:make-s3-options #:merge-options
   #:s3o-access-key-id #:s3o-secret-access-key #:s3o-session-token
   #:s3o-bucket #:s3o-region #:s3o-endpoint #:s3o-virtual-hosted-style
   #:s3o-path-style #:s3o-part-size #:s3o-retry #:s3o-content-type
   #:resolve-credentials #:require-credentials
   #:s3-client #:s3-client-p #:make-s3-client #:client-options #:default-client
   #:s3-file #:s3-file-p #:s3f-key #:s3f-client #:s3f-start #:s3f-end
   #:s3-file-slice #:s3-file-get #:s3-file-text #:s3-file-write
   #:s3-file-delete #:s3-file-exists #:s3-file-stat #:s3-file-presign
   #:s3-put #:s3-get #:s3-get-text #:s3-delete #:s3-head
   #:s3-exists #:s3-size #:s3-stat #:s3-stat-p #:s3s-size #:s3s-etag
   #:s3s-last-modified #:s3s-content-type
   #:s3-list #:s3-copy #:s3-delete-objects #:s3-write
   #:s3-create-multipart #:s3-upload-part #:s3-complete-multipart
   #:s3-abort-multipart
   #:presign #:sign-request #:signing-key #:create-canonical-request
   #:create-string-to-sign #:amz-date #:amz-datestamp
   #:*s3-clock* #:*s3-http-fn*
   #:s3-http-response #:s3hr-status #:s3hr-headers #:s3hr-body
   #:make-s3-mock #:s3-mock-handler #:with-s3-mock
   #:resolve-endpoint #:object-canonical-uri #:%uri-encode #:%sha256-hex
   #:%empty-payload-hash #:%hex #:%hmac-sha256))

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

(defpackage :clun.markdown
  (:use :cl)
  (:documentation "Bounded pure-CL Markdown parser and HTML renderer (Phase 75).")
  (:export
   #:+max-source-length+ #:+max-depth+ #:+max-nodes+
   #:markdown-error #:markdown-error-code #:markdown-error-reason
   #:parse-markdown #:markdown-html #:markdown-render
   #:md-node #:md-node-p #:md-node-kind #:md-node-children #:md-node-meta #:md-node-text
   #:make-markdown-options #:markdown-options-p
   #:markdown-options-tables #:markdown-options-strikethrough
   #:markdown-options-tasklists #:markdown-options-autolinks
   #:markdown-options-headings #:markdown-options-hard-soft-breaks
   #:markdown-options-no-html-blocks #:markdown-options-no-html-spans
   #:markdown-options-tag-filter #:markdown-options-collapse-whitespace))

(defpackage :clun.html
  (:use :cl)
  (:documentation "Bounded pure-CL HTML tokenizer and HTMLRewriter substrate (Phase 75).")
  (:export
   #:+max-source-length+ #:+max-nodes+ #:+max-depth+
   #:html-error #:html-error-code #:html-error-reason
   #:parse-html #:serialize-html #:rewrite-html
   #:html-node #:html-node-p #:html-node-kind #:html-node-name
   #:html-node-attrs #:html-node-children #:html-node-text
   #:html-node-self-closing #:html-node-removed
   #:make-rewriter #:rewriter-on #:rewriter-on-document #:rewriter-transform
   #:element-tag-name #:element-namespace-uri #:element-self-closing
   #:element-can-have-content #:element-removed
   #:element-get-attribute #:element-has-attribute #:element-set-attribute
   #:element-remove-attribute #:element-attributes
   #:element-before #:element-after #:element-prepend #:element-append
   #:element-set-inner-content #:element-remove #:element-remove-and-keep-content
   #:text-chunk-text #:text-chunk-last-in-text-node #:text-chunk-removed
   #:text-chunk-before #:text-chunk-after #:text-chunk-replace #:text-chunk-remove
   #:comment-text #:comment-removed
   #:comment-before #:comment-after #:comment-replace #:comment-remove
   #:void-element-p #:selector-matches-p))

;; Defined before clun.engine so the engine's :lp local-nickname can target it.
(defpackage :clun.loop
  (:use :cl)
  (:documentation "Event loop: reactor, timers, mailbox, handles, signals, workers.")
  (:export
   ;; loop lifecycle
   #:event-loop #:event-loop-p #:make-event-loop #:destroy-event-loop
   #:run-loop #:loop-post #:loop-stop #:el-ref-count #:now-ms
   #:loop-on-thread-p #:run-on-loop #:loop-extension #:*on-foreign-thread*
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
   #:register-module-mock #:register-bun-builtin
   #:plugin-clear-all #:plugin-clear #:plugin-list-names
   #:register-cl-plugin #:register-node-module-hooks #:clear-node-module-hooks
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
   #:js-construct #:obj-own-desc #:pd-value #:pd-enumerable
   #:pd-get #:pd-set #:accessor-descriptor-p #:crypto-fill-random
   #:js-loose-eq #:js-instanceof #:throw-js-value #:js-object-class
   #:js-typed-array-p #:make-u8-array #:u8-from-octets #:ta-octets #:u8-over-arraybuffer #:js-array-buffer-bytes #:js-array-buffer-p
   #:buffer-source-octets
   #:code-units->utf8 #:utf8->code-units #:ta-subview
   ;; TS strip hook (Phase 09): the loader applies this to .ts/.mts/.cts source
   ;; before parse-program; the transpiler installs it (engine stays dep-free).
   #:*ts-strip-hook* #:*jsx-transform-hook* #:*html-entry-loader*
   #:make-lexer #:next-token #:reread-regexp #:reread-template
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
   #:tcp-listen #:tcp-connect #:tcp-connect-happy #:tcp-write #:tcp-close #:tcp-shutdown
   #:tcp-pause #:tcp-resume
   #:tcp #:tcp-p #:tcp-state #:tcp-queued-bytes #:tcp-peer #:tcp-local
   #:tcp-on-data #:tcp-on-close #:tcp-on-error #:tcp-on-drain
   #:listener #:listener-p #:listener-port #:listener-close #:listener-address
   #:socket-error-code #:socket-open-error #:socket-open-error-code #:*default-read-size*
   ;; Phase 28 -- bounded DNS + address-family racing
   #:dns-error #:dns-error-message #:dns-address #:dns-address-text
   #:dns-address-ipv6-p #:resolve-hostname-all #:resolve-hostname
   ;; Phase 17 — incremental HTTP/1.1 request parser
   #:make-http-parser #:parser-feed #:http-request #:http-request-p
   #:hr-method #:hr-target #:hr-version #:hr-headers #:hr-body #:hr-keep-alive
   #:*max-header-bytes* #:*max-body-bytes*
   #:make-http-response-parser #:response-finish #:http-response #:http-response-p
   #:hres-status #:hres-reason #:hres-version #:hres-headers #:hres-body #:hres-keep-alive
   #:make-http-response-stream-parser #:response-stream-feed #:response-stream-finish
   #:response-stream-reusable-p
   ;; Phase 18 — reactor HTTP client
   #:http-request-async #:http-request-stream-async #:resolve-hostname #:%header
   #:http-content-decoding-error #:http-content-decoding-error-message
   #:*max-decoded-body-bytes*
   ;; TLS client (Phase 20): blocking HTTPS request for the worker pool + error mapping.
   #:https-request #:https-request-stream #:tls-error-message))

;; Phase 51 — WebSocket protocol (RFC 6455 + Pub/Sub substrate + deflate).

(defpackage :clun.redis
  (:use :cl)
  (:local-nicknames (:sys :clun.sys))
  (:documentation
   "Pure-CL Redis/Valkey RESP client + embedded store (FULL PORT #184 / epic #177).
    Exceeds Bun.redis: offline hermetic store needs no external Redis process.
    Full command surface is available via REDIS-CALL / STORE-EXECUTE (string
    commands). Named helpers cover the Bun.redis core client path.")
  (:export
   ;; Errors
   #:redis-error #:redis-error-message #:redis-error-code
   #:redis-reply-error #:redis-reply-error-message
   ;; RESP
   #:resp-encode #:resp-encode-value #:resp-encode-error
   #:resp-decode-from-stream #:resp-decode-buffer
   ;; URL / options
   #:default-redis-url #:*default-redis-url*
   ;; Client lifecycle
   #:redis-client #:redis-client-p #:make-redis-client
   #:redis-connect #:redis-close #:redis-client-connected-p
   #:redis-duplicate #:default-redis #:*redis*
   ;; Core dispatch (full Redis command surface via string commands)
   #:redis-call #:redis-send
   ;; Bun-shaped named helpers
   #:redis-get #:redis-set #:redis-del #:redis-exists
   #:redis-incr #:redis-publish #:redis-subscribe
   ;; Embedded peer (exceed Bun — hermetic pure-CL Redis)
   #:make-redis-store #:redis-store-p
   #:store-execute
   #:start-embedded-redis #:stop-embedded-redis
   #:embedded-redis-port #:embedded-redis-host
   #:with-embedded-redis))

(defpackage :clun.websocket
  (:use :cl)
  (:local-nicknames (:crypto :ironclad))
  (:documentation
   "Pure Common Lisp WebSocket (RFC 6455 handshake/framing, fragmentation helpers,
    and bounded permessage-deflate inflate via chipz). Server Pub/Sub and the
    client WebSocket global live in clun.runtime; see docs/design/phase-51.md.")
  (:export
   #:+opcode-continuation+ #:+opcode-text+ #:+opcode-binary+
   #:+opcode-close+ #:+opcode-ping+ #:+opcode-pong+
   #:+ws-guid+ #:+default-max-payload-bytes+ #:+default-backpressure-limit+
   #:+max-control-payload+ #:+default-max-inflate-bytes+ #:+pmd-trailer+
   #:websocket-error #:websocket-error-message
   #:websocket-unsupported #:websocket-protocol-error
   #:websocket-not-implemented-message #:signal-websocket-unsupported
   #:ws-frame #:ws-frame-p #:make-ws-frame
   #:ws-frame-fin #:ws-frame-rsv1 #:ws-frame-rsv2 #:ws-frame-rsv3
   #:ws-frame-opcode #:ws-frame-masked #:ws-frame-payload #:ws-frame-mask-key
   #:ws-handler-options #:ws-handler-options-p #:make-ws-handler-options
   #:ws-handler-options-max-payload-length
   #:ws-handler-options-backpressure-limit
   #:ws-handler-options-close-on-backpressure-limit
   #:ws-handler-options-idle-timeout-seconds
   #:ws-handler-options-publish-to-self
   #:ws-handler-options-send-pings
   #:ws-handler-options-permessage-deflate
   #:ws-handler-options-open #:ws-handler-options-message
   #:ws-handler-options-close #:ws-handler-options-ping
   #:ws-handler-options-pong #:ws-handler-options-drain
   #:handshake-accept-key #:encode-frame #:decode-frame
   #:mask-payload #:websocket-upgrade-request-p #:opening-handshake-response
   #:make-close-payload #:parse-close-payload
   #:make-text-frame #:make-binary-frame
   #:make-ping-frame #:make-pong-frame #:make-close-frame
   #:random-mask-key #:client-opening-handshake-request
   #:parse-http-response-head #:extension-token-member-p
   #:fragment-start-p #:append-octets
   #:inflate-permessage-deflate #:compress-permessage-deflate
   #:deflate-stored-block
   #:ws-fragment-state #:ws-fragment-state-p #:make-ws-fragment-state
   #:ws-fragment-state-active-p #:fragment-reset #:fragment-feed
   #:ws-topic-hub #:ws-topic-hub-p #:make-ws-topic-hub
   #:topic-subscribe #:topic-unsubscribe #:topic-unsubscribe-all
   #:topic-subscribed-p #:topic-subscriptions
   #:topic-subscriber-count #:topic-subscribers
   #:client-offers-permessage-deflate-p #:parse-sec-websocket-extensions
   #:make-client-key))

(defpackage :clun.compress
  (:use :cl)
  (:documentation "Phase 74 pure-CL gzip/zlib/raw-deflate codecs (salza2 compress + chipz inflate).")
  (:export
   #:compress-error #:compress-error-message
   #:*max-decompressed-bytes*
   #:gzip-compress #:zlib-compress #:raw-deflate-compress
   #:gunzip #:zlib-decompress #:raw-inflate
   #:gzip-magic-p))

(defpackage :clun.sfe
  (:use :cl)
  (:local-nicknames (:sys :clun.sys) (:crypto :ironclad) (:eng :clun.engine))
  (:documentation
   "Pure-CL single-file executables (FULL PORT #181 / epic #177).
    Compile, cross-compile via offline templates, embed assets, pure-CL sign/verify.
    Exceeds Bun compile: multi-target offline packaging, all-platform signatures,
    registerTemplate, verify without codesign, GPL source notice, reproducible build-id.")
  (:export
   #:sfe-error #:sfe-error-kind #:sfe-error-detail
   #:+sea-magic+ #:+sea-version+
   #:sea-file-p #:open-sea #:strip-sea #:write-sea #:read-footer
   #:encode-payload #:decode-payload
   #:host-target #:normalize-target #:all-four-targets
   #:register-template #:clear-templates #:list-templates #:resolve-template
   #:self-executable-path
   #:collect-module-graph #:load-assets #:prepare-modules
   #:generate-signing-key #:sign-payload #:verify-payload #:verify-sea
   #:payload-digest-hex
   #:compile-executable #:compile-all-targets
   #:sea-boot-info #:materialize-modules #:be-clun-mode-p
   #:install-embedded-assets #:embedded-asset #:embedded-asset-text
   #:*embedded-sea* #:*embedded-assets*
   #:+gpl-source-notice+
   #:perform-image-dump #:image-sfe-p #:verify-path
   #:*sfe-image-mode* #:*sfe-entry* #:*sfe-manifest*))
;; --- dependent layer (local-nicknames into the base packages above) ---------

(defpackage :clun.cli
  (:use :cl)
  (:local-nicknames (:eng :clun.engine) (:sys :clun.sys))
  (:documentation "Per-command argument parsing, help/version, .env loader.")
  (:export #:parse-cli-args #:cli-action #:cli-get #:load-dotenv
           #:parse-build-args))

(defpackage :clun.runtime
  (:use :cl)
  (:local-nicknames (:eng :clun.engine) (:sys :clun.sys) (:lp :clun.loop)
                    (:net :clun.net) (:ws :clun.websocket)
                    (:cmp :clun.compress))
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
  (:documentation "TypeScript type-stripping and JSX/TSX transform (shares the engine lexer).")
  (:export #:strip-types #:unsupported-ts-syntax #:uts-message #:uts-line #:uts-col
           #:uts-path #:ts-source-p #:tsx-path-p #:jsx-path-p
           #:transform-jsx #:transform-jsx-file #:jsx-config #:make-jsx-config))

(defpackage :clun.test-runner
  (:use :cl)
  (:local-nicknames (:eng :clun.engine) (:sys :clun.sys) (:rt :clun.runtime)
                    (:lp :clun.loop))
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

(defpackage :clun.archive
  (:use :cl)
  (:local-nicknames (:sys :clun.sys) (:tb :clun.tarball) (:cmp :clun.compress))
  (:documentation "Phase 74 pure-CL ustar writer + tar/tar.gz extract helpers for Clun.Archive.")
  (:export
   #:write-tar #:build-archive-bytes #:parse-archive-bytes #:extract-archive
   #:%glob-match
   #:build-zip #:read-zip-entries))

(defpackage :clun.installer
  (:use :cl)
  (:local-nicknames (:sys :clun.sys) (:sv :clun.install) (:reg :clun.registry)
                    (:tb :clun.tarball) (:integ :clun.integrity) (:lp :clun.loop) (:net :clun.net))
  (:documentation "clun install: dependency resolution (breadth-first, highest-satisfying,
cycle-safe) + hoisted-layout placement over the Phase-21 registry client, feeding the Phase-22
extractor + cache and the clun.lock lockfile. Phase 60 monorepo workspaces, catalogs, filters,
and concurrent topological script runs.")
  (:export
   ;; conditions
   #:install-error #:install-error-message #:lock-drift-error
   ;; resolution
   #:inst-node #:inst-node-p #:in-name #:in-version #:in-deps #:in-tarball #:in-integrity #:in-bin
   #:in-kind #:in-local-path #:in-optional #:in-real-name
   #:resolve-install #:pick-version #:classify-dep-spec
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
   #:install-result #:install-result-p #:ir-source #:ir-plan #:ir-node-count #:ir-lifecycle-skipped
   ;; monorepo workspaces (Phase 60)
   #:workspace #:workspace-p #:ws-name #:ws-version #:ws-path #:ws-relative #:ws-package #:ws-deps #:ws-scripts
   #:workspace-graph #:workspace-graph-p #:wg-root #:wg-packages #:wg-by-name #:wg-catalog #:wg-catalogs
   #:discover-workspaces #:workspace-packages #:filter-workspaces #:workspace-matches-filter-p
   #:parse-workspaces-field #:expand-dep-spec #:resolve-catalog-range
   #:collect-install-deps #:workspace-link-deps #:workspace-topo-waves
   #:run-workspace-scripts #:workspace-spec-p #:catalog-spec-p))
(defpackage :clun.sql
  (:use :cl)
  (:local-nicknames (:crypto :ironclad) (:sys :clun.sys))
  (:documentation "Pure-CL unified SQL client: PostgreSQL + MySQL wire protocols and embedded SQLite engine (Issue #183). Exceeds Bun.SQL with inspect/stats/export/query-log.")
  (:export
   ;; errors
   #:sql-error #:sql-error-message #:sql-error-code #:sql-error-adapter
   #:sql-error-sqlstate #:sql-error-detail #:sql-error-hint #:sql-error-query
   #:sql-error-position #:sql-error-errno #:sql-error-severity
   #:sql-error-schema #:sql-error-table #:sql-error-column #:sql-error-constraint
   #:sql-error-byte-offset
   #:postgres-error #:mysql-error #:sqlite-error
   #:sql-protocol-error #:sql-connection-error #:sql-timeout-error #:sql-cancel-error
   ;; options / client
   #:sql-options #:sql-options-p #:so-adapter #:so-hostname #:so-port #:so-username
   #:so-password #:so-database #:so-filename #:so-max
   #:parse-sql-url #:merge-sql-options
   #:sql-client #:sql-client-p #:client-adapter #:client-options #:client-closed
   #:make-sql-client #:sql-connect #:sql-close #:sql-end #:sql-flush
   #:sql-execute #:sql-query #:sql-unsafe #:sql-file
   #:sql-array #:sql-helper #:sql-fragment
   #:sql-reserve #:sql-release
   #:sql-begin #:sql-transaction #:sql-savepoint
   #:sql-begin-distributed #:sql-commit-distributed #:sql-rollback-distributed
   ;; exceed
   #:sql-inspect #:sql-stats #:sql-export #:sql-enable-query-log #:sql-query-log
   #:result-rows #:result-first
   #:make-sql-fragment #:make-sql-helper #:make-sql-array-parameter
   #:frag-sql #:frag-params #:helper-value #:helper-columns
   #:sql-array-parameter
   ;; mocks for hermetic tests
   #:*sql-mock-postgres* #:*sql-mock-mysql*
   ;; low-level backends (tests)
   #:open-sqlite #:close-sqlite #:sqlite-exec #:sqlite-inspect #:sqlite-export-json
   #:connect-postgres #:close-postgres #:postgres-exec
   #:connect-mysql #:close-mysql #:mysql-exec
   #:compile-template #:serialize-array-parameter))

(defpackage :clun.bundler
  (:use :cl)
  (:local-nicknames (:eng :clun.engine) (:sys :clun.sys) (:rslv :clun.resolver))
  (:documentation
   "Pure-CL production bundler (Bun.build surface): graph, loaders, split, minify, assets.")
  (:export
   #:build #:analyze #:build-to-string
   #:build-config #:make-build-config #:make-config-from-plist #:build-config-p
   #:build-result #:build-result-p #:br-success #:br-outputs #:br-logs #:br-metafile
   #:build-artifact #:build-artifact-p #:ba-path #:ba-kind #:ba-text #:ba-loader
   #:ba-hash #:ba-entry-point-p #:ba-sourcemap
   #:build-error #:build-error-message #:build-error-path #:build-error-level))

;; FULL PORT #190 — first-party formatter + linter (Phases 69–70).
(defpackage :clun.fmt
  (:use :cl)
  (:local-nicknames (:eng :clun.engine) (:sys :clun.sys) (:glob :clun.glob))
  (:documentation
   "Pure-CL first-party source formatter (JS/TS/JSX/JSON/YAML/CSS). Exceeds Bun.")
  (:export
   #:fmt-error #:fmt-error-message #:fmt-error-path
   #:fmt-options #:make-fmt-options #:default-fmt-options
   #:fo-indent #:fo-print-width #:fo-semicolons #:fo-single-quote
   #:fo-trailing-comma #:fo-line-ending #:fo-insert-final-newline #:fo-language
   #:format-source #:format-file #:format-paths
   #:fmt-result #:fr-path #:fr-changed #:fr-error #:fr-formatted
   #:language-from-path #:language-from-source
   #:read-ignore-patterns #:collect-format-files #:path-ignored-p))

(defpackage :clun.lint
  (:use :cl)
  (:local-nicknames (:eng :clun.engine) (:sys :clun.sys) (:glob :clun.glob))
  (:documentation
   "Pure-CL first-party linter with recommended ruleset. Exceeds Bun.")
  (:export
   #:lint-error #:lint-error-message #:lint-error-path
   #:diagnostic #:diag-rule #:diag-severity #:diag-message #:diag-path
   #:diag-line #:diag-column #:diag-fix
   #:lint-config #:default-lint-config #:load-lint-config #:set-rule
   #:lc-rules #:lc-globals #:lc-env #:lc-fix
   #:lint-source #:lint-file #:lint-paths
   #:apply-safe-fixes
   #:report-stylish #:report-json
   #:diagnostics-error-count #:diagnostics-warn-count
   #:*recommended-rules*))

