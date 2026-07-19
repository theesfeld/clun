<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.63

Phase 37: Modern ECMAScript gap wave.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 26 Yes / 2 Partial / 2 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->
## Highlights

- Stages Phase 37 milestone 4 as a bounded engine residual conversion: pure-CL
  TC39 await-dictionary combinators `Promise.allKeyed` and `Promise.allSettledKeyed`
  (PerformPromiseAllKeyed over enumerable own keys; null-proto result objects).
- Converts **74** frozen keyed-Promise Test262 failures (`make phase-37-m4-check` → 74/74).
  One `allSettledKeyed/result-property-descriptors` row remains outside the freeze
  (Test262 propertyHelper `isConfigurable` is destructive; not an engine semantic gap).
- Test262 ledger: **26018** pass / **2145** fail; Phase 37 residual ownership **378** (−74).
- Does **not** claim a compatibility-table matrix **Yes**. Phase 37 stays open.
- Slot map: published base `v0.1.0-dev.21` (previous_version); master tip `0.1.0-dev.59`;
  concurrent open trains claim free `.58`/`.60`–`.62`; this candidate allocates free
  `0.1.0-dev.63` / `v0.1.0-dev.63` (SemVer `minor`). Hosted installer remains on
  published dev.21 until a later unit publishes.
