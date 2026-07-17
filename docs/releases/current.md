<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.17

Phase 50: Router, static files, and FileSystemRouter.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 9 Yes / 6 Partial / 15 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->

## Highlights

- Adds immutable exact, parameter, wildcard, and per-method `Clun.serve` routes plus Bun's legacy
  `static` alias, route-only servers, atomic reload, and `server.fetch()`.
- Adds conditional, ranged, backpressured regular-file responses with no-follow path safety and live
  revalidation, plus a bounded Next.js-style `Clun.FileSystemRouter`.
- Assigns every one of 254 pinned stable and engineering Bun route/static/file/router tests exactly once
  across 118 executable and five explicit non-applicable semantic contract rows, while retaining traceability
  for all 981 lexical sites.
- Records bounded Blob/body/clone concurrency and 100,000-route construction, lookup, and memory evidence.

The release candidate stages the public router row as `Yes` with registered evidence on all four targets.
Merge, publication, and issue closure remain blocked on green target receipts and final adversarial review.
