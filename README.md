# Clun

**JavaScript and TypeScript toolkit. Implementation is Common Lisp.**

Clun runs TypeScript. Clun installs npm packages. Clun runs tests. Clun serves HTTP. Clun builds bundles.
Commands and APIs follow Bun shape.
The Clun implementation is pure Common Lisp.
The Clun implementation is not Node, V8, libuv, Rust, Zig, or C.
JavaScript is only what **you** run.
Clun is pre-1.0. Do not claim speed parity with Bun. Publish only measured performance data.

<!-- clun-generated:release:begin -->
> **Status: stable release train.** Published release: `0.2.1` / `v0.2.1` (SemVer impact: `patch`).
> Tracking: [issue #58](https://github.com/theesfeld/clun/issues/58).
> The verified release boundary is `v0.2.1`, with four native archives and checksums.
> Capability matrix: 30 Yes / 0 Partial / 0 No.
<!-- clun-generated:release:end -->

Published [`v0.2.1`](https://github.com/theesfeld/clun/releases/tag/v0.2.1) is the verified installable boundary (four native archives, `checksums.txt`, install to `~/.local/bin`, built-in updater, packaged `man clun` matching live CLI).
Tracking: [issue #58](https://github.com/theesfeld/clun/issues/58) (Phase 26 patch `0.2.1`: man page packaging, ElonOptimizer surfaces, STE100 product copy).
Phase 82 ([#56](https://github.com/theesfeld/clun/issues/56)) closed the purity-compatible surface audit.
First stable `0.2.0` remains available; this unit published patch `0.2.1`.

## Install

```sh
curl -fsSL https://clun.sh/install | sh
```

Supported platforms: Linux and macOS on x64 and arm64.
The installer verifies SHA-256. The installer installs `clun` to `~/.local/bin/clun`.
Optional variables: `INSTALL_DIR`, `INSTALL_VERSION` / `CLUN_VERSION`, `ADD_PATH=0|1`.
After install, use `man clun`. The man page must match live CLI help.

The published `v0.2.1` boundary includes the built-in updater (`clun --update` / `clun --check-update`) and packaged man page.

### Update

```sh
clun --check-update   # non-mutating; exit 1 if behind
clun --update         # verify and activate the complete release bundle
```

The updater uses pure Common Lisp HTTPS. The updater uses the same assets as the installer.
Clun is pre-1.0. A minor release may include breaking changes.

## What works

- Run `.js`, `.mjs`, `.cjs`, JSON, TypeScript, JSX, and TSX.
- TypeScript: erasable strip, enums, namespaces, decorators, and `clun tsc` typecheck.
- Node-compatible builtins on the pure Common Lisp matrix (buffer, fs, path, crypto, and more).
- Web APIs: `fetch`, URL, streams, AbortController, cookies, and related surfaces.
- HTTP server (`Clun.serve`), WebSocket, bundler, hot reload, monorepo workspaces.
- `clun test` with matchers, snapshots, async tests, and concurrent files.
- `clun install`, `add`, `remove`, and `publish` against the public npm registry.
- First `add` or `install <pkg>` creates a minimal `package.json` if the directory has none.
- Bare `clun install` requires an existing project manifest.

**test262:** 26,018 frozen passes / 28,163 eligible (92.38%); Phase 25b's 90% target is met.
Engineering detail: [`docs/conformance/test262-execution.md`](docs/conformance/test262-execution.md).
Clun-vs-Clun microbenchmarks only: [`docs/benchmarks.md`](docs/benchmarks.md).

## Compatibility roadmap

<!-- clun-generated:compatibility:begin -->
Each row comes from the capability matrix. `make docs-check` rejects hand-edited status,
evidence, or baseline drift. Status is evidence-backed Yes / Partial / No as tested today.

Snapshot: Bun 1.3.14, Node.js 26.5.0, and Deno 2.9.3 (
July 16, 2026). Engineering pin: Bun `c1076ce95e` (`1.4.0-dev`).

| Capability | Current stable state |
|---|---|
| Node.js compatibility | Yes: pure-CL Bun-comparable node: matrix (54 builtins: assert async_hooks buffer child_process cluster console constants crypto dgram diagnostics_channel dns domain events fs http http2 https inspector module net os path perf_hooks process punycode querystring readline repl sqlite stream string_decoder sys timers tls trace_events tty url util v8 vm wasi worker_threads zlib test); exceeds Bun on sqlite module.register registerHooks createSecurePair repl |
| Web Standard APIs | Yes: `fetch` with streaming clone/tee, operation-wide timeouts, HTTP proxy and HTTPS CONNECT including proxy object `{url,headers}`, plain HTTP and origin-keyed pure-tls HTTPS idle pooling; URL/URLSearchParams; Headers/Request/Response/Blob/File/FormData; AbortController/AbortSignal; Event/EventTarget/CustomEvent/DOMException; TextEncoder/TextDecoder; atob/btoa; performance.now; MessageChannel/MessagePort; crypto.randomUUID/getRandomValues and crypto.subtle.digest; ReadableStream default and BYOB readers, WritableStream, TransformStream with pipeTo/pipeThrough, CountQueuingStrategy/ByteLengthQueuingStrategy; CompressionStream/DecompressionStream (gzip/deflate/deflate-raw); structuredClone; WebSocket client; hermetic large-transfer and network-stress receipts (exceeds Bun pure-CL surface) |
| Native addons | Yes: pure-CL host processes and hooks user native shared libraries (.so/.dylib/.node) via a narrow allowlisted load/call boundary; Bun.ffi-shaped dlopen/linkSymbols/typed call; registered CL libraries, bounds-checked virtual memory, N-API-style registry, and .claddon packs |
| TypeScript | Yes: pure Common Lisp TypeScript execution: erasable strip, enums, namespaces, parameter properties, experimental decorators, import=/export=, angle-bracket casts, .tsx via JSX lower+strip, and structural typecheck CLI (clun tsc) exceeding Bun (Bun has no typecheck) |
| JSX | Yes: pure Common Lisp JSX and TSX parse, transform, and execute with classic React.createElement and automatic jsx/jsxs/Fragment runtimes, file pragmas, tsconfig/jsconfig compilerOptions, fragments, spreads, nested expressions, member tags, HTML entity decoding, and built-in offline helpers that run without a react package (exceeds Bun) |
| Module loader plugins | Yes: pure Common Lisp Bun.plugin-compatible Clun.plugin with ordered onResolve/onLoad/onStart/onEnd, namespaces, virtual builder.module, object/js/json/yaml/text/file loaders, clearAll plus exceed list/clear/priority/registerHooks and pure-CL register-cl-plugin (exceeds Bun.plugin and node:module hooks) |
| SQL database drivers | Yes: `Clun.SQL` pure-CL PostgreSQL+MySQL wire + embedded SQLite engine; Bun.SQL-compatible unified API plus inspect/stats/export/queryLog |
| S3 cloud storage | Yes: `Clun.s3` pure-CL AWS SigV4 S3-compatible client (list/get/put/delete/exists/stat/presign/multipart; credentials; path-style and virtual-hosted) |
| Redis client | Yes: `Clun.redis` pure-CL RESP client with embedded offline Redis store (get/set/del/exists/incr/publish/subscribe); Bun.redis-compatible Promise API; offline Yes without external Redis (exceeds Bun) |
| WebSocket server | Yes: `Clun.serve` WebSocket upgrade, RFC 6455 framing, fragmentation reassembly, Pub/Sub (`publish`/`subscriberCount`/`subscribe`), permessage-deflate (chipz inflate + stored compress), and browser-shaped `WebSocket` client (`ws:`) |
| HTTP server | Yes: HTTP/1.1 Clun.serve with streaming request/response bodies (chunked Transfer-Encoding), keep-alive, idleTimeout, maxRequestBodySize, stop(force) |
| HTTP router | Yes: `Clun.serve({ routes })` and `Clun.FileSystemRouter` |
| Single-file executables | Yes: `clun build --compile` / `Clun.build({compile})` pure-CL single-file executables with cross-target offline templates, embedded assets, Ed25519/HMAC sign+verify on every platform, GPL source notice, reproducible build-id, and CLUN_BE_CLUN CLI mode (exceeds Bun compile) |
| YAML | Yes: `Clun.YAML` parser/stringifier and `.yaml`/`.yml` module loading |
| Cookies API | Yes: `Clun.Cookie` and `Clun.CookieMap` with request/response integration |
| Encrypted secrets storage | Yes: `Clun.secrets` Bun-shaped get/set/delete plus has/list/clear on pure-CL AES-256-GCM encrypted storage (exceeds Bun.secrets API; no Keychain/libsecret FFI) |
| npm package management | Yes: `clun add <pkg>` and Bun-compatible `clun install <pkg>` resolve public npm metadata and tarballs through pure-CL TLS; no-argument install resolves the existing manifest with SRI, clun.lock, node_modules, offline cache, aliases, local packages, optional deps, hoisting, and workspaces; `clun publish` packs a package/ tarball and PUTs an authenticated npm attach-document (NPM_TOKEN / .npmrc _authToken) |
| Bundler | Yes: Clun.build and clun build pure-CL production bundler: entrypoints, dependency graph, ESM/CJS/IIFE formats, code splitting, minification, loaders (js/ts/tsx/jsx/json/text/file/dataurl/css/html), define, external, packages external or bundle, naming templates, banner/footer, metafile, sourcemaps, target, publicPath, env inlining, drop, features, virtual files, tree shaking, asset hashing, Clun.build.analyze and Clun.buildSync exceed surface, four-target receipts |
| Cross-platform shell API | Yes: `Clun.$`, `clun exec`, standalone `.bun.sh` files with positional parameters, dollar and backtick command substitution, background jobs and wait, merged stdout/stderr pipelines, grouped subshells and brace groups nested across `if` control flow, Blob/Response I/O, positive extended-glob conditions, compound-word field splitting, 100-level arrays, Unicode, tilde and continuation expansion, builtins, and 1,598/1,630 pinned shell sites (32 upstream-inactive) |
| Jest-compatible test runner | Yes: 62 core and extended matchers, snapshot lifecycles with stable property tokens and Bun-formatted core values including own-accessor Getter tokens and control-byte escapes, source-aligned ESM/CommonJS/TypeScript statement and function coverage with Bun-shaped text and LCOV reporters, filters, config, and thresholds, custom and Promise-settlement asymmetric matchers, per-realm ESM/CJS module mocks, CLI and bunfig setup preloads, realm-local Jest and vi fake timers with Date and performance clock control, seeded Bun-pinned randomization, deterministic file sharding, dots and JUnit reporters, function mocks/spies, callbacks, cleanup, parameterization, retries, repeats, cooperative test.concurrent / describe.concurrent / test.serial scheduling with --concurrent and --max-concurrency, pure-CL --parallel multi-file process pools with serial/parallel count agreement, expect.unreachable, and runtime expectTypeOf |
| Hot reloading | Yes: clun --hot state-preserving server reload with connection retention, pure-CL stat-poll watcher, module-graph soft re-evaluation, import.meta.hot dispose/accept/data, Clun.hot introspection, --watch hard restart, failed-reload recovery, and four-target receipts |
| Monorepo support | Yes: workspaces with globs and exclusions, workspace: and catalog: protocols, live symlink workspace packages, filtered install and topological concurrent script waves with --concurrency, and four-target monorepo receipts |
| Frontend development server | Yes: HTML entry imports, on-demand JS/TS/JSX/CSS transforms, pure-CL browser HMR WebSocket client, development mode object, path isolation, Clun.devServer introspection, and four-target receipts |
| Formatter and linter | Yes: pure-CL `clun fmt`/`clun lint` and `Clun.format`/`Clun.lint`: JS/TS/JSX/JSON/YAML/CSS formatting with check/write/stdin/ignore; versioned recommended lint ruleset with stylish+JSON reporters and safe fixes; exceeds Bun which has no first-party fmt/lint |
| Password and hashing APIs | Yes: `Clun.password` and `Clun.hash` sync/async APIs |
| String width API | Yes: `Clun.stringWidth` with Unicode 17 and ANSI handling |
| Glob API | Yes: `Clun.Glob` matcher with sync and async scans |
| Semver API | Yes: `Clun.semver` satisfies and order |
| CSS color conversion | Yes: `Clun.color` with CSS Color and ANSI output |
| CSRF API | Yes: `Clun.CSRF` generate and verify |
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
Current source version and latest published release are [`0.2.1`](https://github.com/theesfeld/clun/releases/tag/v0.2.1).
Tracking: [issue #58](https://github.com/theesfeld/clun/issues/58).
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
