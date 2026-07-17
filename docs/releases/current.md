<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.21

Phase 65: Cross-platform shell API.

- SemVer impact: `patch` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 9 Yes / 7 Partial / 14 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->

## Highlights

- Unpublished correction of master `0.1.0-dev.21` (no new prerelease slot): pure-CL unmatched
  pathname globs fail in command position with `clun: no matches found: <pattern>` (exit 1);
  assignment position keeps the literal pattern; multi-match assignment values join with a space.
- Inventory burn-down: **1,282 covered / 316 pending / 32 upstream-inactive** (was
  1,247 / 351 / 32). Closes 35 pending sites across language, glob, and
  `pwd | cd | pwd` pipeline isolation fixtures.
- Does **not** claim `tooling.shell` Yes. Residual parser, lifecycle, background,
  and permission-sensitive rows remain pending under Issue #39.
- Slot map: published base `v0.1.0-dev.18`; master source after Phase 37 m2 is
  `0.1.0-dev.21`; this unit retains that candidate as an unpublished correction.
  Hosted installer remains on published dev.18 until a later unit publishes.
