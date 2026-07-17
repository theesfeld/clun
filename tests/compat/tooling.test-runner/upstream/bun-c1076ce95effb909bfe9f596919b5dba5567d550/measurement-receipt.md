# Phase 66.23 measurement receipt

## Environment

```
bun_source=/home/glenda/Projects/bun
bun_commit=c1076ce95effb909bfe9f596919b5dba5567d550
bun_binary=/home/glenda/Projects/clun/tmp-test/bun-1.3.14/bun-linux-x64/bun
bun_version=1.3.14
clun_binary=/home/glenda/Projects/clun-worktrees/bun-test-resolve/build/clun
clun_version=clun 0.1.0-dev.17+ (master base; branch feat/issue-40-bun-test-resolve)
timeout_s=30
measured_at=2026-07-17T(re-measure after bun:test resolve)
```

**Note on Bun binary:** Engineering source is pinned at `c1076ce95e` (Bun 1.4.0-dev forward inventory).
No host-local binary built from that exact commit is available. Baseline Bun counts were measured with
**Bun 1.3.14 stable** against the pinned `c1076ce95e` sources (unchanged from the 66.23 fill).

## Commands used

```sh
# Bun (from bun source root at c1076ce95e)
timeout 90 bun test <source_path>

# Clun (absolute single-file path; cwd = source directory)
timeout 30 build/clun test /abs/path/to/<source_path>
```

## Aggregates (52 roots)

| Runner | pass | fail | skip (+todo) |
|--------|-----:|-----:|-------------:|
| Bun 1.3.14 @ c1076ce sources | 849 | 18 | 32 |
| Clun (post `bun:test` resolve) | 91 | 46 | 1 |

- **Filled roots:** 52 / 52 (no `pending` result triples remain)
- **Clun roots with any pass:** 8 (was 0)
- **Clun load-ok roots:** 11 (was ~0–1)
- **Roots matching Bun counts (closed residual):** 6
- **Roots improved vs prior all-load-fail baseline:** 11 load, 8 with pass

## Residual owner histogram

- `upstream-meta:bun-harness+cli-meta-spawn`: 11
- `engine:using-or-typescript-syntax`: 8
- `runtime:bun-namespace-module`: 7
- `closed`: 6
- `engine:esm-import-in-test-files`: 4
- `test-runner:loaded-zero-pass`: 3
- `upstream-meta:bun-harness+cli-meta-spawn+concurrent-parallel`: 2
- `test-runner:partial-assert-gap`: 2
- `test-runner:expectTypeOf-or-api-gap`: 2
- `engine:class-fields`: 2
- `engine:chained-optional-or-call`: 2
- `upstream-meta:strip-ansi-dep`: 1
- `engine:optional-chaining-or-arrow+cli-meta-spawn`: 1
- `engine:optional-chaining-or-arrow`: 1

## Interpretation

`bun:test` is now a pure-CL virtual module registered per test realm (`register-bun-builtin` +
`install-bun-test-module`). ESM `import { … } from "bun:test"` and CJS `require("bun:test")`
resolve without filesystem/node_modules. The previous dominant residual
`test-runner:bun-test-esm-resolve` is **cleared** for roots that only needed that path.

Remaining dominant blockers:

1. **Upstream harness / host-spawn** (`harness`, `bunExe()`, strip-ansi) — Bun self-tests
2. **`bun` package/namespace** imports
3. **Parser tier gaps** (class fields, optional chaining, ESM import keyword, using/TS forms)
4. **expectTypeOf / partial assertion** residuals after successful load

These counts **do not** promote the ledger row to Yes — row stays **Partial**.

Artifacts: `manifest.tsv`, `gap-catalog.tsv`, this receipt.
