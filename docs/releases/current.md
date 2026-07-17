<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.25

Phase 66: Jest-compatible test-runner parity.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 9 Yes / 7 Partial / 14 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->

## Highlights

- Stages Phase 66 concurrent/serial scheduling as a bounded Partial checkpoint under Issue #40:
  pure-CL `test.concurrent` / `describe.concurrent` / `test.serial` / `describe.serial`,
  `concurrentIf` / `serialIf`, CLI `--concurrent` and `--max-concurrency`, and Bun-shaped
  consecutive concurrent groups with overlapping async settlement on the realm event loop.
- Fixtures prove serial isolation between concurrent groups, sync concurrent ordering, and
  `--concurrent` defaulting with serial override.
- Does **not** promote `tooling.test-runner` to ledger `Yes`. Parallel files, watch, full
  frozen-root counts, four-target receipts, and residual exotic surfaces remain open.
- Slot map after published shell (`v0.1.0-dev.18`) and master tip (`0.1.0-dev.21` Phase 37 m2):
  parallel trains may hold unpublished intermediate slots; this candidate allocates
  `0.1.0-dev.25` under the unpublished-intermediate prerelease gap policy.

The release candidate stages honest test-runner residual work without promoting any matrix row to `Yes`.
