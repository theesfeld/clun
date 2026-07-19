<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.61

Phase 48: Native-addon constitutional checkpoint and conditional implementation.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 27 Yes / 2 Partial / 1 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->
## Highlights

- Issue #192 promotes `language.typescript` Partial→**Yes** (pure-CL transpile+decorators+tsx+structural typecheck exceeding Bun strip).
- Slot: free `0.1.0-dev.59` after master SFE Yes `0.1.0-dev.57` (leave `0.1.0-dev.58` for webstd #210).
