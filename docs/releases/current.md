<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.28

Phase 47: Node compatibility certification.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 9 Yes / 7 Partial / 14 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->

## Highlights

- Ships pure-CL `node:path.win32` string algorithms so `require('path').win32` no longer throws.
- Implements sep/delimiter, basename/dirname/extname, isAbsolute, normalize, join, resolve,
  relative, parse, format, toNamespacedPath/`_makeLong`, and Node-shaped posix/win32 cross-links.
- Does **not** promote `runtime.node-compatibility` to ledger `Yes`.
- Slot map: master tip `0.1.0-dev.26`; concurrent #110 claims `0.1.0-dev.27`; this candidate is
  `0.1.0-dev.28`.

The release candidate stages honest Node path residual work without promoting any matrix row to `Yes`.
