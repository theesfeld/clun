<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.34

Phase 75: Markdown + HTMLRewriter pure-CL checkpoint.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 10 Yes / 7 Partial / 13 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->
## Highlights

- Issue #120 (parent #39) shell-language residual burn-down after #122 parser and #123 lifecycle:
  pure-CL **export isolation** (shell-local assignments stay out of child environments until
  `export`), `which` prints `NAME not found`, silent Bun-compatible `cd -`, command-substitution
  stderr surfaces on the surrounding command, and unmatched-glob diagnostics use the
  user-visible pattern spelling.
- Corpus disposition: **1,551 covered / 47 pending / 32 upstream-inactive** (was 1,433 / 165
  after #123). Shell-language owner residual closes 118 sites. Fixture:
  `tests/compat/tooling.shell/upstream-language.js`.
- Does **not** claim `tooling.shell` Yes. Residual background, ENAMETOOLONG, and four-target
  receipts remain under Issue #120 / #39.
- Slot map: published base `v0.1.0-dev.21`; master tip `0.1.0-dev.30` (#113); this candidate
  allocates free `0.1.0-dev.31` / `v0.1.0-dev.31` (SemVer `minor`). Hosted installer remains on
  published dev.21 until a later unit publishes.

The release candidate stages honest Partial shell progress without promoting any matrix row to
`Yes`.
