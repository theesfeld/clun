<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.18

Phase 65: Cross-platform shell API.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 9 Yes / 7 Partial / 14 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->

## Highlights

- Adds the pure-Common-Lisp `Clun.$` application shell with tagged-template interpolation, parser/AST,
  variables, substitutions, pipelines, redirects, compound control flow, and internal builtins.
- Supports standalone `.bun.sh` files, positional parameters, dollar and backtick command substitution,
  isolated `Shell` instances, Blob/Response I/O, and brace-plus-glob composition.
- Freezes a digest-pinned Bun shell inventory and 1,630-site corpus with an honest Partial checkpoint.
  `tooling.shell` remains `Partial`, not `Yes`.
- Follows master `0.1.0-dev.17` router Yes (`server.router`).

The release candidate stages an honest Partial public shell surface. Merge, publication, and issue closure
remain blocked on residual corpus work, lifecycle stress, four-target receipts, and final review.
