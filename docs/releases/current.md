<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.38

Phase 38: Web platform foundations.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 13 Yes / 4 Partial / 13 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->
## Highlights

- Issue #130 (Phase 38): runtime.web-standard-apis Partial→Yes —
  - Pure-CL WritableStream, TransformStream, BYOB readers, pipeTo/pipeThrough
  - HTTPS proxy object options `{url, headers}` on absolute-form HTTP and CONNECT
  - Hermetic 8 MiB Transform+BYOB stress evidence
  - Four-target supported; ledger Yes; gap cleared
- SemVer slot: free `0.1.0-dev.38` / `v0.1.0-dev.38` after websocket Yes `0.1.0-dev.38` on master
- Hosted installer remains on published `v0.1.0-dev.21` until a later unit publishes.
