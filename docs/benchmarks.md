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
  (default 5), which damps GC/scheduler noise. The progress table states where later milestones
  deliberately increased `REPS`.
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

Every row uses the same host, compiler, and fixed workloads. Sampling was best of 5 for the baseline,
m2, and m3; best of 7 for m4–m7; and best of 9 for m8–m9. "×" is
`baseline_ms / current_ms` (higher is faster).

| Milestone | richards | deltablue | splay | startup |
|---|---|---|---|---|
| Phase-24 baseline | 3600.4 ms (1.00×) | 2942.0 ms (1.00×) | 1520.3 ms (1.00×) | 17 ms |
| m2 — profile-guided fast paths | 2262.0 ms (1.59×) | 2182.0 ms (1.35×) | 901.2 ms (1.69×) | 17 ms |
| m3 — shapes + read inline caches | 1705.0 ms (2.11×) | 1968.7 ms (1.49×) | 884.7 ms (1.72×) | 18 ms |
| m4 — array-index-key-p fast path | 1533.6 ms (2.35×) | 1790.4 ms (1.64×) | 565.0 ms (2.69×) | 17 ms |
| m5 — skip unused `arguments` object | 1064.2 ms (3.38×) | 1110.9 ms (2.65×) | 487.4 ms (3.12×) | 17 ms |
| m6 — ptable simple-vectors | 888.3 ms (4.05×) | 997.8 ms (2.95×) | 424.5 ms (3.58×) | 16 ms |
| m7 — create fast-path + write IC | 695.3 ms (**5.18×**) | 964.3 ms (3.05×) | 370.6 ms (4.10×) | 15 ms |
| m8 — array create + integer ToString | 580.0 ms (**6.21×**) | 848.1 ms (3.47×) | 342.9 ms (4.43×) | 14 ms |
| m9 — small-integer string cache | 543.5 ms (**6.62×**) | 771.8 ms (3.81×) | 286.9 ms (**5.30×**) | 14 ms |

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

**m4 (array-index-key-p fast path)** — profiling the laggards contradicted the planned m4: a write
inline cache *regressed* deltablue/splay (their writes mostly *create* properties, where the pre-write
shape never matches the cached post-write shape → every write missed and paid an extra refill scan), so
it was reverted. The real splay bottleneck was `array-index-key-p` (**26%** of splay) — the "is this key
a canonical array index?" test ran a full float-parse + `princ-to-string` round-trip on *every*
enumerated key. Rewritten to fail fast (a cheap digit scan + direct integer parse; a non-numeric key
like `"left"` returns nil after one char), plus the double index-parse in `ordinary-own-property-keys`
removed. Splay 1.72×→2.69×; no regression elsewhere. Semantically exact (verified against the canonical
array-index definition via observable array-length/enumeration behavior; a 2-agent panel found zero
divergences); zero pass-list regressions.

**m5 (skip the unused `arguments` object)** — deltablue's profile was dominated by `setup-frame` (~44%
total), and the bulk of that was an unconditional `arguments`-object allocation on *every* non-arrow
call. Now a non-arrow function builds `arguments` only when its body (or a nested arrow, at any depth,
or a default-param expression) textually references the identifier — detected precisely by flagging the
function scope whenever `arguments` resolves to it during compilation (a full traversal, so nothing is
missed). Sound: the object is unobservable in clun by any other channel (`f.arguments`,
`arguments.callee`, the arguments iterator, mapped/aliased args, `with`, and caller-visible direct
`eval` are all unimplemented — pre-existing, verified by a soundness panel + probes). Biggest single
lift so far: deltablue 1.64×→2.65×, richards 2.35×→3.38×, splay 2.69×→3.12×; zero pass-list regressions.

**m6 (ptable simple-vectors)** — the property table stored keys+descriptors in two ADJUSTABLE/
fill-pointer vectors, whose bounds-checked "hairy" `aref` was ~15% of the post-m5 profile (both the
read-IC-hit descriptor read and the linear-scan key reads). Converted to two parallel SIMPLE-VECTORs +
a manual `count` (grown by doubling); every access is now `svref`. Behavior-neutral (a 6-invariant
adversarial review + growth/delete/hash-index/enumeration probes, zero divergences). richards crossed
4×; no regression.

**m7 (create fast-path + update-only write IC)** — two changes. (1) A fast `create-data-property`
path: a brand-new default data property on an extensible ordinary `:object` stores the descriptor
directly, skipping `validate-and-apply` (which re-defaults it into a second descriptor); helps
allocation-heavy splay (3.58×→4.10×). (2) A revived write inline cache at `obj.x = v` sites — the m4
version regressed create-heavy code because every write missed and paid an extra refill scan; this one
refills **only on an update** (the write left the shape unchanged), so a create pays nothing extra. It
stores into the cached slot in place after re-checking the live descriptor is data+writable, and only
caches an own writable-data update. Sound (a 2-agent panel + a cross-object same-shape accessor test
confirmed it always revalidates the per-object descriptor; 0 findings). **richards crossed 5× (5.18×).**

**m8 (array create fast-path + integer ToString)** — two profile-guided wins. (1) An array-index create
fast-path: a new index (≥ length ⟹ not already own) with a complete data descriptor on an extensible
array stores directly + bumps length, skipping `validate-and-apply` — splay's array-literal `[0..9]`
construction was ~33% (`jm-define-own-property (js-array)`). (2) An integer `number->js-string` fast
path: a whole-number double in `[1, 2^53]` prints as its plain decimal (`floor` is exact there), skipping
the exact-rational Ryū machinery — deltablue's `"v"+i` names and splay's `String(key)` showed up as
`gcd`/`intexp`. Both verified sound (2-agent panel; the number path checked against the full Ryū path over
4.3M values, 0 mismatches); zero pass-list regressions. deltablue 3.05×→3.47×, splay 4.10×→4.43×.

**m9 (small-integer string cache)** — array index keys + integer `ToString` are pervasive (array
literals, `arr[i]`, `String(i)`, `"v"+i`) and were re-formatting a decimal string each time
(`stringify-object` ~8% of splay). A shared cache of `"0".."1023"` (JS strings are immutable, so a
shared instance is safe as both a value and a property key) is handed out by `int->string`, used at
`number->js-string` + every array-index call site. Behavior-neutral (byte-identical to `princ-to-string`;
a reviewer confirmed sharing is unobservable — all comparisons are `string=`/`equal`, never `eq`). **splay
crossed 5× (5.30×)**; deltablue 3.47×→3.81×.

**Gate status — 2 of 3 benchmarks MET; geomean ≥ 5×.** richards 6.62×, splay 5.30×, deltablue 3.81×
(geomean ≈ **5.1×**). The per-benchmark gate (each ≥ 5×) is met by richards + splay; **deltablue (≤588 ms
target, at 772 ms) is the holdout** — its residual cost is property-lookup scanning at IC-*miss* sites,
dominated by **deep-prototype method dispatch** (its constraint class hierarchy puts methods at depth ≥ 2,
which the depth-1 proto IC can't cache) plus call-frame machinery and constructor-write creation. Closing
the ~31% deltablue gap needs either risky deep-IC work (a general prototype-chain IC / a transition write
IC) or the machine-code-tier `COMPILE` path (§5) — exactly the case §8.1 flagged as "plausible, not
guaranteed" for a tree-walking interpreter. This is an open PLAN §2.4 scope decision (per-benchmark ≥5×
vs geomean/majority ≥5×).

_This file gains a new row per milestone, so every ratio is traceable to the frozen baseline above._
