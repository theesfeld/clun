# Clun

**Bun, rewritten in pure Common Lisp.** Clun is a JavaScript/TypeScript runtime and toolkit —
including a from-scratch ECMAScript engine — implemented in **pure Common Lisp** with zero CFFI
and zero foreign libraries. v0.1 prioritizes correctness and purity while FULL PORT targets complete capability over
breadth. The active prerelease roadmap targets evidence-backed parity with Bun's purity-compatible
surface, one gated capability at a time, before a final re-baselined hardening phase. Performance
targets are workload-specific and published;
Clun does not claim blanket speed parity with Bun.

<!-- clun-generated:release:begin -->
> **Status: pre-alpha, under active construction.** [Phase 39](https://github.com/theesfeld/clun/issues/13) is in progress.
> Its release-bearing target is `0.1.0-dev.59` / `v0.1.0-dev.59` (SemVer impact: `minor`).
> The verified release boundary is `v0.1.0-dev.21`, with four native archives, checksums, Pages,
> and hosted-installer evidence.
> Phase 26 remains deferred until after Phase 82 and will
> be rewritten for the repository state that exists then.
> Clun is a pure Common Lisp full-port runtime: every ledger row is a Yes target that must meet or exceed Bun/npm/Node/Deno. Partial is temporary honesty, never a destination.
> The canonical issue is the live source of truth; `PLAN.md` is the technical contract and `STATE.md` is
> the local resume checklist.
<!-- clun-generated:release:end -->

Source stages `runtime.loader-plugins` No→Yes under Issue
[#187](https://github.com/theesfeld/clun/issues/187) / Phase 41 as `0.1.0-dev.50`
Source stages `cloud.s3` No→Yes under Issue
[#185](https://github.com/theesfeld/clun/issues/185) / Phase 53 as `0.1.0-dev.50`
(parent FULL PORT epic [#177](https://github.com/theesfeld/clun/issues/177)).
Published [`v0.1.0-dev.21`](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.21) remains the
verified release boundary. The hosted installer correctly remains on published dev.21 until the
candidate is merged, tagged, and released.

## Install

Tagged releases are installed by the same POSIX shell command on Linux and macOS:

```sh
curl -fsSL https://clun.sh/install | sh
```

The installer detects x86-64 or arm64, verifies the release SHA-256 checksum, and installs under
`~/.clun`. The release workflow builds and tests native archives on Ubuntu and macOS 15 runners for
both architectures. macOS archives target macOS 13.0 or newer, but are runtime-tested on macOS 15.
Windows is not supported.

Clun is still pre-alpha. In particular, `clun install` is verified against the hermetic registry
fixture, but the default public npm registry currently hits a TLS `protocol_version`
interoperability gap.

## What works

- JavaScript, JSON, ESM, CommonJS, TypeScript (erasable strip, enums/namespaces/param-props,
  experimental decorators, import=/export=, angle-bracket casts, `.tsx`, and `clun tsc`
  structural typecheck — Phase 39 / #192), and JSX/TSX execution via pure Common Lisp transform
  (classic and automatic runtimes; Phase 40 / #186).
- Object integrity and legacy accessor operations including `Object.seal`, `Object.isSealed`,
  `__defineGetter__`, `__defineSetter__`, `__lookupGetter__`, and `__lookupSetter__`. Proxy remains
  unsupported.
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
- Timers, promises, files, buffered HTTP serving, `fetch`, URL APIs, and process spawning.
- `clun test` with hooks, filters, async tests, timeouts, 33 core matchers, function mocks/spies,
  expected-failure modifiers, array-parameterized tests and suites, retries, and repeats.
- `clun install`, `add`, `remove`, and package scripts with a deterministic lockfile and cache.

The checked-in curated test262 pass list contains 25,944 tests. The current
40,654-row off-mode execution ledger measures 25,944 passes and 2,219 gaps across 28,163 eligible tests
(92.12%), with 12,491 skips and zero crashes. Phase 25b's 90% target is met: the 25,347-pass target has
zero remaining lift. The pass list gained 893 tests from milestone 5 and 3,301 from the Phase 25b entry.
Its focused m6 slice contains 509 tests: 407 pass and 102 fail, with zero skips, timeouts, and crashes.
All 407 milestone-owned rows pass; the 102 deliberate controls remain assigned to m11 (7) and Phase 37
(95), leaving m6 with no owned residual. Three additional `Promise.prototype.finally` rows passed
incidentally: `species-constructor.js`, `subclass-reject-count.js`, and `subclass-resolve-count.js`.
Phase 32's supporting Proxy infrastructure adds 13 newly frozen passes without making a blanket Proxy
compatibility claim. Phase 37 milestone 1 adds 173 more frozen passes without claiming complete modern
ECMAScript parity. The full gap inventory assigns 1,767 residuals to Phase 25b and 452 to Phase 37.
The canonical execution ledger digest is `8FCFC569AA653BF1`.
The off/eager ledgers are byte-identical; eager mode compiled
1,030,545 forms, classified 56,018 as ineligible, fell back zero times, and executed zero interpreter
fallbacks. The parse gate classifies
23,713 tests as 17,699 pass, 976 fail, 5,038 skip, and zero crash
while retaining all 17,512 frozen passes.
The Common Lisp suite passes 3,260 tests with zero failures and zero skips.
Phase 25's final
default-tier measurements are 6.68x Richards, 3.85x DeltaBlue, and 5.36x Splay against the frozen
Phase-24 Clun baseline, a 5.16x suite geomean. Clun has no measured cross-runtime benchmark against
Bun or Node.js; `docs/benchmarks.md` reports only reproducible Clun-versus-Clun measurements.

## Compatibility roadmap

<!-- clun-generated:compatibility:begin -->
The current column describes pre-alpha behavior as tested today. A linked phase is a planned acceptance
gate, not a claim that the capability already exists. Every row below is generated from the canonical
compatibility ledger; `make docs-check` rejects hand-edited status, evidence, owner, or baseline drift.

The public comparison snapshot uses Bun 1.3.14, Node.js 26.5.0, and Deno 2.9.3, checked
July 16, 2026. Engineering references are separately pinned to Bun commit `c1076ce95e` (`1.4.0-dev`).

| Capability | Current pre-alpha state | Evidence-backed target |
|---|---|---|
| Node.js compatibility | Partial: selected pure-CL modules (path/fs/url/buffer/events/assert/util/timers/querystring/os/process/crypto helpers) | Phases [42](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-42), [43](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-43), [44](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-44), [45](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-45), [46](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-46), [47](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-47) |
| Web Standard APIs | Partial: streaming fetch, clone/tee, timeouts, HTTP/HTTPS proxy and pooling, ReadableStream/WritableStream/TransformStream, Response/Request.body streams; remaining Web surface (full Streams edge cases, broader standards globals, residual network stress) full-port in progress | [Phase 38](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-38) |
| Native addons | No: not yet implemented (full-port target) | [Phase 48](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-48) |
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
| Encrypted secrets storage | Yes: `Clun.secrets` pure-CL AES-256-GCM encrypted vault (get/set/delete by service+name); Bun.secrets-compatible surface | [Phase 58](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-58) |
| npm package management | Yes: `clun install`/`add`/`remove` with registry packages (semver ranges, dist-tags), npm: aliases, file:/link: local packages, optionalDependencies soft-fail, hoisted node_modules, clun.lock offline reinstall, SRI-verified tarballs, and four-target hermetic install receipts | Phases [28](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-28), [59](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-59), [60](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-60), [61](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-61) |
| Bundler | Yes: Clun.build and clun build pure-CL production bundler: entrypoints, dependency graph, ESM/CJS/IIFE formats, code splitting, minification, loaders (js/ts/tsx/jsx/json/text/file/dataurl/css/html), define, external, packages external or bundle, naming templates, banner/footer, metafile, sourcemaps, target, publicPath, env inlining, drop, features, virtual files, tree shaking, asset hashing, Clun.build.analyze and Clun.buildSync exceed surface, four-target receipts | Phases [62](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-62), [63](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-63), [64](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-64), [77](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-77) |
| Cross-platform shell API | Yes: `Clun.$`, `clun exec`, standalone `.bun.sh` files with positional parameters, dollar and backtick command substitution, background jobs and wait, merged stdout/stderr pipelines, grouped subshells and brace groups nested across `if` control flow, Blob/Response I/O, positive extended-glob conditions, compound-word field splitting, 100-level arrays, Unicode, tilde and continuation expansion, builtins, and 1,598/1,630 pinned shell sites (32 upstream-inactive) | [Phase 65](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-65) |
| Jest-compatible test runner | Yes: 62 core and extended matchers, snapshot lifecycles with stable property tokens and Bun-formatted core values including own-accessor Getter tokens and control-byte escapes, source-aligned ESM/CommonJS/TypeScript statement and function coverage with Bun-shaped text and LCOV reporters, filters, config, and thresholds, custom and Promise-settlement asymmetric matchers, per-realm ESM/CJS module mocks, CLI and bunfig setup preloads, realm-local Jest and vi fake timers with Date and performance clock control, seeded Bun-pinned randomization, deterministic file sharding, dots and JUnit reporters, function mocks/spies, callbacks, cleanup, parameterization, retries, repeats, cooperative test.concurrent / describe.concurrent / test.serial scheduling with --concurrent and --max-concurrency, pure-CL --parallel multi-file process pools with serial/parallel count agreement, expect.unreachable, and runtime expectTypeOf | [Phase 66](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-66) |
| Hot reloading | Yes: clun --hot state-preserving server reload with connection retention, pure-CL stat-poll watcher, module-graph soft re-evaluation, import.meta.hot dispose/accept/data, Clun.hot introspection, --watch hard restart, failed-reload recovery, and four-target receipts | [Phase 67](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-67) |
| Monorepo support | Yes: workspaces with globs and exclusions, workspace: and catalog: protocols, live symlink workspace packages, filtered install and topological concurrent script waves with --concurrency, and four-target monorepo receipts | [Phase 60](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-60) |
| Frontend development server | Yes: HTML entry imports, on-demand JS/TS/JSX/CSS transforms, pure-CL browser HMR WebSocket client, development mode object, path isolation, Clun.devServer introspection, and four-target receipts | [Phase 68](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-68) |
| Formatter and linter | No: not yet implemented (full-port target) | Phases [69](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-69), [70](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-70) |
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
Release versions follow the actual SemVer impact recorded in the canonical issue, not the number of pushes.
The current source is the `0.1.0-dev.59` release candidate; the immutable tag and assets are not published yet.
The last published prerelease remains [`v0.1.0-dev.21`](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.21).
[The versioning contract](docs/versioning.md) defines prerelease sequencing, synchronized surfaces, immutable tags, assets, and installer evidence.
[Phase 39 issue #13](https://github.com/theesfeld/clun/issues/13) is the canonical live release record.
<!-- clun-generated:release-summary:end -->

## The purity contract

- **Allowed:** ANSI Common Lisp, SBCL contribs, and third-party libraries written entirely in CL
  (vendored + pinned under `vendor/`).
- **Forbidden:** CFFI or any foreign library; any JavaScript as part of the *implementation* (JS/TS
  appears only as test fixtures). No shelling out to system tools as an implementation crutch.
- **Enforced:** `make purity` scans every source under `src/` and `vendor/` for foreign-code entry
./build/clun --version   # => clun 0.1.0-dev.59
./build/clun --version   # => clun 0.1.0-dev.55
./build/clun --version   # => clun 0.1.0-dev.53
./build/clun --version   # => clun 0.1.0-dev.54
  points and fails on any hit. It runs at every phase gate.

## TLS / HTTPS security posture

**Treat HTTPS as experimental.** Clun's TLS stack — the vendored **pure-tls** (TLS 1.3) and
**ironclad** libraries, both pure Common Lisp — is **unaudited**, young, and not hardened against
side-channel adversaries. Do not rely on it where a compromise would be serious.

What Clun does guarantee: HTTPS **fails closed**. A connection is rejected with a distinct, catchable
error whenever the server's certificate is expired, is for the wrong host, is self-signed, chains to
an untrusted root, or is simply not presented — and there is no "ignore certificate errors" switch.
Clun explicitly rejects a missing peer certificate when verification is required, closing the
pure-tls verification gap recorded in `DECISIONS.md`. Trust anchors resolve from `$SSL_CERT_FILE` /
`$SSL_CERT_DIR`, else the system CA bundle; if none is found, verification rejects rather than
trusting nothing.

Known limitations (see `STATE.md`): pure-tls does not yet interoperate with every server frontend
(e.g. `registry.npmjs.org` currently returns a `protocol_version` alert); DNS resolution is blocking;
each in-flight HTTPS request uses one worker thread. Package tarballs are additionally protected by
SRI SHA-512 verification before extraction, so a TLS compromise cannot by itself corrupt an install.

## Building from source

Requirements: **SBCL 2.6.4** and **GNU Make** on `PATH`. No quicklisp; all CL dependencies are
vendored under `vendor/` and located via `scripts/registry.lisp`.

```sh
make build     # compile everything, save build/clun (save-lisp-and-die)
make test      # run the CL suites and JS/TS fixture harnesses
make purity    # fail on any CFFI/foreign-code token
./build/clun --version   # => clun 0.1.0-dev.52
./build/clun --version   # => clun 0.1.0-dev.51
./build/clun --version   # => clun 0.1.0-dev.50
./build/clun --version   # => clun 0.1.0-dev.53
./build/clun --version   # => clun 0.1.0-dev.54
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
