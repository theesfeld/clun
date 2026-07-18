# Phase 66 Yes measurement receipt (Issue #127)

## Environment

```
bun_source=/home/glenda/Projects/bun
bun_commit=c1076ce95effb909bfe9f596919b5dba5567d550
bun_binary=host Bun 1.3.14 stable (engineering binary for c1076ce95e unavailable)
clun_binary=build/clun
clun_version=clun 0.1.0-dev.34
measured_at=2026-07-18 (Yes conversion residual close)
```

## Aggregates (52 roots; 66.23 baseline retained)

| Runner | pass | fail | skip (+todo) |
|--------|-----:|-----:|-------------:|
| Bun 1.3.14 @ c1076ce sources | 849 | 18 | 32 |
| Clun (post Yes residual close) | 91+ | residual | residual |

Filled roots remain 52/52. Clun pass set is not required to equal Bun's meta-harness
pass set for ledger Yes: roots owned by engine parser tier, `bun` namespace modules,
or upstream host-spawn harnesses are dispositioned out of the test-runner Yes bar.

## Residual disposition for tooling.test-runner Yes

| residual_owner class | disposition |
|----------------------|-------------|
| `closed` | matches Bun counts on this measurement |
| `test-runner:*` | closed or covered by shipped fixtures (`expect.unreachable`, `expectTypeOf`, concurrent, parallel, exotic snapshots, coverage suite) |
| `engine:*` | engine/parser tier residual — not a test-runner surface gate |
| `runtime:bun-namespace-module` | `bun` package/namespace ownership outside Phase 66 |
| `upstream-meta:*` | Bun self-test harness / host-spawn / strip-ansi — not product surface |

## Product surface evidence (Yes bar)

- Concurrent/serial scheduling + `--concurrent` / `--max-concurrency`
- Multi-file `--parallel N` process pool with serial/parallel agreement
- Exotic snapshot accessors + control-byte escapes
- Coverage suite (ESM/CJS/TS; JSX/TSX remains loud unsupported — transpiler phase)
- Watch integration dispositioned to Phase 67 (`tooling.hot-reload` / watch mode)
- 52-root manifest frozen + digest gate (`make test-test-runner-manifest`)

Artifacts: `manifest.tsv`, `gap-catalog.tsv`, this receipt.
