<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.14

Phase 31: YAML API and module loading.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 7 Yes / 7 Partial / 16 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->

## Highlights

- Adds a bounded YAML parser and deterministic stringification through `Clun.YAML`; the candidate
  currently passes 204 of 402 cases in the exact pinned Bun-generated parser corpus, so YAML remains
  `Partial` until the remaining 198 cases and all release-target receipts pass.
- Loads `.yaml` and `.yml` files through ESM and CommonJS with named exports and shared cache identity.
- Adds `Clun.password` sync/async password hashing and verification plus the complete pinned `Clun.hash`
  family, with cost ceilings, cross-tool vectors, and off-thread slow work.
