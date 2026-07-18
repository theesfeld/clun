<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.34

Phase 49: HTTP server streaming request/response bodies (Partial).

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: `server.http` remains Partial (streaming bodies land; TLS/HTTP2 residual).
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->
## Highlights

- Issue #128 (parent #23 Phase 49): pure-CL streaming request/response bodies for `Clun.serve`.
  - `new Response(readableStream)` is serialized with HTTP/1.1 `Transfer-Encoding: chunked`.
  - Async `controller.enqueue` after `start` parks `reader.read()` until chunks arrive.
  - Server `Request.body` is a ReadableStream; handlers can `getReader()` or stream-through
    `new Response(req.body)`.
- Does **not** claim `server.http` Yes. Residual server TLS, HTTP/2, Unix sockets, multi-listen,
  and four-target receipts remain under Issue #128 / #23.
- Slot map: previous candidate `0.1.0-dev.33`; this unit allocates free `0.1.0-dev.34` /
  `v0.1.0-dev.34` (SemVer `minor`). Hosted installer remains on published dev.21 until a later
  unit publishes.

The release candidate stages honest Partial HTTP streaming progress without promoting the matrix
row to `Yes`.
