<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.70

Phase 82: Purity-compatible Bun-surface final audit and release.

- SemVer impact: `patch` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 28 Yes / 2 Partial / 0 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->
## Highlights

- Issue #219 recovers the immutable tag-only dev.69 candidate on a new dev.70 slot.
- Darwin workspace links now survive the `/tmp` to `/private/tmp` alias, blocking HTTPS completes on
  valid framing without weakening truncation checks, and CookieMap timing remains strict but deterministic.
- Darwin CI removes the runner image's untrusted `aws/tap` before Homebrew dependency resolution.
