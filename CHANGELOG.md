# Changelog

All notable changes to Clun are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Clun is pre-1.0; minor versions may include breaking changes.

The immutable tags `v0.1.0-dev.2`, `v0.1.0-dev.11`, `v0.1.0-dev.12`,
`v0.1.0-dev.15`, `v0.1.0-dev.68`, `v0.1.0-dev.69`, `v0.1.0-dev.70`,
`v0.2.0-dev.1–v0.2.0-dev.4`, and `v0.2.0-dev.9` did not produce GitHub Releases
or assets and are not installable release checkpoints.

## [Unreleased]

## [0.2.2] - 2026-07-21

### Fixed
- `clun --update` now installs packaged `share/man/man1/clun.1` into the user man path (same as `site/install`). Archives without man still activate successfully.

## [0.2.1] - 2026-07-21

### Added
- Installed section-1 man page (`man clun`) generated from the same CLI catalog as `clun --help`.
- `make man` / `make man-check` gate so the man page cannot drift from live CLI functionality.
- Release archives include `share/man/man1/clun.1`; the installer stages it under the XDG man path.

### Notes
- Hard project rule: man page content must always match actual current CLI behavior.

## [0.2.0] - 2026-07-21

### Added
- First **stable** release of the `0.2.0` train after the beta prerelease series.

