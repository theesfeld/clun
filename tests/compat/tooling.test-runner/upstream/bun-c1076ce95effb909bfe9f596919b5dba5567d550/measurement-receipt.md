# Phase 66.23 measurement receipt

## Environment

```
bun_source=/home/glenda/Projects/bun
bun_commit=c1076ce95effb909bfe9f596919b5dba5567d550
bun_binary=/home/glenda/Projects/clun/tmp-test/bun-1.3.14/bun-linux-x64/bun
bun_version=1.3.14
clun_binary=/home/glenda/Projects/clun-worktrees/test-runner/build/clun
clun_version=clun 0.1.0-dev.19
timeout_s=90
measured_at=2026-07-17T16:01:01Z
```

**Note on Bun binary:** Engineering source is pinned at `c1076ce95e` (Bun 1.4.0-dev forward inventory).
No host-local binary built from that exact commit is available. Baseline Bun counts were measured with
**Bun 1.3.14 stable** (`0d9b296a`) against the pinned `c1076ce95e` sources. Re-measure under a true
`c1076ce95e` engineering binary when one is available:

```sh
# When a c1076ce engineering build exists:
CLUN_BUN_SOURCE=/path/to/bun-c1076ce95e \
CLUN_BUN_BINARY=/path/to/bun-built-from-c1076ce95e \
  sh scripts/measure-test-runner-roots.sh
```

## Commands used

```sh
# Bun (from bun source root at c1076ce95e)
timeout 90 bun test <source_path>

# Clun (absolute single-file path; cwd = source directory)
timeout 90 build/clun test /abs/path/to/<source_path>
```

## Aggregates (52 roots)

| Runner | pass | fail | skip (+todo) |
|--------|-----:|-----:|-------------:|
| Bun 1.3.14 @ c1076ce sources | 849 | 18 | 32 |
| Clun 0.1.0-dev.19 | 0 | 52 | 0 |

- **Filled roots:** 52 / 52 (no `pending` result triples remain)
- **Clun roots with any pass:** 0
- **Clun load-fail roots:** 51
- **Roots matching Bun counts (closed residual):** 0

## Residual owner histogram

- `test-runner:bun-test-esm-resolve`: 15
- `test-runner:bun-test-esm-resolve+cli-meta-spawn`: 8
- `engine:using-or-typescript-syntax+cli-meta-spawn`: 5
- `runtime:bun-namespace-module`: 4
- `engine:esm-import-in-test-files`: 4
- `runtime:bun-namespace-module+cli-meta-spawn`: 3
- `test-runner:bun-test-esm-resolve+concurrent-parallel`: 2
- `engine:class-fields`: 2
- `engine:numeric-separators-or-bigint-literal`: 2
- `engine:chained-optional-or-call`: 2
- `upstream-meta:bun-harness`: 1
- `test-runner:expectTypeOf`: 1
- `engine:optional-chaining-or-arrow`: 1
- `engine:using-or-typescript-syntax`: 1
- `engine:optional-chaining-or-arrow+cli-meta-spawn`: 1

## Interpretation

Clun currently cannot load or execute nearly all frozen upstream Bun meta-roots as-is. Dominant blockers:

1. **`bun:test` ESM resolve** for TypeScript roots that `import { ... } from "bun:test"`
2. **`bun` package/namespace** imports used by CLI/meta tests
3. **Parser tier gaps** (class fields, optional chaining, ESM import keyword, using/TS forms)
4. **Upstream harness / host-spawn** dependencies (`harness`, `bunExe()`) that are Bun self-tests, not pure Jest surface

These counts replace `pending` so Yes-gate work has a measured denominator. They do **not** promote the ledger row to Yes.

Artifacts: `manifest.tsv`, `gap-catalog.tsv`, this receipt. Local logs under `tmp-test/m6623-baseline/` (not committed).
