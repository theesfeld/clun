<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.40

Phase 39: Full TypeScript transforms.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 14 Yes / 3 Partial / 13 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->
## Highlights

- Issue #133 (Phase 39): `language.typescript` **Partial→Yes** — erasable strip plus Bun-compatible
  runtime transforms for enums, runtime namespaces, and constructor parameter properties.
- Slot: free `0.1.0-dev.40` / `v0.1.0-dev.40` after master `0.1.0-dev.39`.

- Issue #135 (parent #49, Phase 75): pure-CL **`Clun.markdown`** and global **`HTMLRewriter`**.
- **30-feature honesty:** no forged matrix Yes / no 31st features.tsv row.
- Slot: free after master tip `0.1.0-dev.38` → `0.1.0-dev.39` / `v0.1.0-dev.39` (SemVer `minor`).
