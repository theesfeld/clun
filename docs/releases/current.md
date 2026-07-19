<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.68

Phase 82: Purity-compatible Bun-surface final audit and release.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 30 Yes / 0 Partial / 0 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->
## Highlights

- Issue #191 promotes `runtime.node-compatibility` Partial→**Yes** (pure-CL Node surface exceeding Bun).
- Slot: free `0.1.0-dev.68` after master Phase 37 m4 `0.1.0-dev.63` (webstd `.64`, fmt-lint `.65`, native-addons `.66`).