### Changed
- Maturity: leave the `beta` prerelease train. Historical immutable tags `v0.2.0-beta.1` / `v0.2.0-beta.2` remain published for recovery pins; new default installs and `--update` target stable `v0.2.0`.
- Phase 26 final hardening program closes with this release (Issue #58).

### Notes
- Pre-1.0: minor versions on the `0.x` train may still include breaking changes per SemVer 0.x convention.
- Built-in updater prefers higher maturity on the same core (stable > rc > beta > alpha > dev).

## [0.2.0-beta.2] - 2026-07-21

### Fixed

- Updater channel ranking: on the same core, prefer `beta`/`rc` over higher-looking `dev` tags (SemVer lexical prerelease order alone preferred `0.2.0-dev.11` over published `0.2.0-beta.1`).
- Multi-asset `clun --update` clears pure-tls session tickets per host so each download full-handshakes (avoids Certificate-missing PSK resume failures).
- TLS update failures print a curl reinstall recovery hint for stuck older binaries.

### Added

- TTY update-available notice on `clun --version` / `clun --help` (12-hour cached probe; stderr for version so machine-stable stdout remains one line).
- `clun --check-update` prints `run: clun --update` when behind.


## [0.2.0-beta.1] - 2026-07-20

### Added

- Phase 26 final hardening gate: `make phase-26-gate` and `scripts/phase-26-hardening-smokes.sh` (backtrace discipline, resource plateau, SIGINT interruption, partial-install recovery, bounded long-run server).
- Version-transition maturity ladder: same-core prerelease may advance `dev` → `alpha` → `beta` → `rc` starting at `.1` (enables this beta.1 ship after published `0.2.0-dev.11`).

### Fixed

- SIGINT / `SB-SYS:INTERACTIVE-INTERRUPT` now exits with a human `interrupted` message and code 130 instead of dumping an unhandled Lisp backtrace without `--backtrace` (Phase 26 hardening).

### Changed

- First **beta** prerelease of the `0.2.0` core after the purity-compatible surface train (`0.2.0-dev.*`) and Phase 82 audit.
- Design notebook `docs/design/phase-26.md` and Issue #58 rebaseline for beta.1 (stable `0.2.0` is a later unit).


## [0.2.0-dev.11] - 2026-07-20

### Fixed

- `clun install` / `add` / `remove`: unknown packages report `package not found: <name>` (not bare `registry error`); registry HTTP status errors include status and package name (Issue #280).
- Async `Clun.spawn` subprocesses are loop-owned via `register-loop-handle-resource` and cleaned up on settle or loop destroy (Issue #61).

### Added

- Unified CLI emit surface in `src/cli/style.lisp` (`emit-ok` / `emit-err` / `emit-warn` / `emit-info` / `fail` / `call-with-progress`) with TTY braille spinner for install progress; `CLUN_FORCE_COLOR` overrides `NO_COLOR`.

## [0.2.0-dev.10] - 2026-07-20

### Fixed

- `clun --update` multi-asset HTTPS: allow TLS 1.3 PSK resumption under `+verify-required+` when the session ticket carries a verified hostname (Phase 20 fail-closed patch was rejecting legitimate certificate-less resumed handshakes). Issue #272 / recovery Issue #276.

### Changed

- Advance the recovery candidate past immutable tag-only `v0.2.0-dev.9` (annotated tag peeled to the wrong historical commit; Release claims failed before assets). Verified installer remains `v0.2.0-dev.8` until `v0.2.0-dev.10` assets publish.

## [0.2.0-dev.9] - 2026-07-20

### Notes

- Immutable annotated tag only; **no GitHub Release or assets**. Peel was not the intended master TLS fix. Do not reinstall from this tag. Superseded by `0.2.0-dev.10`.

## [0.2.0-dev.8] - 2026-07-20

### Added

- `clun publish` â pure-CL pack + authenticated npm registry publish (`NPM_TOKEN` /
  `.npmrc` `_authToken`), with `--dry-run` packing a `package/`-prefixed tarball and SRI
  (Issue #262).

### Changed

- Promote `package-manager.npm` to **Yes**: install + publish surfaces complete on the
  pure-CL registry client (30 Yes / 0 Partial / 0 No).

## [0.2.0-dev.7] - 2026-07-20

### Added

- User native-addon load/hook: real `.so` / `.dylib` / `.node` open + typed call through
  a narrow allowlisted machine boundary; pure-CL host processes specs, marshalling, and
  registry (Issue #265 / Phase 48).
- ANSI-colored CLI help/version/update status (honors `NO_COLOR` and non-TTY).
- Braille spinner animation during `clun --update` asset download when attached to a TTY.

### Changed

- Promote `security.encrypted-secrets` to **Yes**: pure-CL AES-256-GCM vault is the
  purity-compatible full-port surface (exceeds Bun with has/list/clear). OS Keychain
  FFI is out of scope, not a Partial hold.
- Promote `runtime.native-addons` to **Yes**: purity constrains Clun implementation, not
  user-loaded machine code; Clun processes and hooks addons in Common Lisp.

## [0.2.0-dev.6] - 2026-07-20

### Fixed

- Stop pure-tls system CA bundle loading from emitting a WARNING for every
  unparseable PEM (legacy serial/GeneralizedTime/SAN forms). Trust-store skips
  match OpenSSL behavior; handshake verification remains fail-closed.

## [0.2.0-dev.5] - 2026-07-20

### Fixed

- Stop release packaging validation from false-failing under `set -o pipefail` when
  `tar -tzf` receives SIGPIPE after an early `grep` match for `bin/clun` (Linux x64/arm64
  Release archives contained the entry but still failed closed).

### Changed

- Advance the recovery candidate past immutable tag-only `v0.2.0-dev.4` (Linux packaging
  validation false-failed; Darwin assets built but publish was skipped); verified installer
  remains `v0.1.0-dev.21` until publication of `v0.2.0-dev.5` assets succeeds.

## [0.2.0-dev.4] - 2026-07-20

### Fixed

- Package release archives as portable ustar without macOS AppleDouble noise so the
  pure-CL extractor materializes `bin/clun` on every platform.
- Raise packaged-updater and self-update asset ceilings to 300 MiB for full SBCL
  bundles.
- Auto-create `package.json` on empty-directory `clun add` / `clun install <pkg>`.
- Repair site compatibility intro baseline-refresh contract for CI/Docs gates.

### Changed

- Advance the recovery candidate past immutable tag-only `v0.2.0-dev.2` (Release
  gates failed before assets); verified installer remains `v0.1.0-dev.21` until
  publication of `v0.2.0-dev.4` assets succeeds.

## [0.2.0-dev.2] - 2026-07-19

### Changed

- Advance the recovery candidate without moving or reusing immutable,
  tag-only `v0.2.0-dev.1`; the verified installer remains pinned to published
  `v0.1.0-dev.21` until the new four-platform assets pass every release gate.
- Correct README and Pages status to the verified current 19,848-assertion
  Common Lisp suite and make the still-missing npm publish and full registry-auth
  support visible alongside the working add/install path.

### Fixed

- Commit concurrently downloaded package tarballs to `node_modules` in
  deterministic ancestor-before-descendant order, independent of lockfile JSON
  member order, so a later parent extraction cannot erase an already-materialized
  nested dependency. Queue completed bodies through the verified cache or a
  cleaned disk spool instead of retaining an unbounded ready set in memory.
- Regenerate three dependency-bearing registry fixtures with valid package
  manifests so install-layout tests verify identity from extracted bytes.

## [0.2.0-dev.1] - 2026-07-19

### Added

- Add public Releases Atom-feed fallback for prerelease-only discovery when
  the unauthenticated GitHub Releases API returns 403.
- Add packaged full-bundle updater smoke coverage against real release archives.

### Changed

- Change the default installation destination to `~/.local/bin/clun`, with
  complete versioned bundles stored below the XDG data root.
- Bind no-argument installs to the ledger's verified boundary; explicit
  `INSTALL_VERSION=latest` retains redirect-first dynamic discovery.
- Select the highest suitable SemVer from fallback release listings rather
  than trusting chronological response order.
- Update an installation by staging and validating the complete release
  bundle, then atomically switching the installer-managed stable launcher.
- Record the distribution-contract break as `major` intent while publishing
  it on the conventional pre-1.0 `0.2.0` minor core.
- Classify npm package management as Partial until a real publish command and
  the remaining registry-auth/publishing corpus exist; do not conflate working
  public add/install with the complete Bun package-manager surface.

### Fixed

- Emit one typed fatal TLS alert for local TLS 1.2 failures and TLS 1.3
  certificate failures, never answer peer fatal alerts, and reciprocate a valid
  `close_notify` exactly once with independent receive/send state.
- Preserve Linux wrapper loaders and `libexec/clun` instead of replacing only
  the running core image.
- Resolve bare `argv[0]` only through `PATH`, preventing an updater from
  overwriting an unrelated file in the current directory.
- Preserve shell-profile symlinks whose canonical targets remain inside HOME;
  externally managed targets are reported and left unchanged.
- Retain the prior launcher and bundle on checksum, archive, version, layout,
  executable, or post-activation validation failure.
- Ship public npm metadata and tarball access through the experimental bounded pure-CL TLS
  1.3-to-1.2 fallback, and exercise both `clun add <pkg>` and `clun install
  <pkg>`, SRI, package execution, and byte-identical frozen offline reinstalls
  in the live, non-hermetic smoke required by Compatibility and Release. The
  frozen proof makes the registry unreachable and supplies an explicit empty TLS
  trust source so public tarballs cannot be downloaded as a fallback; the
  bounded WebPKI hardening recorded below now protects the authenticated path.
- Make `clun install <pkgâ¦>` a Bun-compatible alias for adding the named
  dependencies and installing them; retain no-argument `clun install` for the
  existing manifest.

### Security

- Fetch updater metadata and assets through direct pure-Common-Lisp HTTPS/TLS;
  no updater path synthesizes or evaluates JavaScript.
- Require the archive `VERSION` and staged executable version to match the
  requested immutable tag exactly before activation.
- Harden HTTPS identity and path validation with SAN-only DNS/IP matching,
  2048â8192-bit RSA server keys, and an eight-certificate ordered-path bound.
- Enforce non-anchor CA EKU constraints and reject malformed/empty KU/EKU,
  unsupported critical policy semantics, and every path containing
  `nameConstraints` until cumulative subtree processing is implemented.
- Consume DER, Certificate/TBSCertificate, Name, Extension, validity,
  AlgorithmIdentifier, SPKI, RSA, and ECDSA structures exactly; reject
  noncanonical RDN ordering and EC field coordinates, off-curve EC public keys,
  unsupported SAN GeneralName choices, noncanonical signature representatives,
  oversized/infeasible or declaration-mismatched RSA-PSS salts, and mismatched
  RSA-PSS key restrictions. TLS CertificateVerify fixes PSS salt length to the
  selected hash output length as required by the protocol.
- Bound DER and TLS certificate materialization by bytes, nesting, node count,
  chain entries, and per-CertificateEntry extension count before allocation.

## [0.1.0-dev.70] - 2026-07-19

### Added

- Add a root Keep a Changelog record covering every published checkpoint.
- Include the built-in `--update`, `update`, and non-mutating `check-update`
  surfaces staged by the tag-only dev.69 candidate.

### Changed

- Carry the Phase 82 candidate forward from immutable, tag-only
  `v0.1.0-dev.69` into a new recovery slot without moving or reusing a tag.
- Preserve `v0.1.0-dev.21` as the installer default until dev.70 assets are
  published and verified.
- Correct public capability claims to the evidence-backed 28 Yes / 2 Partial /
  0 No snapshot and enforce complete canonical Issue labels.

### Fixed

- Resolve workspace-link endpoints canonically so relative package links remain
  valid through Darwin's `/tmp` to `/private/tmp` alias.
- Make CookieMap scaling evidence deterministic with rotated paired trials and
  median ratios while retaining the strict `< 3.25` timing bound and allocation
  checks.
- Make blocking HTTPS frame-aware so complete Content-Length and chunked bodies
  finish without waiting for EOF, while truncated and until-close bodies still
  fail closed without authenticated `close_notify`.

### Security

- Remove the image-provided untrusted `aws/tap` before Homebrew dependency
  resolution on Darwin compatibility and release runners.

## [0.1.0-dev.21] - 2026-07-17

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.21)

### Added

- Ship the Phase 37 modern ECMAScript gap-wave checkpoint.

## [0.1.0-dev.19] - 2026-07-17

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.19)

### Added

- Ship the Phase 66 Jest-compatible test-runner checkpoint.

## [0.1.0-dev.18] - 2026-07-17

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.18)

### Added

- Ship the Phase 65 cross-platform shell API checkpoint.

## [0.1.0-dev.17] - 2026-07-17

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.17)

### Added

- Ship the Phase 50 router, static-file, and FileSystemRouter checkpoint.

## [0.1.0-dev.16] - 2026-07-17

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.16)

