<!-- clun-generated:release-notes:begin -->
# Clun 0.2.0-dev.1

Phase 82: Purity-compatible Bun-surface final audit and release.

- SemVer impact: `major` within the selected `0.2.0` prerelease train.
- Compatibility snapshot: 27 Yes / 3 Partial / 0 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->
## Highlights

- Current integration tree: Issue #234 is merged at `456467556c394e4e31b26e19747d25e6ce05a873`,
  Issue #235 is merged via PR #238 at `bf96273a28d5c6907c26a887a454a69afdb225b9`, and
  Issue #216 is the current release-hardening unit.
- Issue #219 fixes Darwin workspace links across the `/tmp` to `/private/tmp` alias,
  makes HTTPS completion frame-aware without weakening truncation checks, keeps
  CookieMap resource evidence strict and deterministic, and removes the runner
  image's unrelated untrusted `aws/tap` before Homebrew dependency resolution.
- Issue #221 replaces unsafe single-binary updater activation with checksum-verified full-bundle
  installation and an atomic stable-launcher switch.
- Issue #233 restores real public-registry package use in current source: `clun add <pkg>` and
  Bun-compatible `clun install <pkg>` now pass live metadata, transitive tarball, SRI, execution, and
  frozen transport-denied reinstall checks. The published `v0.1.0-dev.21` binary still predates that
  repair.
- Issues #234 and #235 implement the bounded WebPKI profile plus one-shot fatal-alert and reciprocal
  `close_notify` behavior. CI, Compatibility, and Release exercise them through the complete
  `make test-tls` chain; the candidate remains unpublished until the exact release gates pass.
- The default install destination becomes `~/.local/bin`; the complete release bundle is retained
  under the XDG data root, and any failed install or update preserves the prior launcher and bundle.
- Tag publication requires successful push-event CI, Documentation, Compatibility, and Pages runs on
  the exact tagged master SHA. Initial publication and immutable reruns redownload exactly four native
  archives plus `checksums.txt`, require one checksum record per archive, and run strict SHA-256
  verification.
- The change is breaking in intent; Clun records `major` while publishing it as the conventional
  pre-1.0 minor-core candidate `0.2.0-dev.1`.
