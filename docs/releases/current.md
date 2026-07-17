<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.20

Phase 28: TLS, DNS, streaming transport, and public npm.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 9 Yes / 6 Partial / 15 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->

## Highlights

- Stages Phase 28 transport foundation as an honest Partial surface: pure-CL TLS 1.2 registry
  fallback, A/AAAA DNS and Happy Eyeballs, streaming Fetch request/response bodies, HTTP
  connection pooling, and HTTP proxy / HTTPS CONNECT transport.
- Registers executable hermetic proxy contracts and DNS suite evidence under the real ledger IDs
  `runtime.web-standard-apis` and `package-manager.npm` (`make compat FEATURE=…` is valid).
- Keeps both public rows `Partial` (not `Yes`). Router owns published `0.1.0-dev.17`; shell owns
  `0.1.0-dev.18`; test-runner owns `0.1.0-dev.19`; this candidate allocates `0.1.0-dev.20` under the
  unpublished-intermediate prerelease gap policy.

The release candidate stages honest Partial transport and package-manager surfaces. Merge,
publication, and issue closure remain blocked on HTTPS proxy endpoints, pooling/stress breadth,
four-target receipts, and final review.
