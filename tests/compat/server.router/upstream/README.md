# Pinned Bun router sources

This directory vendors the exact upstream source files that define Phase 50's stable and engineering
compatibility denominator. The files are evidence inputs only; Clun never executes, compiles, or ships them.

| Baseline | Exact Bun commit |
| --- | --- |
| Stable | `0d9b296af33f2b851fcbf4df3e9ec89751734ba4` (Bun 1.3.14) |
| Engineering | `c1076ce95effb909bfe9f596919b5dba5567d550` (Bun 1.4.0-dev) |

The four sources in each baseline are exact exports of:

- `test/js/bun/http/bun-serve-routes.test.ts`
- `test/js/bun/http/bun-serve-static.test.ts`
- `test/js/bun/http/bun-serve-file.test.ts`
- `test/js/bun/util/filesystem_router.test.ts`

`SHA256SUMS` makes any source drift a gate failure. `../upstream-inventory.tsv` assigns every lexical
`test`/`it` and `expect` site an explicit disposition. `scripts/router-upstream-inventory-check.sh` regenerates
that inventory deterministically and rejects missing evidence, changed counts, or unrecognized dispositions.

An `aggregate-mapped` row means the semantic cluster is exercised by a shipped Clun fixture; it does not
pretend that Bun's TypeScript test was run unchanged. `not-applicable` is limited to upstream `todo` or
commented sites, platform exclusions, and named cross-feature behavior such as Bun's build-cache integration.
Special files are also explicit: Clun's router serves regular files and rejects FIFO/device routes fail-closed.

The vendored sources retain Bun's MIT license. `BUN-LICENSE.md` is the upstream license text from the same
checkout. Clun remains GPL-3.0-or-later.