### Fixed

- Recover the Phase 31 YAML API and module-loading release after the tag-only
  dev.15 attempt.

## [0.1.0-dev.14] - 2026-07-17

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.14)

### Added

- Ship the Phase 36 password and hashing API checkpoint.

## [0.1.0-dev.13] - 2026-07-17

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.13)

### Added

- Ship the Phase 34 CSS Color API checkpoint.

### Fixed

- Recover the Glob and CookieMap release path from earlier tag-only attempts.

## [0.1.0-dev.10] - 2026-07-16

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.10)

### Added

- Ship the Phase 33 terminal string-width and ANSI-utility checkpoint.

## [0.1.0-dev.9] - 2026-07-16

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.9)

### Added

- Ship the Phase 35 CSRF API checkpoint.

## [0.1.0-dev.8] - 2026-07-16

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.8)

### Added

- Ship the Phase 29 public SemVer API checkpoint.

## [0.1.0-dev.7] - 2026-07-16

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.7)

### Added

- Ship the Phase 27 compatibility ledger and release-document automation.

## [0.1.0-dev.6] - 2026-07-16

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.6)

### Added

- Ship async generators and async iteration.

## [0.1.0-dev.5] - 2026-07-16

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.5)

### Added

- Ship synchronous generators and delegation semantics.

