<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.66

Phase 48: Native-addon constitutional checkpoint and conditional implementation.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 29 Yes / 1 Partial / 0 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->
## Highlights

- Issue #178 promotes `runtime.native-addons` No→**Yes** (pure-CL N-API/FFI host exceeding Bun).
- Slot: free `0.1.0-dev.66` after master fmt-lint Yes `0.1.0-dev.65`.
