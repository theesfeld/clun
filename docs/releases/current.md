<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.45

Phase 47: Node compatibility certification.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 16 Yes / 1 Partial / 13 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->
## Highlights

- Issue #132: `runtime.node-compatibility` Partial→**Yes** (selected pure-CL surface).
- Slot: free `0.1.0-dev.44` after master HTTP Yes `0.1.0-dev.43`.
