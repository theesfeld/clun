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

- Stages Phase 28 transport foundation (Issue #2 / PR #95): pure-CL TLS 1.2 registry
  transport, DNS and Happy Eyeballs, streaming Fetch with clone/tee, plain HTTP pooling,
  origin-keyed pure-tls HTTPS idle pooling, and HTTP proxy / HTTPS CONNECT support.
- Absorbs master through `0.1.0-dev.21` (Phase 37 m2, node:url residual, TypeScript
  declare-enum strip, one-chunk Response/Request.body ReadableStream consumers, bun:test
  module resolve) while keeping the candidate at `0.1.0-dev.22` (no 23+ slot theft).
- Public `runtime.web-standard-apis` and `package-manager.npm` remain honest `Partial`
  (not Yes). Residual gaps: HTTPS proxy endpoints, broader pool/race stress, large-transfer
  and portability gates, full Streams (BYOB/Transform/Writable).
- Slot map: published installer boundary `v0.1.0-dev.18`; master source `0.1.0-dev.21`;
  Phase 28 candidate `0.1.0-dev.22` under unpublished-intermediate prerelease gap policy
  (`previous_version` remains the published boundary).

The release candidate stages honest Partial transport work without promoting any matrix
row to `Yes`.
