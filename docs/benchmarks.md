# Benchmarks

Clun's performance is tracked with a small, fixed benchmark suite (the classic V8/Octane trio,
ported to run on the `clun` engine). Phase 25's speed gate is **≥5× vs. the Phase-24 baseline**
recorded below.

## Methodology (read before quoting a number)

- **Self-relative, clun-vs-clun.** Each benchmark runs a **fixed, pinned workload** (the iteration
  count is a committed constant in the file — `const ITERATIONS`, never auto-scaled). The speedup of
  any later build is `baseline_ms / current_ms` on that identical workload. This is the only
  comparison that is rigorous on this host and the correct one for a performance pass.
- **Steady-state timing** excludes startup: each file runs one untimed warmup, then times
  `ITERATIONS` iterations of the core workload with `Clun.nanoseconds()` (a monotonic nanosecond
  clock — `Date.now()` is only 1-second-granular here). Reported number = **best of `REPS` runs**
  (default 5), which damps GC/scheduler noise.
- **Startup measured separately** (`clun -e ''` wall-clock), never folded into the throughput ratio.
- **No cross-runtime comparison.** `node` and `bun` are **not installed on this host**, so there are
  **no clun-vs-node/bun numbers here** — none are fabricated. The same fixed-workload files run
  unmodified on any host that has them, so a cross-runtime table can be added later as a separate,
  clearly-labeled section.
- **Reproduce:** `make bench` (→ `bench/run.sh`; override reps with `REPS=N make bench`).

## The suite

| Benchmark | What it stresses |
|---|---|
| `richards`  | OS-scheduler simulation — polymorphic method dispatch + property access on a few stable shapes (inline caches + shapes). |
| `deltablue` | one-way constraint solver — prototype chains + many small polymorphic call sites (proto-chain caching + direct calls). |
| `splay`     | splay-tree insert/find/remove — allocation + GC pressure + shape churn (dense/allocation path + dict-fallback boundary). |

Each self-verifies its result (Richards checks the final queue/hold counts; DeltaBlue's
chain/projection tests assert exact variable values; Splay checks tree invariants) and **throws** on
any mismatch, so a mis-measuring workload fails loudly rather than reporting a bogus time.

## Phase-24 baseline (frozen)

Recorded at commit `b9a8a862` (Phase 24, gate MET) — the reference the Phase-25 ≥5× gate is measured
against. Lower is better.

- **Host:** Intel Core Ultra 9 275HX (24 cores), Linux x86-64
- **Compiler:** SBCL 2.6.5-85913ede1
- **Measurement:** best of 5 (`REPS=5 make bench`)

| Metric | Baseline | Workload |
|---|---|---|
| startup   | 17 ms | `clun -e ''` |
| richards  | 3600.4 ms | 80 iterations |
| deltablue | 2942.0 ms | 40 iterations |
| splay     | 1520.3 ms | 40 iterations |

**Phase-25 speed gate:** each benchmark's `current_ms` must reach `baseline_ms / 5` or better on the
same workload — i.e. richards ≤ 720 ms, deltablue ≤ 588 ms, splay ≤ 304 ms. The gate is evaluated
after the shapes / inline-cache / direct-call / string-builder milestones (see
`docs/design/phase-25.md` §7). Startup is reported but is not part of the ×5 ratio (it trades off
against any load-time compilation — §5 of the design doc).

_This file is updated (a new dated row per milestone) as optimizations land, so the ratio is always
traceable to the frozen baseline above._
