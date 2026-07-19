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

- Issue #219 fixes Darwin workspace links across the `/tmp` to `/private/tmp` alias,
  makes HTTPS completion frame-aware without weakening truncation checks, keeps
  CookieMap resource evidence strict and deterministic, and removes the runner
  image's unrelated untrusted `aws/tap` before Homebrew dependency resolution.
- Issue #221 replaces unsafe single-binary updater activation with checksum-verified full-bundle
  installation and an atomic stable-launcher switch.
- The default install destination becomes `~/.local/bin`; the complete release bundle is retained
  under the XDG data root, and any failed install or update preserves the prior launcher and bundle.
- The change is breaking in intent; Clun records `major` while publishing it as the conventional
  pre-1.0 minor-core candidate `0.2.0-dev.1`.
