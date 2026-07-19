<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.64

Phase 38: Web platform foundations.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 27 Yes / 1 Partial / 2 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->
## Highlights

- Issue #207 promotes `runtime.web-standard-apis` Partial→**Yes** (pure-CL full Web Standard surface exceeding Bun).
- Residual streams edge cases, EventTarget/FormData/File, CompressionStream, crypto.subtle.digest, atob/btoa, performance, MessageChannel, queuing strategies, and hermetic large-transfer/network stress evidence.
- Slot: free `0.1.0-dev.64` after master Phase 37 m4 `0.1.0-dev.63`.
