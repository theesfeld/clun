<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.34

Phase 47: Node compatibility certification.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 11 Yes / 6 Partial / 13 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->
## Highlights

- Issue #132 promotes `runtime.node-compatibility` Partial→**Yes** for the frozen **selected
  pure-CL Node surface**: `path` (posix + win32), `fs`, `url`, `buffer`, `events`, `assert`,
  `util`, `timers` / `timers/promises`, `querystring`, `os`, process globals, and crypto helpers.
- Evidence: eleven shipped-binary fixtures under `tests/js/node/` (modules, path-win32, url,
  buffer, bufedge, events, assertions, fsops, fsedge, globals, timers) with four-target
  `supported` platform receipts.
- Honest bounds: not full Node.js module/API/CLI or V8 parity; IDNA, resolveObject, URLPattern,
  and the broader Phase 47 certification inventory remain outside this Yes claim.
- Slot map: published base `v0.1.0-dev.21`; prior shell Yes candidate `0.1.0-dev.33`; this
  candidate allocates free `0.1.0-dev.34` / `v0.1.0-dev.34` (SemVer `minor`). Hosted installer
  remains on published dev.21 until a later unit publishes.

The release candidate stages the selected Node surface ledger Yes without claiming full Node
compatibility.
