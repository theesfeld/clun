# Phase 21 — Semver + registry client + local registry fixture

**Objective (PLAN §5/§3.5):** the install pipeline's front half, hermetic-first. A pure-CL **semver**
conformance-tested against node-semver's own fixtures; a **registry client** that fetches abbreviated
package metadata; and a **local registry fixture** (in-process server + hand-built tarballs) so every
later install test is hermetic. All three are CL-side (no engine dependency), under `src/install/`.

**Gate:** semver fixture corpus at 100% (deviations enumerated); metadata round-trips including
scoped / gzip / 304; the fixture server reusable as a `make` target.

## 1. Semver (`src/install/semver.lisp`, package `clun.install`)

A faithful port of node-semver (pinned in `vendor-data/semver-fixtures/node-semver/CLUN-PIN.txt`, ISC).
- A `version` struct: `major`/`minor`/`patch` (CL bignums — a numeric component > 2^53-1 is rejected as
  "too big", matching node-semver), an ordered `prerelease` list (numbers + strings), a `build` list.
  Parse with a hand-rolled scanner (loose mode accepts a leading `v`/`=`, whitespace, `1.2` short forms).
- Comparison per semver.org §11 (numeric < prerelease; field-by-field; a version with prerelease is
  lower than the same without; prerelease identifiers compared numerically or lexically). Build metadata
  is ignored in comparison + equality.
- Ranges: parse `range` = an OR of comparator sets (ANDs of `<op><version>`). Desugar hyphen `a - b`,
  caret `^`, tilde `~`, x-ranges (`1.x`, `1.*`, `1`), and `*`/`""` per node-semver's `ranges/*.js`.
  `satisfies(version, range)` honours `includePrerelease` (a prerelease only satisfies a comparator whose
  own tuple carries a prerelease, unless includePrerelease). `range-to-string` = the canonical form the
  fixtures expect.
- `inc(version, release, options, identifier, identifierBase)` for major/minor/patch/pre* + prerelease
  identifier bumping. `gtr`/`ltr` (version-outside-range). `intersects` (comparator/range intersection).
- **Conformance** (`tests/lisp/install/semver-tests.lisp`): the node-semver fixtures were converted to
  JSON (`tests/fixtures/semver/*.json`, via Clun's own engine — `clun fixture.cjs` → `JSON.stringify`,
  which also exercised the engine + module system + fs) and are replayed vector-by-vector through the CL
  library. Documented deviation: 3 `invalid-versions` cases whose input is a JS object (`{}`) rather than
  a string — N/A for a CL string API.

## 2. Registry client (`src/install/registry.lisp`)

Fetches **abbreviated** package metadata over the Phase-18 client:
- `Accept: application/vnd.npm.install-v1+json`; the abbreviated document's field set (Appendix C.20):
  `versions{dependencies, optionalDependencies, peerDependencies, bin, dist{tarball, shasum, integrity},
  engines, os, cpu, hasInstallScript, deprecated}`, `dist-tags`, `modified`.
- Scoped names URL-encode `@scope/name` → `@scope%2Fname`. `--registry` override + `.npmrc`-lite
  (`registry=`, `//host/:_authToken=`, `@scope:registry=` — a minimal parser, not full npm config).
- Retries with backoff on transient failures; a 404 → a clean "package not found" error.
- Parses the JSON (via `clun.sys` JSON) into a metadata struct: per-version dist + deps.
- Transport dispatches by scheme: `http` over the Phase-18 reactor client; `https` over the Phase-20
  pure-tls **worker path** (`%https-request-async` → `lp:worker-submit` → `net:https-request`, the same
  path `fetch` uses, verification always fail-closed). The hermetic gate exercises `http` against the
  local fixture; the `https` path is proven in the **fail-closed** direction (an untrusted in-process
  pure-tls server is rejected). A *successful* in-process `https` round-trip is not asserted — the
  pure-tls client↔server self-interop records the peer certificate racily (a Phase-20 finding), so a
  verify-ON round-trip is non-deterministic — and the live `registry.npmjs.org` green path remains gated
  on the pure-tls `protocol_version` interop fix (Phase 23's live smoke). A blocking `fetch-metadata`
  is intentionally not shipped here; the CLI (Phase 23) runs `fetch-metadata-async` on its own main loop.

## 3. Local registry fixture (`tests/fixtures/registry/`)

An in-process HTTP server (reusing `Clun.serve` from a fixture script, or a CL server) that serves a
hand-built registry so install tests are hermetic:
- ~8 fake packages with real semver/dep relationships: a plain package; a scoped `@scope/pkg`; a
  `bin`-bearing package; a version **conflict** that forces nesting; a **pax-longname** tarball entry.
- Each package's `.tgz` is hand-built (a gzipped ustar tar of `package/package.json` + a file or two);
  `dist.integrity` = `sha512-<base64>` computed from the real tarball bytes (**ironclad** SHA-512, now
  vendored — Phase 19 — + `cl-base64`); `dist.tarball` templated to the server's base URL.
- Metadata JSON served with `ETag` + `304 Not Modified` on `If-None-Match`, and gzip on
  `Accept-Encoding: gzip` (the client's chipz decode round-trips it).
- Reusable as a `make` target / a CL helper so Phases 22–23 reuse it.

## 4. Gate tests

- **semver**: the fixture replay at 100% (minus the 3 documented deviations).
- **registry round-trips**: the client fetches metadata for a plain + a scoped package from the fixture;
  a gzip response decodes; a second request with the returned `ETag` gets `304` and reuses the cache.
- **fixture server**: a `make` target (or CL entry point) starts it on an ephemeral port; the .tgz
  bytes verify against their advertised `dist.integrity`.

## 5. Risks / notes

- node-semver fixtures encode JS-specific input coercion (object inputs); those are enumerated
  deviations, not failures.
- The registry client's live npm path is blocked by the pure-tls `registry.npmjs.org` `protocol_version`
  interop gap (Phase 20 known issue) — the local fixture keeps Phase 21 fully hermetic; the live smoke
  is Phase 23's concern.
- Tarball building here is minimal (enough for metadata + integrity round-trips); the hardened
  ustar/pax **reader** + traversal suite is Phase 22.
