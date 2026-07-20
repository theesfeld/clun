<!-- clun-generated:release-notes:begin -->
# Clun 0.2.0-dev.11

Phase 82: Purity-compatible Bun-surface final audit and release.

- SemVer impact: `patch` within the selected `0.2.0` prerelease train.
- Compatibility snapshot: 30 Yes / 0 Partial / 0 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->
## Highlights

- Immutable `v0.2.0-dev.1` peels to exact master commit
  `184dfa13577ae6f24a7e6dde785a824ef46aa373`. Its release run passed Linux x64/arm64 and macOS
  arm64, but macOS x64 exposed an order-dependent fresh-hoist materialization race. Publication was
  skipped, so that tag has no GitHub Release or assets.
- Issue #219 fixes Darwin workspace links across the `/tmp` to `/private/tmp` alias,
  makes HTTPS completion frame-aware without weakening truncation checks, keeps
  CookieMap resource evidence strict and deterministic, and removes the runner
  image's unrelated untrusted `aws/tap` before Homebrew dependency resolution.
- Issue #221 replaces unsafe single-binary updater activation with checksum-verified full-bundle
  installation and an atomic stable-launcher switch.
- Issue #233 restores real public-registry package use in current source: `clun add <pkg>` and
  Bun-compatible `clun install <pkg>` now pass live metadata, transitive tarball, SRI, execution, and
  frozen transport-denied reinstall checks. Three `v0.2.0-dev.1` release targets reproduced that
  evidence; the published `v0.1.0-dev.21` binary still predates the repair.
- Issues #234 and #235 implement the bounded WebPKI profile plus one-shot fatal-alert and reciprocal
  `close_notify` behavior. CI, Compatibility, and Release exercise them through the complete
  `make test-tls` chain.
- Issue #241 keeps package downloads concurrent while committing ready packages in deterministic
  ancestor-before-descendant order independent of lockfile member order. Completed bodies wait in
  the verified cache or a cleaned lazy disk spool. Its forced timing regression reverses the
  lockfile package entries and compares identities parsed from the complete fresh and cache-only
  replay layouts before `0.2.0-dev.2` can replace the failed tag-only attempt.
- The default install destination becomes `~/.local/bin`; the complete release bundle is retained
  under the XDG data root, and any failed install or update preserves the prior launcher and bundle.
- Tag publication requires successful push-event CI, Documentation, Compatibility, and Pages runs on
  the exact tagged master SHA. Initial publication and immutable reruns redownload exactly four native
  archives plus `checksums.txt`, require one checksum record per archive, and run strict SHA-256
  verification.
- The train is breaking in intent; Clun records `major` while publishing the recovery as the
  conventional pre-1.0 minor-core candidate `0.2.0-dev.2`.
