# Clun

**Bun, rewritten in pure Common Lisp.** Clun is a JavaScript/TypeScript runtime and toolkit —
including a from-scratch ECMAScript engine — implemented in **pure Common Lisp** with zero CFFI
and zero foreign libraries. v0.1 is deliberately scoped: correctness and purity take priority over
breadth. After v0.1, the roadmap targets evidence-backed parity with Bun's purity-compatible
surface, one gated capability at a time. Performance targets are workload-specific and published;
Clun does not claim blanket speed parity with Bun.

> **Status: pre-alpha, under active construction.** Phase 25 performance work is complete;
> Phase 25b, the curated-test262 conformance push, is next and has not started.
> Clun executes its scoped JS/TS surface, but it is not a drop-in Node.js or Bun replacement.
> See `PLAN.md` for the compatibility matrix and `STATE.md` for live progress.

## Install

Tagged releases are installed by the same POSIX shell command on Linux and macOS:

```sh
curl -fsSL https://clun.sh/install | sh
```

The installer detects x86-64 or arm64, verifies the release SHA-256 checksum, and installs under
`~/.clun`. The release workflow builds and tests native archives on Linux and macOS 13+ for both
architectures. Windows is not supported.

Clun is still pre-alpha. In particular, `clun install` is verified against the hermetic registry
fixture, but the default public npm registry currently hits a TLS `protocol_version`
interoperability gap.

## What works

- JavaScript, JSON, ESM, CommonJS, and erasable TypeScript execution (`.tsx` is not supported in
  v0.1; JSX/TSX is planned for Phase 40).
- Timers, promises, files, buffered HTTP serving, `fetch`, URL APIs, and process spawning.
- `clun test` with hooks, modifiers, filters, async tests, timeouts, and about 22 matchers.
- `clun install`, `add`, `remove`, and package scripts with a deterministic lockfile and cache.

The checked-in curated test262 pass list contains 22,643 tests. Phase 25's final default-tier
measurements are 6.68x Richards, 3.85x DeltaBlue, and 5.36x Splay against the frozen Phase-24
Clun baseline, a 5.16x suite geomean. Clun has no measured cross-runtime benchmark against Bun or
Node.js; `docs/benchmarks.md` reports only reproducible Clun-versus-Clun measurements.

## Compatibility roadmap

The current column describes pre-alpha behavior as tested today. A linked phase is a planned acceptance
gate, not a claim that the capability already exists. A roadmap item becomes complete only with its
specified conformance, stress, platform, and benchmark evidence; `PLAN.md` is the authoritative
gate definition.

The landing-page comparison uses the stable Bun 1.3.14 release. The engineering roadmap separately
audits Bun source commit `c1076ce95e` (`1.4.0-dev`) so newer upstream work is not missed.

| Capability | Current pre-alpha state | Evidence-backed target |
|---|---|---|
| Node.js compatibility | Partial: selected globals and module subsets | Phases [42](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-42), [43](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-43), [44](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-44), [45](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-45), [46](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-46), [47](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-47) |
| Web Standard APIs | Partial: buffered fetch and a scoped Web API surface | [Phase 38](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-38) |
| Native addons | No: excluded by the current purity contract | [Phase 48 architecture gate](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-48) |
| TypeScript | Partial: erasable syntax stripping only | [Phase 39](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-39) |
| JSX | No: outside the v0.1 scope | [Phase 40](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-40) |
| Module loader plugins | No: fixed loader surface | [Phase 41](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-41) |
| SQL database drivers | No | Phases [55](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-55), [56](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-56), [57](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-57) |
| S3 cloud storage | No | [Phase 53](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-53) |
| Redis client | No | [Phase 54](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-54) |
| WebSocket server | No: no WebSocket implementation | [Phase 51](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-51) |
| HTTP server | Partial: HTTP/1.1 with buffered bodies | [Phase 49](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-49) |
| HTTP router | No: routing belongs in the handler | [Phase 50](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-50) |
| Single-file executables | No: Clun ships a runtime executable | Phases [52](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-52), [77](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-77) |
| YAML | No | [Phase 31](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-31) |
| Cookies API | No | [Phase 32](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-32) |
| Encrypted secrets storage | No | [Phase 58 architecture gate](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-58) |
| npm package management | Partial: fixture-tested; public npm is blocked by TLS interop | Phases [28](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-28), [59](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-59), [60](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-60), [61](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-61) |
| Bundler | No: outside the v0.1 scope | Phases [62](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-62), [63](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-63), [64](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-64), [77](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-77) |
| Cross-platform shell API | No: spawn and package scripts only | [Phase 65](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-65) |
| Jest-compatible test runner | Partial: 22 matchers; no snapshots, coverage, mocks, or concurrency | [Phase 66](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-66) |
| Hot reloading | No | [Phase 67](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-67) |
| Monorepo support | No: workspaces are unsupported | [Phase 60](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-60) |
| Frontend development server | No | [Phase 68](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-68) |
| Formatter and linter | No | Phases [69](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-69), [70](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-70) |
| Password and hashing APIs | No: randomness APIs only | [Phase 36](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-36) |
| String width API | No | [Phase 33](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-33) |
| Glob API | No | [Phase 30](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-30) |
| Semver API | No: installer-internal only | [Phase 29](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-29) |
| CSS color conversion | No | [Phase 34](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-34) |
| CSRF API | No | [Phase 35](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-35) |

### Beyond the 30-row matrix

Bun exposes additional public APIs outside its homepage matrix. These links are planned gates, not
current Clun capabilities: [73 inventory freeze](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-73),
[74 archive/compression](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-74),
[75 data/document formats, Markdown, and HTMLRewriter](https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-75),
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
`scripts/roadmap.sh sync` after changing roadmap metadata.

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

What Clun does guarantee: HTTPS **fails closed**. A connection is rejected with a distinct, catchable
error whenever the server's certificate is expired, is for the wrong host, is self-signed, chains to
an untrusted root, or is simply not presented — and there is no "ignore certificate errors" switch.
(pure-tls's own verify step skips when no peer certificate is recorded; Clun patches it so that
`verify-required` with a missing certificate rejects rather than silently accepting — see
`DECISIONS.md`.) Trust anchors resolve from `$SSL_CERT_FILE` / `$SSL_CERT_DIR`, else the system CA
bundle; if none is found, verification rejects rather than trusting nothing.

Known limitations (see `STATE.md`): pure-tls does not yet interoperate with every server frontend
(e.g. `registry.npmjs.org` currently returns a `protocol_version` alert); DNS resolution is blocking;
each in-flight HTTPS request uses one worker thread. When package installation lands, tarball
integrity is additionally enforced by SRI sha512 verification of every downloaded tarball, so a TLS
compromise cannot by itself corrupt an install.

## Building from source

Requirements: **SBCL 2.6.4** and **GNU Make** on `PATH`. No quicklisp; all CL dependencies are
vendored under `vendor/` and located via `scripts/registry.lisp`.

```sh
make build     # compile everything, save build/clun (save-lisp-and-die)
make test      # run the parachute CL suites
make purity    # fail on any CFFI/foreign-code token
./build/clun --version   # => clun 0.0.1-dev
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
