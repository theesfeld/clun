<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.31

Phase 51: WebSocket and Pub/Sub.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 9 Yes / 8 Partial / 13 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->

## Highlights

- Phase 51 **M1** implements pure-CL RFC 6455 server handshake (`Sec-WebSocket-Accept`) and
  frame encode/decode for text, binary, ping, pong, and close.
- `Clun.serve({ websocket })` accepts handlers; `server.upgrade(req)` performs the 101 upgrade
  and drives a minimal frame loop sufficient for an echo server.
- Ledger row `server.websocket` promotes **No → Partial**. Residuals: no Pub/Sub
  (`publish` / `subscriberCount` remain fail-closed), no client `WebSocket`, no permessage-deflate,
  no fragmentation reassembly, no Autobahn / four-target Yes gate.
- Child Issue #121; parent phase Issue #25. Slot: free `0.1.0-dev.31` after master `0.1.0-dev.30`.

The release candidate stages an honest Partial capability with parachute evidence and does **not**
claim ledger Yes.
