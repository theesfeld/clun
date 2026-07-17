<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.22

Phase 28: TLS, DNS, streaming transport, and public npm.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 9 Yes / 7 Partial / 14 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->

## Highlights

- Stages Phase 37 milestone 2 as a bounded engine residual conversion: pure-CL
  `Array.fromAsync` over Promise + async-iterator / AsyncFromSync / array-like paths.
- Admits nullish coalescing (`??`) and numeric separators in the lexer/parser so frozen
  Test262 helper observation controls parse (emitter already handled `??`).
- Converts 95 frozen `built-ins/Array/fromAsync` failures; pass-list reclassification is not
  claimed on this candidate. No compatibility-table `Yes` is claimed.
- Slot map after published shell (`v0.1.0-dev.18`, #86/#98) and master test-runner (#88):
  published base `0.1.0-dev.18`; master source is `0.1.0-dev.19`; transport holds unpublished
  `0.1.0-dev.20`; this candidate allocates `0.1.0-dev.21` under the unpublished-intermediate
  prerelease gap policy (transition `0.1.0-dev.19` → `0.1.0-dev.21`).

The release candidate stages honest engine residual work without promoting any matrix row to `Yes`.
Merge, publication, and Phase 37 closure remain blocked on remaining inventory residuals, pass-list
integration, and final review.
