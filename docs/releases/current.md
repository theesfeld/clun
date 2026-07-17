<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.16

Phase 31: YAML API and module loading.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 8 Yes / 6 Partial / 16 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->

## Highlights

- Completes the bounded `Clun.YAML` parser at 402/402 in the exact pinned Bun-generated corpus, with
  deterministic stringification, aliases/cycles, source-aware errors, and hostile-input limits.
- Loads `.yaml` and `.yml` through ESM and CommonJS with named exports, alias identity, and shared cache
  identity, converting the YAML compatibility row to the eighth evidence-backed `Yes`.
- Adds the first reviewed Phase 37 modern ECMAScript milestone: `Object.hasOwn`, array copy-by-change
  methods, String well-formedness methods, `Error.isError`, and `Promise.withResolvers`. Phase 37 remains
  in progress; this release does not claim full modern-language parity.
