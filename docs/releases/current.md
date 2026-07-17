<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.12

Phase 30: Glob API.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 4 Yes / 6 Partial / 20 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->

## Highlights

- Supersedes the unpublished dev.11 tag after both arm64 release builders exposed geometric CookieMap
  backing-vector growth; an allocation-free layout prepass now assigns exact capacity without weakening
  the release gate.
- Adds `Clun.Cookie` and `Clun.CookieMap`, including parsing, serialization, attributes, mutation,
  live iteration, expiry, tombstones, and private receiver validation.
- Integrates request cookies and ordered `Set-Cookie` output with `Headers`, `Request`, `Response`,
  `fetch`, and `Clun.serve` without reusing state across requests or mutating shared responses.
- Hardens incremental HTTP framing and repeated-header handling for split reads, pipelines, conflicting
  lengths, chunked bodies, injection attempts, and bounded input.
- Adds the Proxy internal-method support required by the public Cookie and HTTP surfaces. This release
  does not claim blanket ECMAScript Proxy compatibility or promote the broader HTTP/Web API rows.
