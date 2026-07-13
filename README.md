# Clun

**Bun, rewritten in pure Common Lisp.** Clun is a sharply scoped, faithful-in-spirit
JavaScript/TypeScript runtime and toolkit — including a from-scratch ECMAScript engine —
implemented in **pure Common Lisp** with zero CFFI and zero foreign libraries. Correctness of the
scoped surface and purity of the implementation are the point; breadth and raw speed are not.

> **Status: pre-alpha, under active construction.** This is Phase 00 scaffolding. The runtime does
> not execute JavaScript yet. See `PLAN.md` for the full build plan and `STATE.md` for live progress.

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

MIT (`LICENSE`). Vendored libraries retain their own licenses; see `DECISIONS.md` for pins.