## [0.1.0-dev.4] - 2026-07-16

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.4)

### Added

- Ship the function and class conformance checkpoint.

## [0.1.0-dev.3] - 2026-07-15

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.3)

### Added

- Ship iterator and binding semantics.

### Fixed

- Recover release teardown after the tag-only dev.2 attempt.

## [0.1.0-dev.1] - 2026-07-15

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.1)

### Added

- Ship the first Phase 25b Object and compile-tier development checkpoint.

## [0.0.1-dev] - 2026-07-14

[GitHub Release](https://github.com/theesfeld/clun/releases/tag/v0.0.1-dev)

### Added

- Publish the initial Clun development release.

[Unreleased]: https://github.com/theesfeld/clun/compare/v0.2.0-dev.6...HEAD
[0.2.0-dev.6]: https://github.com/theesfeld/clun/compare/v0.2.0-dev.5...v0.2.0-dev.6
[0.2.0-dev.5]: https://github.com/theesfeld/clun/compare/v0.2.0-dev.4...v0.2.0-dev.5
[0.2.0-dev.4]: https://github.com/theesfeld/clun/compare/v0.2.0-dev.2...v0.2.0-dev.4
[0.2.0-dev.2]: https://github.com/theesfeld/clun/compare/v0.2.0-dev.1...v0.2.0-dev.2
[0.2.0-dev.1]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.21...v0.2.0-dev.1
[0.1.0-dev.70]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.21...v0.1.0-dev.70
[0.1.0-dev.21]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.19...v0.1.0-dev.21
[0.1.0-dev.19]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.18...v0.1.0-dev.19
[0.1.0-dev.18]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.17...v0.1.0-dev.18
[0.1.0-dev.17]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.16...v0.1.0-dev.17
[0.1.0-dev.16]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.14...v0.1.0-dev.16
[0.1.0-dev.14]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.13...v0.1.0-dev.14
[0.1.0-dev.13]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.10...v0.1.0-dev.13
[0.1.0-dev.10]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.9...v0.1.0-dev.10
[0.1.0-dev.9]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.8...v0.1.0-dev.9
[0.1.0-dev.8]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.7...v0.1.0-dev.8
[0.1.0-dev.7]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.6...v0.1.0-dev.7
[0.1.0-dev.6]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.5...v0.1.0-dev.6
[0.1.0-dev.5]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.4...v0.1.0-dev.5
[0.1.0-dev.4]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.3...v0.1.0-dev.4
[0.1.0-dev.3]: https://github.com/theesfeld/clun/compare/v0.1.0-dev.1...v0.1.0-dev.3
[0.1.0-dev.1]: https://github.com/theesfeld/clun/compare/v0.0.1-dev...v0.1.0-dev.1
[0.0.1-dev]: https://github.com/theesfeld/clun/releases/tag/v0.0.1-dev
