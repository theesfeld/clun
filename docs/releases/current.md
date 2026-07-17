<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.30

Phase 49: HTTP server parity (bounded lifecycle slice).
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->

## Highlights

- Stages Phase 49 as a bounded Bun-compatible `Clun.serve` lifecycle slice:
  - `idleTimeout` (seconds; default 10; `0` disables; max 255)
  - `maxRequestBodySize` (bytes; parser 413 when exceeded)
  - `server.stop(true)` force-closes in-flight connections
- Exposes `server.idleTimeout` and `server.maxRequestBodySize` as readback properties.
- Keeps `server.http` **Partial**: streaming request/response bodies, TLS server, HTTP/2, Unix
  sockets, multi-listen, and full lifecycle inventory remain open for later Phase 49 work.
- Slot map: published base `0.1.0-dev.21`; master tip `0.1.0-dev.30` (concurrent #110); this
  candidate allocates free `0.1.0-dev.30` under the unpublished-intermediate prerelease gap policy
  (transition `0.1.0-dev.30` → `0.1.0-dev.30`).

The release candidate stages honest HTTP server Partial work without promoting any matrix row to `Yes`.
Merge and publication remain separate from full Phase 49 closure.
