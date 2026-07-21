# Clun

**Bun, rewritten in pure Common Lisp.** Clun is a JavaScript/TypeScript runtime and toolkit —
including a from-scratch ECMAScript engine — implemented in **pure Common Lisp** with zero CFFI
and zero foreign libraries. The pre-1.0 series prioritizes correctness and purity while the full-port program targets complete capability over
breadth. The active prerelease roadmap targets evidence-backed parity with Bun's purity-compatible
surface, one gated capability at a time, before a final re-baselined hardening phase. Performance
targets are workload-specific and published;
Clun does not claim blanket speed parity with Bun.

<!-- clun-generated:release:begin -->
> **Status: stable release train.** Release target: `0.2.1` / `v0.2.1` (SemVer impact: `patch`).
> Tracking: [issue #320](https://github.com/theesfeld/clun/issues/320).
> The verified release boundary is `v0.2.0` until this candidate publishes.
> Capability matrix: 30 Yes / 0 Partial / 0 No.
<!-- clun-generated:release:end -->

The current source is the `0.2.1` stable candidate; immutable tag and assets are not published yet.
The last published release remains [`v0.2.0`](https://github.com/theesfeld/clun/releases/tag/v0.2.0)
(four native archives, `checksums.txt`, `~/.local/bin`, built-in updater). Tracking:
[issue #320](https://github.com/theesfeld/clun/issues/320) (man page install + hard CLI sync rule).
Phase 82 ([#56](https://github.com/theesfeld/clun/issues/56)) closed the purity-compatible surface audit;
Phase 26 ([#58](https://github.com/theesfeld/clun/issues/58)) closed first stable `0.2.0`.

## Install
Tagged releases are installed by the same POSIX shell command on Linux and macOS:

```sh
curl -fsSL https://clun.sh/install | sh
```

The no-argument installer defaults to the release ledger's verified installable boundary, so a newly
published GitHub Release cannot outrun its claims and hosted smoke test. Explicit
`INSTALL_VERSION=latest` resolves `github.com/theesfeld/clun/releases/latest` first, then falls back
to the Releases API and the public Releases Atom feed. The API honors `GITHUB_TOKEN` or `GH_TOKEN`;
the feed keeps prerelease-only resolution working after an unauthenticated API 403. Fallback
candidates are compared as SemVer rather than accepted in chronological response order. The installer
detects x86-64 or arm64, verifies the published SHA-256 checksum, stages the complete versioned bundle under
`${XDG_DATA_HOME:-$HOME/.local/share}/clun/releases`, and installs `clun` into `~/.local/bin` as an
atomically switched stable launcher.
If that directory is missing from `PATH`, the installer prints the current-shell export and adds one
idempotent marked block to `.bashrc`, `.zshrc`, or Fish's `config.fish`. Validation failure leaves the
prior launcher and bundle intact.

```sh
# Exact destination, pinned release, or PATH-control overrides
curl -fsSL https://clun.sh/install | INSTALL_DIR="$HOME/bin" sh
curl -fsSL https://clun.sh/install | INSTALL_VERSION=latest sh
curl -fsSL https://clun.sh/install | INSTALL_VERSION=0.2.0-dev.6 sh
curl -fsSL https://clun.sh/install | ADD_PATH=0 sh   # print export; do not edit an rc file
curl -fsSL https://clun.sh/install | ADD_PATH=1 sh   # ensure the managed rc block exists
```

Existing `~/.clun` installations remain supported: `CLUN_INSTALL="$HOME/.clun"` retains the legacy
release-root layout, while `CLUN_VERSION` and `CLUN_NO_MODIFY_PATH=1` remain compatibility aliases.
While the hosted boundary remains `v0.2.0`, that command only reinstalls `v0.2.0` and does not
activate the `0.2.1` candidate until `v0.2.1` assets publish. The published `v0.2.0` boundary includes
the built-in updater (`clun --update` / `clun check-update`), maturity-aware channel selection, and TLS
multi-asset recovery messaging.

Existing users can reinstall through the checksum-verifying installer or `clun --update`:
```sh
curl -fsSL https://clun.sh/install | sh
# legacy ~/.clun layout:
curl -fsSL https://clun.sh/install | CLUN_INSTALL="$HOME/.clun" CLUN_NO_MODIFY_PATH=1 sh
```

The release workflow exercises the modern installer on Ubuntu and macOS 15 runners for x64 and arm64.
macOS archives target macOS 13.0 or newer, but are runtime-tested on macOS 15. Windows is not supported.

After install, `man clun` documents the same commands and flags as `clun --help`. The man page is
generated from `src/cli/catalog.lisp` and must always match live CLI functionality (`make man` /
`make man-check`).

### Update

The built-in updater uses direct pure-Common-Lisp HTTPS/TLS and the same redirect, authenticated API,
and public Atom-feed resolution. It selects the highest suitable SemVer while keeping stable installs
off prereleases, verifies `checksums.txt` and the package's exact `VERSION`, stages the complete
versioned bundle, and atomically switches the installer-managed stable launcher only after the new
bundle runs successfully. Any failure retains the prior bundle and launcher.

```sh
clun --check-update   # non-mutating; exit 1 if behind
clun --update         # verify and activate the complete release bundle
# or: clun check-update / clun update
```

Clun is pre-1.0 on the stable `0.2.0` train (pre-1.0 minors may still include breaking changes). The published `v0.2.0` binary has live `registry.npmjs.org` receipts for both `clun add <pkg>` and Bun-compatible `clun install <pkg>`, including a transitive dependency graph, SRI-verified tarballs, installed-package execution, and byte-identical frozen cache-only reinstalls while both registry metadata and public HTTPS tarball fallback are denied. Empty directories get an auto-created `package.json` on first add/install. Packages commit in deterministic ancestor-before-descendant order. The live, non-hermetic gate uses Clun's experimental bounded pure-CL TLS profile (not browser-grade WebPKI). Prior `v0.1.0-dev.21` / early `0.2.0-dev.*` binaries predate parts of that path. Publication evidence for the installable boundary is on the Release for `v0.2.0`.

## What works

- JavaScript, JSON, ESM, CommonJS, TypeScript (erasable strip, enums/namespaces/param-props,
  experimental decorators, import=/export=, angle-bracket casts, `.tsx`, and `clun tsc`
  structural typecheck — Phase 39 / #192), and JSX/TSX execution via pure Common Lisp transform
  (classic and automatic runtimes; Phase 40 / #186).
- Object integrity and legacy accessor operations including `Object.seal`, `Object.isSealed`,
  `__defineGetter__`, `__defineSetter__`, `__lookupGetter__`, and `__lookupSetter__`. Proxy traps and
  invariants are implemented for the covered paths; this is not a blanket modern-ECMAScript claim.
- Shared iterator operations now drive lazy `for...of`, destructuring, `Array.from`, collection
  constructors, and Promise combinators, including iterator close on abrupt completion.
- Parameter defaults, catch patterns, and the covered destructuring paths enforce temporal dead
  zones; `const` bindings reject assignment, and anonymous parameter defaults receive inferred names.
- Functions and classes now distinguish calls from construction, implement derived `this` and
  `super`, separate parameter/body/name environments, expose mapped and unmapped arguments objects,
  delegate bound construction, and preserve source text for the covered callable forms.
- Same-realm synchronous generators support dynamic `GeneratorFunction` construction, per-function
  prototypes, and `yield*` delegation with iterator-result identity and close/error precedence.
  Cross-realm generator semantics remain outside the current milestone.
- Async generators serialize `next`, `return`, and `throw` requests, await yielded and returned
  values, reject incompatible receivers, and support async `yield*`. Async iteration includes
  AsyncFromSync fallback and completion-correct `for await...of` close behavior.
- Timers, promises, files, streaming HTTP request/response bodies, `fetch`, URL APIs, and process spawning.
- `clun test` with hooks, filters, async tests, timeouts, 62 core and extended matchers, function
  mocks/spies, expected-failure modifiers, snapshots, cooperative concurrency, parallel files,
  array-parameterized tests and suites, retries, and repeats.
- `clun install [pkg…]`, `add`, `remove`, and package scripts with a deterministic lockfile and cache.
  First `add` / `install <pkg>` in a directory without `package.json` creates a minimal manifest
  (npm/Bun empty-dir behavior). Bare `clun install` still requires an existing project manifest.

The checked-in curated test262 pass list contains 26,018 tests. The current
40,654-row off-mode execution ledger measures 26,018 passes and 2,145 gaps across 28,163 eligible tests
(92.38%), with 12,491 skips and zero crashes. Phase 25b's 90% target is met: the 25,347-pass target has
zero remaining lift. The pass list gained 967 tests from milestone 5 and 3,375 from the Phase 25b entry.
Its focused m6 slice contains 509 tests: 407 pass and 102 fail, with zero skips, timeouts, and crashes.
All 407 milestone-owned rows pass; the 102 deliberate controls remain assigned to m11 (7) and Phase 37
(95), leaving m6 with no owned residual. Three additional `Promise.prototype.finally` rows passed
incidentally: `species-constructor.js`, `subclass-reject-count.js`, and `subclass-resolve-count.js`.
Phase 32's supporting Proxy infrastructure adds 13 newly frozen passes without making a blanket Proxy
compatibility claim. Phase 37 milestone 1 adds 173 more frozen passes without claiming complete modern
ECMAScript parity. The full gap inventory assigns 1,767 residuals to Phase 25b and 378 to Phase 37.
The canonical execution ledger digest is `ECC1719FA1FA8A61`.
The off/eager ledgers are byte-identical; eager mode compiled
1,030,545 forms, classified 56,018 as ineligible, fell back zero times, and executed zero interpreter
fallbacks. The parse gate classifies
23,713 tests as 17,699 pass, 976 fail, 5,038 skip, and zero crash
while retaining all 17,512 frozen passes.
The current full Common Lisp suite passes 19,848 assertions with zero failures and zero skips.
Phase 25's final
default-tier measurements are 6.68x Richards, 3.85x DeltaBlue, and 5.36x Splay against the frozen
Phase-24 Clun baseline, a 5.16x suite geomean. Clun has no measured cross-runtime benchmark against
Bun or Node.js; `docs/benchmarks.md` reports only reproducible Clun-versus-Clun measurements.

## Compatibility roadmap

<!-- clun-generated:compatibility:begin -->
The current column describes stable behavior as tested today. A linked phase is a planned acceptance
gate, not a claim that the capability already exists. Every row below is generated from the canonical
compatibility ledger; `make docs-check` rejects hand-edited status, evidence, owner, or baseline drift.

The public comparison snapshot uses Bun 1.3.14, Node.js 26.5.0, and Deno 2.9.3, checked
July 16, 2026. Engineering references are separately pinned to Bun commit `c1076ce95e` (`1.4.0-dev`).

| Capability | Current stable state | Evidence-backed target |
|---|---|---|
| Node.js compatibility | Yes: pure-CL Bun-comparable node: matrix (54 builtins: assert async_hooks buffer child_process cluster console constants crypto dgram diagnostics_channel dns domain events fs http http2 https inspector module net os path perf_hooks process punycode querystring readline repl sqlite stream string_decoder sys timers tls trace_events tty url util v8 vm wasi worker_threads zlib test); exceeds Bun on sqlite module.register registerHooks createSecurePair repl | Phases [42](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-42), [43](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-43), [44](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-44), [45](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-45), [46](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-46), [47](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-47) |
| Web Standard APIs | Yes: `fetch` with streaming clone/tee, operation-wide timeouts, HTTP proxy and HTTPS CONNECT including proxy object `{url,headers}`, plain HTTP and origin-keyed pure-tls HTTPS idle pooling; URL/URLSearchParams; Headers/Request/Response/Blob/File/FormData; AbortController/AbortSignal; Event/EventTarget/CustomEvent/DOMException; TextEncoder/TextDecoder; atob/btoa; performance.now; MessageChannel/MessagePort; crypto.randomUUID/getRandomValues and crypto.subtle.digest; ReadableStream default and BYOB readers, WritableStream, TransformStream with pipeTo/pipeThrough, CountQueuingStrategy/ByteLengthQueuingStrategy; CompressionStream/DecompressionStream (gzip/deflate/deflate-raw); structuredClone; WebSocket client; hermetic large-transfer and network-stress receipts (exceeds Bun pure-CL surface) | [Phase 38](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-38) |
| Native addons | Yes: pure-CL host processes and hooks user native shared libraries (.so/.dylib/.node) via a narrow allowlisted load/call boundary; Bun.ffi-shaped dlopen/linkSymbols/typed call; registered CL libraries, bounds-checked virtual memory, N-API-style registry, and .claddon packs | [Phase 48](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-48) |
| TypeScript | Yes: pure Common Lisp TypeScript execution: erasable strip, enums, namespaces, parameter properties, experimental decorators, import=/export=, angle-bracket casts, .tsx via JSX lower+strip, and structural typecheck CLI (clun tsc) exceeding Bun (Bun has no typecheck) | [Phase 39](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-39) |
| JSX | Yes: pure Common Lisp JSX and TSX parse, transform, and execute with classic React.createElement and automatic jsx/jsxs/Fragment runtimes, file pragmas, tsconfig/jsconfig compilerOptions, fragments, spreads, nested expressions, member tags, HTML entity decoding, and built-in offline helpers that run without a react package (exceeds Bun) | [Phase 40](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-40) |
| Module loader plugins | Yes: pure Common Lisp Bun.plugin-compatible Clun.plugin with ordered onResolve/onLoad/onStart/onEnd, namespaces, virtual builder.module, object/js/json/yaml/text/file loaders, clearAll plus exceed list/clear/priority/registerHooks and pure-CL register-cl-plugin (exceeds Bun.plugin and node:module hooks) | [Phase 41](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-41) |
| SQL database drivers | Yes: `Clun.SQL` pure-CL PostgreSQL+MySQL wire + embedded SQLite engine; Bun.SQL-compatible unified API plus inspect/stats/export/queryLog | Phases [55](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-55), [56](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-56), [57](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-57) |
| S3 cloud storage | Yes: `Clun.s3` pure-CL AWS SigV4 S3-compatible client (list/get/put/delete/exists/stat/presign/multipart; credentials; path-style and virtual-hosted) | [Phase 53](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-53) |
| Redis client | Yes: `Clun.redis` pure-CL RESP client with embedded offline Redis store (get/set/del/exists/incr/publish/subscribe); Bun.redis-compatible Promise API; offline Yes without external Redis (exceeds Bun) | [Phase 54](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-54) |
| WebSocket server | Yes: `Clun.serve` WebSocket upgrade, RFC 6455 framing, fragmentation reassembly, Pub/Sub (`publish`/`subscriberCount`/`subscribe`), permessage-deflate (chipz inflate + stored compress), and browser-shaped `WebSocket` client (`ws:`) | [Phase 51](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-51) |
| HTTP server | Yes: HTTP/1.1 Clun.serve with streaming request/response bodies (chunked Transfer-Encoding), keep-alive, idleTimeout, maxRequestBodySize, stop(force) | [Phase 49](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-49) |
| HTTP router | Yes: `Clun.serve({ routes })` and `Clun.FileSystemRouter` | [Phase 50](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-50) |
| Single-file executables | Yes: `clun build --compile` / `Clun.build({compile})` pure-CL single-file executables with cross-target offline templates, embedded assets, Ed25519/HMAC sign+verify on every platform, GPL source notice, reproducible build-id, and CLUN_BE_CLUN CLI mode (exceeds Bun compile) | Phases [52](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-52), [77](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-77) |
| YAML | Yes: `Clun.YAML` parser/stringifier and `.yaml`/`.yml` module loading | [Phase 31](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-31) |
| Cookies API | Yes: `Clun.Cookie` and `Clun.CookieMap` with request/response integration | [Phase 32](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-32) |
| Encrypted secrets storage | Yes: `Clun.secrets` Bun-shaped get/set/delete plus has/list/clear on pure-CL AES-256-GCM encrypted storage (exceeds Bun.secrets API; no Keychain/libsecret FFI) | [Phase 58](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-58) |
| npm package management | Yes: `clun add <pkg>` and Bun-compatible `clun install <pkg>` resolve public npm metadata and tarballs through pure-CL TLS; no-argument install resolves the existing manifest with SRI, clun.lock, node_modules, offline cache, aliases, local packages, optional deps, hoisting, and workspaces; `clun publish` packs a package/ tarball and PUTs an authenticated npm attach-document (NPM_TOKEN / .npmrc _authToken) | Phases [28](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-28), [59](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-59), [60](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-60), [61](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-61) |
| Bundler | Yes: Clun.build and clun build pure-CL production bundler: entrypoints, dependency graph, ESM/CJS/IIFE formats, code splitting, minification, loaders (js/ts/tsx/jsx/json/text/file/dataurl/css/html), define, external, packages external or bundle, naming templates, banner/footer, metafile, sourcemaps, target, publicPath, env inlining, drop, features, virtual files, tree shaking, asset hashing, Clun.build.analyze and Clun.buildSync exceed surface, four-target receipts | Phases [62](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-62), [63](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-63), [64](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-64), [77](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-77) |
| Cross-platform shell API | Yes: `Clun.$`, `clun exec`, standalone `.bun.sh` files with positional parameters, dollar and backtick command substitution, background jobs and wait, merged stdout/stderr pipelines, grouped subshells and brace groups nested across `if` control flow, Blob/Response I/O, positive extended-glob conditions, compound-word field splitting, 100-level arrays, Unicode, tilde and continuation expansion, builtins, and 1,598/1,630 pinned shell sites (32 upstream-inactive) | [Phase 65](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-65) |
| Jest-compatible test runner | Yes: 62 core and extended matchers, snapshot lifecycles with stable property tokens and Bun-formatted core values including own-accessor Getter tokens and control-byte escapes, source-aligned ESM/CommonJS/TypeScript statement and function coverage with Bun-shaped text and LCOV reporters, filters, config, and thresholds, custom and Promise-settlement asymmetric matchers, per-realm ESM/CJS module mocks, CLI and bunfig setup preloads, realm-local Jest and vi fake timers with Date and performance clock control, seeded Bun-pinned randomization, deterministic file sharding, dots and JUnit reporters, function mocks/spies, callbacks, cleanup, parameterization, retries, repeats, cooperative test.concurrent / describe.concurrent / test.serial scheduling with --concurrent and --max-concurrency, pure-CL --parallel multi-file process pools with serial/parallel count agreement, expect.unreachable, and runtime expectTypeOf | [Phase 66](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-66) |
| Hot reloading | Yes: clun --hot state-preserving server reload with connection retention, pure-CL stat-poll watcher, module-graph soft re-evaluation, import.meta.hot dispose/accept/data, Clun.hot introspection, --watch hard restart, failed-reload recovery, and four-target receipts | [Phase 67](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-67) |
| Monorepo support | Yes: workspaces with globs and exclusions, workspace: and catalog: protocols, live symlink workspace packages, filtered install and topological concurrent script waves with --concurrency, and four-target monorepo receipts | [Phase 60](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-60) |
| Frontend development server | Yes: HTML entry imports, on-demand JS/TS/JSX/CSS transforms, pure-CL browser HMR WebSocket client, development mode object, path isolation, Clun.devServer introspection, and four-target receipts | [Phase 68](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-68) |
| Formatter and linter | Yes: pure-CL `clun fmt`/`clun lint` and `Clun.format`/`Clun.lint`: JS/TS/JSX/JSON/YAML/CSS formatting with check/write/stdin/ignore; versioned recommended lint ruleset with stylish+JSON reporters and safe fixes; exceeds Bun which has no first-party fmt/lint | Phases [69](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-69), [70](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-70) |
| Password and hashing APIs | Yes: `Clun.password` and `Clun.hash` sync/async APIs | [Phase 36](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-36) |
| String width API | Yes: `Clun.stringWidth` with Unicode 17 and ANSI handling | [Phase 33](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-33) |
| Glob API | Yes: `Clun.Glob` matcher with sync and async scans | [Phase 30](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-30) |
| Semver API | Yes: `Clun.semver` satisfies and order | [Phase 29](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-29) |
| CSS color conversion | Yes: `Clun.color` with CSS Color and ANSI output | [Phase 34](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-34) |
| CSRF API | Yes: `Clun.CSRF` generate and verify | [Phase 35](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-35) |
<!-- clun-generated:compatibility:end -->

### Beyond the 30-row matrix

Bun exposes additional public APIs outside its homepage matrix. Clun may ship pure-CL implementations
here **without** inventing a 31st `features.tsv` row or forging a matrix Yes:

- **Shipped (Issue [#135](https://github.com/theesfeld/clun/issues/135), Phase 75 slice):**
  `Clun.markdown.html` / `render` / `ansi` (GFM-oriented; `react` fail-closed) and global
  `HTMLRewriter` (`on` / `onDocument` / `transform`). Not a ledger Yes — no feature ID exists.
- **Still planned gates (not claims):** [73 inventory freeze](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-73),
[74 archive/compression](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-74),
[75 remaining formats (TOML/JSON5/JSONL) and full streaming rewriter](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-75),
[76 Cron and REPL](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-76),
[77 transpiler/build APIs](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-77),
[78 image processing](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-78),
[79 WebView checkpoint](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-79),
[80 zero-unowned surface closure](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-80),
[81 performance recheck](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-81), and
[82 final audit/release](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-82).

`scripts/roadmap.sh check` validates the phase ledger and public phase references.
`scripts/public-claims-check.sh` also compares capability names, status values, and complete phase-link
sets between this README and the landing page; descriptive prose still requires review. Use
`scripts/roadmap.sh sync` for a deliberate live-issue reconciliation before pushing. Publication
workflows are read-only and fail closed if the canonical issues, README, or site have drifted.

<!-- clun-generated:release-summary:begin -->
Candidate `0.2.1` is unpublished; installable boundary remains `v0.2.0`.
Tracking: [issue #320](https://github.com/theesfeld/clun/issues/320).
<!-- clun-generated:release-summary:end -->

## The purity contract

- **Allowed:** ANSI Common Lisp, SBCL contribs, and third-party libraries written entirely in CL
  (vendored + pinned under `vendor/`).
- **Forbidden:** CFFI or any foreign library; any JavaScript as part of the *implementation* (JS/TS
  appears only as test fixtures). No shelling out to system tools as an implementation crutch.
- **Enforced:** `make purity` scans every source under `src/` and `vendor/` for foreign-code entry
  points and fails on any hit. It runs at every phase gate.

## TLS / HTTPS security posture

**Treat HTTPS as experimental.** Clun's TLS stack — the vendored **pure-tls** (TLS 1.3) and
**ironclad** libraries, both pure Common Lisp — is **unaudited**, young, and not hardened against
side-channel adversaries. Do not rely on it where a compromise would be serious.

Clun HTTPS uses an authenticated, deliberately bounded pure-Common-Lisp WebPKI profile in both TLS
1.3 and TLS 1.2: DNS identities must appear as `dNSName` SANs (Common Name fallback is disabled), IP
literals must exactly match an `iPAddress` SAN, RSA server keys must be 2048–8192 bits, and a peer may
supply at most eight leaf-first certificates. The verifier authenticates that ordered path to one
configured trust anchor (including an exact subject/public-key match for a cross-signed root); it does
not fetch AIA issuers or search alternate paths. Non-anchor issuing-CA EKU,
BasicConstraints, path length, KeyUsage, signatures, validity, hostname/IP identity, and
critical-extension handling are enforced. Unsupported path semantics fail closed: until cumulative
permitted/excluded subtree processing exists, **every** path containing `nameConstraints` is rejected,
whether the extension is critical or not.

Certificate parsing is bounded before trust decisions: each DER object/certificate list is limited to
one MiB, DER nesting to 32 levels and 4,096 nodes, TLS 1.3 CertificateEntry extensions to 16, and peer
paths to eight certificates. Certificate, TBSCertificate, Name/RDN, Extension, validity-time,
AlgorithmIdentifier, SubjectPublicKeyInfo, RSA, and ECDSA shapes are consumed exactly; trailing,
ambiguous, out-of-range, or mismatched encodings fail closed. RDN `SET OF` values require canonical
DER order, EC coordinates must be canonical field elements on their named curve, and unsupported SAN
GeneralName choices reject. RSA-PSS salt lengths are bounded globally and by the actual issuer
key/hash capacity, certificate-declared lengths are enforced exactly, and TLS CertificateVerify uses
the protocol-required salt length equal to the selected hash output length.

This is not browser-grade or complete RFC 5280 validation: Clun does not implement policy-tree
processing, AIA/alternate-path building, Certificate Transparency, or online revocation checking in
its HTTPS clients. DNS resolution is blocking and each in-flight HTTPS request uses one worker thread.
Public npm metadata and tarball downloads are live-smoked through the bounded TLS 1.3-to-1.2 profile:
both `clun install <package>` and `clun add <package>` install and execute a pinned package with a
transitive dependency, then reproduce byte-identical frozen installs with registry transport denied.
Package tarballs are additionally checked against SRI SHA-512 before extraction. For frozen
reinstalls, the lockfile's already-recorded integrity detects cache corruption or tampering. During
fresh resolution, however, integrity and tarball URLs both come from registry metadata authenticated
by TLS; SRI alone does not protect against a transport compromise that can replace both metadata and
tarball.

Within that bounded profile, local TLS 1.2 protocol/authentication failures and TLS 1.3
certificate failures emit at most one standard fatal alert; a peer fatal is preserved without a
response alert, and a valid peer `close_notify` receives exactly one reciprocal `close_notify`.
Deterministic byte-level fixtures run through `make test-tls-alerts`, which is required by the
full CI, Compatibility, and Release TLS gate. Issue #234's bounded WebPKI work and Issue #235's alert
and closure lifecycle are both implemented in this candidate. This is not a claim of full BoringSSL,
browser TLS, or complete RFC 5280 parity.

## Building from source

Requirements: **SBCL 2.6.4** and **GNU Make** on `PATH`. No quicklisp; all CL dependencies are
vendored under `vendor/` and located via `scripts/registry.lisp`.

```sh
make build     # compile everything, save build/clun (save-lisp-and-die)
make test      # run the CL suites and JS/TS fixture harnesses
make purity    # fail on any CFFI/foreign-code token
./build/clun --version   # => clun 0.2.1
```

A fresh clone builds with `make build` alone: ASDF compiles the vendored closure and `src/` into
its per-user fasl cache automatically; nothing else is fetched.

## Layout

See `PLAN.md §3.7` for the full repository map. Top level: `src/` (runtime), `vendor/` (pinned
pure-CL deps), `tests/` (parachute suites, test262 conformance, JS fixtures), `scripts/` (build
tooling), `docs/design/` (per-phase design notes).

## License

GPL-3.0-or-later (`LICENSE` and `COPYING`). Vendored libraries retain their own licenses; see
`DECISIONS.md` for pins.
