<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.29

Phase 46: Processes, VM, workers, and async hooks.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 9 Yes / 7 Partial / 14 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->

## Highlights

- Bun-shaped object form: `Clun.spawn({ cmd: [...], ... })` and `Clun.spawnSync({ cmd: [...] })`.
- `signal: AbortSignal`, `timeout` (ms), and `killSignal` for async and sync spawn.
- Subprocess `killed`, `ref()`, and `unref()` over the existing loop handle.
- Slot map: published boundary `v0.1.0-dev.21`; master tip is `0.1.0-dev.28` after path.win32 #114;
  this candidate allocates free `0.1.0-dev.29` under the unpublished-intermediate prerelease gap policy
  (transition `0.1.0-dev.28` → `0.1.0-dev.29`).
- Does **not** claim matrix Yes; does not implement Issue #61 loop-owned lifecycle.

The release candidate stages honest spawn residual work without promoting any matrix row to `Yes`.
