<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.24

Phase 47: Node compatibility certification.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 9 Yes / 7 Partial / 14 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->

## Highlights

- Implements pure Common Lisp `path.win32` string algorithms (sep, delimiter,
  basename, dirname, extname, isAbsolute, normalize, join, resolve, relative,
  parse, format, toNamespacedPath / `_makeLong`) so `require('path').win32` no
  longer throws.
- Cross-links match Node: `path.win32 === path.win32.win32`, `path.posix.win32`,
  `path.win32.posix`.
- Host cwd for resolve/relative/namespaced paths rewrites `/` → `\` (Node-on-POSIX).
- Fixture-covered by `tests/js/node/path-win32.js`. **Does not** promote
  `runtime.node-compatibility` to ledger Yes.
- Slot map after published shell (`v0.1.0-dev.18`) and master Phase 37 m2
  (`0.1.0-dev.21`): parallel drafts hold 22–23; this candidate allocates
  `0.1.0-dev.24` under the unpublished-intermediate prerelease gap policy.

The release candidate stages honest node:path residual work without promoting any
matrix row to `Yes`.
