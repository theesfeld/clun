<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.19

Phase 66: Jest-compatible test-runner parity.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 9 Yes / 7 Partial / 14 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->

## Highlights

- Stages Phase 66 Jest-compatible test-runner parity as an honest Partial surface: core and extended
  matchers, snapshot lifecycles with Bun-formatted values, source-aligned coverage (text/LCOV),
  function and module mocks, setup preloads, realm-local fake timers, reporters, sharding, and
  deterministic randomization.
- Freezes a 52-root Bun denominator manifest; exact Bun/Clun pass/fail/skip counts, concurrent
  scheduling, JSX coverage mapping, and four-target Yes receipts remain open.
- Keeps the public ledger row `Partial` (not `Yes`). Shell Partial is on master as source
  `0.1.0-dev.18`; published boundary remains `v0.1.0-dev.17`; this candidate allocates
  `0.1.0-dev.19` as the next prerelease after master.

The release candidate stages an honest Partial public test-runner surface. Merge, publication, and
issue closure remain blocked on residual PLAN gates, four-target receipts, and final review.
