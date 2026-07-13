# Phase 19 — Crypto foundation: ironclad KATs + pure-tls vendoring

**Objective (PLAN §5/§3.4):** get the pure-CL crypto/TLS stack in-tree and proven. Vendor
**ironclad** (all primitives) and **pure-tls** (TLS 1.3 + X.509 + trust store) plus their dep
closure, all pinned; patch the one CFFI leak (`precise-time`), strip win/mac CFFI and non-SBCL
paths so `make purity` stays green; prove ironclad with known-answer tests and run pure-tls's own
crypto/record/handshake/certificate suites in our CI.

**Gate:** all KATs pass; pure-tls suites pass; `make purity` green over the full closure.
(Phase 20 = HTTPS, consumes this. Phase 19 is ◇ independent: no engine dependency.)

## 1. Vendoring manifest (pinned SHAs recorded in DECISIONS.md)

Cloned shallow, `.git` stripped, registered by the existing `scripts/registry.lisp` `vendor/*/`
scan (each has its `.asd` at its root). Purity audited per-tree with the forbidden-token scan.

| Library | SHA (short) | Purpose | Purity |
|---|---|---|---|
| ironclad | f6519450 | all crypto primitives | clean (129 files, 0 tokens; SBCL VOPs) |
| alexandria | f283e25 | utilities (many deps) | clean |
| bordeaux-threads | 92da6b9 | threads (ironclad, pure-tls, cl-cancel) | clean (sb-thread on SBCL) |
| global-vars | c749f32 | bordeaux-threads dep | clean |
| trivial-features | 18a5cfa | `*features*` normalizer | **patch** tf-sbcl endianness; strip tests |
| trivial-gray-streams | fd5fed1 | gray-stream shims | clean |
| flexi-streams | 4951d57 | in-memory octet streams | clean |
| cl-base64 | (pin) | SRI / DER base64 | clean |
| split-sequence | 89a10b4 | usocket/pure-tls util | clean |
| idna | bf789e6 | punycode for hostnames | clean |
| usocket | d492f74 | sockets (pure-tls crl.lisp only) | **patch** wait-for-input; strip win32 block + tests |
| atomics | bf0e261 | cl-cancel dep | clean |
| precise-time | e0bf77d | cl-cancel dep (timing) | **patch** — drop CFFI, SBCL clock-gettime |
| cl-cancel | (pin) | pure-tls cancellation/deadlines | clean (deps patched) |
| pure-tls | ebfb60f0 | TLS 1.3 + X.509 + trust store | **patch** .asd (strip win/mac `:feature cffi`) |

Not re-vendored (already present from earlier phases): chipz, cl-ppcre, parachute + its closure
(documentation-utils, form-fiddle, trivial-custom-debugger, trivial-indent). `documentation-utils`
is also precise-time's dep — one copy.

## 2. The three purity patches (the only edits to vendored code)

Each is minimal, documented in-file with a `;; clun purity patch (Phase 19):` comment, and logged
in DECISIONS.md. The upstream `precise-time` CFFI issue is filed (note in DECISIONS.md).

1. **precise-time** — its `.asd` pulls `(:feature (:not :mezzano) :cffi)` and loads `posix.lisp`,
   which calls `cffi:foreign-funcall "clock_gettime"`. Replace `posix.lisp` with a pure SBCL
   implementation using `sb-unix:clock-gettime` (verified available: returns integer secs+nsecs
   for `sb-unix:clock-realtime`/`clock-monotonic`), and drop the CFFI dep + the win/mac/nx platform
   files from the `.asd`. `protocol.lisp` already provides `get-internal-real-time` fallbacks, so
   even the pure override is belt-and-suspenders. Nanosecond precision preserved.

2. **trivial-features/src/tf-sbcl.lisp** — replaces an `sb-alien` endianness probe (write `#xfeff`,
   read a byte) with a reader conditional: SBCL already publishes `:little-endian`/`:big-endian` in
   `*features*` (verified), so `#+little-endian (pushnew :little-endian *features*)` etc. is exact
   and pure. Strip `trivial-features-tests.asd` + `tests/` (a test carries `cffi`).

3. **usocket/backend/sbcl.lisp** — the non-win32 `get-host-name` is already pure
   (`sb-unix:unix-gethostname`); the only Linux `sb-alien` is `wait-for-input-internal`'s
   `fd-set` + `unix-fast-select`. Replace it with `sb-sys:wait-until-fd-usable` (the pure
   serve-event primitive; per-socket loop — usocket is used ONLY by pure-tls's `x509/crl.lisp`,
   i.e. single-socket CRL fetch, so this suffices; multi-socket precision is a documented
   divergence). Delete the dead `#+win32` block (never compiled on Linux, but the token scanner
   reads it) and the `sb-alien` mention in a comment. Strip usocket's test files carrying tokens.

pure-tls's own `.asd` lists `(:feature :windows "cffi")` / `(:feature (:or :darwin :macos) "cffi")`
— never loaded on Linux, but the literal string trips the scanner: strip those two lines from the
vendored `.asd` (Windows/macOS are non-goals).

## 3. KAT suites (tests/lisp/crypto/kat-tests.lisp)

Parachute suites asserting ironclad against published vectors (each vector's RFC/FIPS line cited):
- **SHA-256 / SHA-512** — NIST FIPS 180-4 example digests ("abc", empty, the 896-bit message).
- **HMAC-SHA256** — RFC 4231 test cases 1–4.
- **HKDF-SHA256** — RFC 5869 test cases 1–3 (extract+expand, incl. zero-length salt/info).
- **AES-128/256-GCM** — NIST GCM test vectors (a representative subset: ct + tag + AAD).
- **x25519** — RFC 7748 §6.1 (the two scalar-mult test vectors + the alice/bob shared secret).
- **ChaCha20-Poly1305 AEAD** — RFC 8439 §2.8.2 (the canonical seal, with AAD, ct + tag).

These validate ironclad end-to-end (the primitives pure-tls composes). `crypto.getRandomValues`/
`randomUUID` stay on the existing `/dev/urandom` path (ironclad's os-prng is also pure — a follow-up
may route through it, not gate-blocking).

## 4. pure-tls's own suites

pure-tls ships parachute/fiveam suites for crypto (ChaCha20-Poly1305, HKDF), record layer,
handshake, and certificate/X.509 validation (RFC 8448 traces + interop). We load `pure-tls/tests`
under the vendored closure and run them via a `make` hook, asserting green. If a suite needs the
CFFI-only cert path (win/mac) it is `:feature`-guarded off on Linux.

## 5. Risks / fallbacks (PLAN §7)

- **pure-tls is young/unaudited (High):** vendored + pinned; its suites in our CI; SRI sha512 is
  the independent integrity check (Phase 22); fail-closed certs; posture labeling in README
  (Phase 20/26). MIT permits the maintained fork.
- **Dep version conflicts under ASDF:** all deps pinned + vendored; no quicklisp. If a transitive
  version mismatch surfaces, pin the compatible SHA and log it.
- **usocket wait-for-input divergence:** single-socket only exercised (CRL); documented.
- **If pure-tls cannot be made to load/pass purely within the spike:** milestone 1 (ironclad +
  KATs, self-contained, half the gate) commits independently; pure-tls status recorded in STATE.md
  under Blocked, and Phase 20 (its only dependent) waits — the rest of the plan is unblocked.
