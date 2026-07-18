<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.37

Phase 75: Data formats, Markdown, and HTMLRewriter.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 11 Yes / 6 Partial / 13 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->
## Highlights

- Issue #127 (Phase 66): tooling.test-runner Partial→Yes —
  - Cooperative `test.concurrent` / `describe.concurrent` / `test.serial` with `--concurrent` and `--max-concurrency`
  - Pure-CL multi-file `--parallel` process pools with serial/parallel count agreement
  - Exotic snapshot property tokens (own-accessor Getter, control-byte escapes)
  - `expect.unreachable` and runtime `expectTypeOf`
  - Measured 52-root disposition; four-target supported; ledger Yes; gap cleared
- SemVer slot: free `0.1.0-dev.36` / `v0.1.0-dev.36` after master archive/cron at `0.1.0-dev.35`
- Hosted installer remains on published `v0.1.0-dev.21` until a later unit publishes.
