<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.23

Phase 37: Modern ECMAScript gap wave.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 9 Yes / 7 Partial / 14 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->

## Highlights

- Stages Phase 37 milestone 3 as a bounded engine residual conversion: pure-CL
  ES2025 `Set.prototype` set-methods (`union`, `intersection`, `difference`,
  `symmetricDifference`, `isSubsetOf`, `isSupersetOf`, `isDisjointFrom`) over
  Set-like `GetSetRecord` arguments.
- Converts 151 frozen `set-methods` Test262 failures; pass-list reclassification
  is not claimed on this candidate. No compatibility-table `Yes` is claimed.
- Slot map: published shell boundary `v0.1.0-dev.18`; master tip `0.1.0-dev.22`
  after Phase 28 transport foundation (#95); this candidate allocates
  `0.1.0-dev.23` under the unpublished-intermediate prerelease gap policy
  (transition `0.1.0-dev.22` → `0.1.0-dev.23`).

The release candidate stages honest engine residual work without promoting any matrix row to `Yes`.
Merge, publication, and Phase 37 closure remain blocked on remaining inventory residuals, pass-list
integration, and final review.
