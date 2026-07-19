<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.47

Phase 40: JSX and TSX.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 16 Yes / 2 Partial / 12 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->
## Highlights

- Issue #186 promotes `language.jsx` No→**Yes**: pure Common Lisp JSX/TSX parse, transform, and
  execute with classic `React.createElement` and automatic `jsx`/`jsxs`/`Fragment` runtimes,
  file pragmas, tsconfig/jsconfig options, fragments, spreads, nested expressions, member tags,
  HTML entity decoding, and offline helpers that run without a `react` package (exceeds Bun).
- Evidence: nine shipped-binary fixtures under `tests/js/jsx/` with four-target `supported`
  platform receipts (`.jsx` and `.tsx`).
- Slot: free `0.1.0-dev.47` / `v0.1.0-dev.47` after master honesty scrub `0.1.0-dev.46`.
  Hosted installer remains on published `v0.1.0-dev.21`.
- Parent epic: FULL PORT [#177](https://github.com/theesfeld/clun/issues/177).

The release candidate stages full JSX/TSX execute-without-external-transform ledger Yes.
