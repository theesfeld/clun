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

## Progress (per milestone, vs. the frozen baseline)

Same host / compiler / measurement as above. "×" is `baseline_ms / current_ms` (higher is faster).

| Milestone | richards | deltablue | splay | startup |
|---|---|---|---|---|
| Phase-24 baseline | 3600.4 ms (1.00×) | 2942.0 ms (1.00×) | 1520.3 ms (1.00×) | 17 ms |
| m2 — profile-guided fast paths | 2262.0 ms (1.59×) | 2182.0 ms (1.35×) | 901.2 ms (1.69×) | 17 ms |
| m3 — shapes + read inline caches | 1705.0 ms (2.11×) | 1968.7 ms (1.49×) | 884.7 ms (1.72×) | 18 ms |

**m2 (profile-guided fast paths)** — a `sb-sprof` profile of the baseline (`scripts/profile.lisp`)
showed property access + dispatch + the property-write validate path + per-op FP-trap masking
dominating. Four behavior-preserving changes, no kernel-architecture rewrite: (1) `with-js-floats`
masks the FP traps once per JS call chain instead of per arithmetic op (a `*fp-masked*` guard +
coarse masks at `jm-call`/`jm-construct`); (2) a write fast-path that mutates an existing own writable
data descriptor in place (guarded `(eq o receiver)` + non-array, so exotic receivers keep the full
path); (3) a tight `ptable-pos` linear scan (direct `string=`/`eq`, no generic `position`/`equal`);
(4) inlined descriptor predicates. Geomean ≈ 1.53×; zero test262 pass-list regressions.

**m3 (shapes + read inline caches)** — a `pshape` transition tree (interned per property-add order)
on the ptable gives objects with the same key layout a shared shape identity. A per-site monomorphic
read inline cache keys on that shape: an OWN-data hit reads `descs[slot]` directly (no key scan, no
`[[Get]]` generic dispatch); a depth-1 PROTO hit (for method dispatch `obj.m()`) additionally
revalidates the direct-proto link + holder shape. Both re-read the live descriptor + require a data
descriptor, so value/attribute changes and freeze stay correct; only a layout change flips the shape
→ miss. Richards (own-field + method-dispatch heavy) gained most (1.59×→2.11×). A 3-agent adversarial
soundness panel (86 live JS probes) found zero divergences; zero test262 pass-list regressions.

**Still short of the ≥5× gate** — deltablue (1.49×) and splay (1.72×) are now write- and
allocation-bound: the read IC hit still does an adjustable-vector `aref` (~15%), and writes/allocation
aren't cached yet. Next: a WRITE inline cache + moving `descs` to a simple-vector (m4), then
known-arity direct calls + a `+=` string builder (m5).

_This file gains a new row per milestone, so every ratio is traceable to the frozen baseline above._
