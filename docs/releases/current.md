<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.21

Phase 51: WebSocket and Pub/Sub.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 9 Yes / 7 Partial / 14 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->

## Highlights

- Phase 51 M0 constitutional checkpoint: pure Common Lisp WebSocket is **feasible**
  (RFC 6455 + Bun-shaped Pub/Sub on existing reactor/HTTP/Ironclad/Chipz paths) — not a
  purity block. Design notebook: `docs/design/phase-51.md`.
- Ships package `clun.websocket` types scaffold and fail-closed `Clun.serve` refusal of
  `websocket` options plus `upgrade` / `publish` / `subscriberCount` with clear Phase 51
  TypeErrors. No silent half-shim.
- Compatibility ledger `server.websocket` remains **No** until Autobahn-style and
  Bun-differential four-target evidence exist. Matrix counts unchanged (9 Yes / 7 Partial / 14 No).
- Version retention: master source remains unpublished `0.1.0-dev.21`; this unit does **not**
  allocate a new prerelease slot. Published boundary remains `v0.1.0-dev.18`.

This candidate is release-bearing fail-closed edge behavior only. It does **not** promote
`server.websocket` to Partial or Yes.
