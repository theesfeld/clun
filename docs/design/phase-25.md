# Phase 25 — Performance Pass

## 1. Overview and the Constraint

Phase 25 closes the gap toward the cl-js-era performance claims (PLAN §3.1) **without
any correctness cost**. The prior phases built a straightforward "compile AST → CL
closures" engine: each expression node becomes a `(lambda (env) → js-value)` closure that
invokes its sub-closures at runtime (emitter.lisp). Property access walks an
order-preserving property table (`ptable`) per lookup; calls dispatch untyped through a
CLOS generic; string `+` allocates a fresh string every time. Those are the four hot
paths this phase attacks.

**Hard constraints — these are gate conditions, not aspirations:**

1. **Zero pass-list regressions.** Every test in the curated test262 pass-list that
   passes at the Phase-24 baseline must still pass. The pass-list is the correctness
   oracle; a performance change that drops even one test is rejected.

2. **No correctness cost.** Shapes, inline caches, direct-call paths, and the
   string-builder are all *representation/dispatch* optimizations. They must be
   observably transparent to JS semantics (property order, enumeration, prototype
   chain effects, getter/setter timing, `delete`, `Object.defineProperty` on the
   same objects).

3. **All kernel changes live behind the internal-methods protocol.** The ten `jm-*`
   generic functions (objects.lisp:152–211) are the specification surface. Shapes and
   dense arrays slot in *below* that surface, at the `obj-own-desc` / `obj-set-desc` /
   `ptable-*` implementation layer (objects.lisp:50–100). The `jm-*` interface and the
   `js-getv` / `js-set` / `js-call` entry points (objects.lisp:315–321) do not change
   shape. This is what makes the optimization reviewable: a reader can confirm the
   spec methods are untouched and reason about the cache/shape layer in isolation.

The gate has three independent parts, and one of them is not a performance task:

- **(G1)** conformance pass-list unchanged or grown;
- **(G2)** ≥5× on the benchmark suite vs. the Phase-24 baseline;
- **(G3)** overall curated test262 ≥ 90%.

At the start of this phase curated test262 is ~80.4% (22,643 pass / 5,520 fail-gap /
12,491 skipped-by-feature-tag of 40,654 files). **(G3) is a ~2,700-test correctness
lift**, not a byproduct of making the engine faster. §7 and §8 treat it as a separate,
explicitly-scoped effort and flag the scope question to the human per PLAN §2.4.

---

## 2. Shapes / Hidden Classes

### 2.1 Design: an ADD-keyed transition tree with dict fallback

Following cl-js (`scls`/`hcls` — study, don't vendor; PLAN §3.1), a **shape** describes
the *layout* of an object: the ordered set of own-property keys and the slot index each
key occupies. Objects that were built by the same sequence of property additions share
one shape object and therefore one layout.

A shape node holds:

- `keys` — ordered vector of property keys defining this layout;
- `index-map` — key → slot index (materialized as a hash only past the linear-scan
  threshold, mirroring the existing `ptable` promotion at 16 keys, objects.lisp:45–88);
- `transitions` — a small map `key → child-shape`, the ADD transition edges;
- `proto` — the `[[Prototype]]` this shape was minted under (a proto change is a shape
  change; inline caches key on shape, so this keeps proto-chain caching sound);
- a flag marking whether the shape carries per-key attribute metadata that differs from
  the default `writable/enumerable/configurable = true` data descriptor.

Objects gain a `shape` reference and a flat `slots` vector; property *values* move into
`slots[index]`, replacing per-object storage of the key+descriptor pair for the common
"plain data property" case. The empty object starts at the shared root shape. Adding a
key `k` follows the `k` transition edge if present, otherwise mints a child shape and
records the edge — so two objects built `{a, b, c}` in the same order converge on the
same shape, and lookups become "check shape, index into `slots`."

### 2.2 When to fall back to a dict

The transition tree is only sound for the monotonic-add, uniform-attribute case. Fall
back to the existing `ptable` dictionary representation (which stays as the general
implementation) whenever:

- **`delete` of an own property** — deletion breaks the append-only layout invariant and
  would fragment the transition tree; the object goes to dict mode (objects.lisp:99, the
  `obj-remove-key` seam is the shape-invalidation point);
- **too many properties** — beyond a threshold (start at the same 16 used for hash
  promotion; tune by measurement) the shape tree stops paying for itself and risks
  unbounded transition-tree growth for objects-used-as-maps;
- **non-string keys / integer-index keys** — symbol keys and array-index keys do not go
  through the shape layer; array indices belong to the dense-array path (§2.4), symbols
  stay in `ptable`;
- **non-default descriptor attributes** — a property defined via
  `Object.defineProperty` with a non-standard attribute, or an accessor, is representable
  as a distinct shape but is rare enough that the first cut routes it to dict mode and
  measures before adding attribute-carrying shapes.

Dict-mode objects keep working exactly as today; inline caches simply miss on them and
take the slow path.

### 2.3 Attachment at the object-model seam

The shape layer attaches strictly below the `jm-*` protocol:

- **Read** goes through `obj-own-desc` (objects.lisp:91) → `ptable-lookup` /
  `ptable-pos` (objects.lisp:50). Shape mode answers "does this object have own key `k`,
  and at what slot" from `shape.index-map` instead of scanning the ptable, and returns a
  descriptor view over `slots[index]`.
- **Write / create** goes through `obj-set-desc` (objects.lisp:94) → `ptable-put`. A new
  own key triggers a shape transition (`obj-set-desc` is the *only* property-mutation
  path, per the object-model map, so this is the single insertion seam); an existing key
  writes `slots[index]`.
- **Delete** goes through `obj-remove-key` (objects.lisp:99) → dict fallback + shape
  invalidation.
- Because `jm-get-own-property` / `jm-define-own-property` (objects.lisp:152, :210) are
  thin wrappers over these two functions, the CLOS protocol and array override
  (objects.lisp:406) are unchanged.

The point of anchoring here: the descriptor-shaped view (`pd-value`, `pd-writable`, …)
that the `jm-*` methods consume is preserved, so getter/accessor semantics and property
enumeration order (indices, then insertion-ordered strings, then symbols) fall out of the
shape's ordered `keys` for free.

### 2.4 Dense arrays (same protocol)

`js-array` (objects.lisp:395) currently stores every element as a canonical decimal-string
property in the shared ptable. Behind the *same* protocol, a contiguous integer-index run
gets a dense backing vector; the `jm-define-own-property` override (objects.lisp:406) is
the branch point where a write to index `i` either extends the dense vector or, on a hole
/ out-of-range / non-writable-length case, deoptimizes back to property storage while
preserving the length invariants that method already enforces (objects.lisp:406–453).

### 2.5 Migration / measurement plan

1. Land shapes for the plain-object data-property case only; everything else falls to
   dict mode. Verify **G1** (full pass-list) before measuring speed.
2. Add dense arrays. Re-verify G1.
3. Measure each on the benchmark suite (§6) and record the per-benchmark delta. Only then
   decide whether attribute-carrying shapes or a larger dict threshold are worth the
   complexity. Shapes are a prerequisite for inline caches (§3) to have anything to key
   on, so they land first.

---

## 3. Inline Caches

### 3.1 Per-site cache cells keyed by shape

The engine is closure-per-site: every `obj.x`, `f(...)`, `obj.m(...)` compiles to its own
closure that closes over its operands (emitter.lisp). That gives each *syntactic site* a
natural home for a mutable **cache cell** captured in the closure. The cell records the
last shape(s) seen at that site and the resolved answer:

- **Monomorphic**: one `(shape → slot-index / getter / method)` entry. Hit path is a
  pointer-equality shape check plus a `slots` index — no ptable scan, no proto walk.
- **Polymorphic (small N)**: a tiny inline vector of up to N entries (start N=4). On
  overflow the site goes **megamorphic** and permanently takes the slow path
  (`js-getv`/`js-set`/`js-call` as today). Megamorphic is a correctness-preserving
  fallback, not a bug.

Every cache cell is an optimization over an operation that is *already correct* via the
`jm-*` path; a miss recomputes via that path and refills the cell. This is what keeps the
"no correctness cost" constraint mechanical: delete the caches and behavior is identical.

### 3.2 Read caching (property get)

Seam: the `js-getv` call inside the compiled member closure — emitter.lisp:285 (static
`obj.x`), emitter.lisp:270 (computed `obj[k]`). For static keys the cell keys on receiver
shape alone; for computed keys the cell keys on `(shape, key)`.

- **Own data property**: cache `(shape → slot-index)`; hit reads `slots[index]`.
- **Own accessor**: cache `(shape → getter fn)`; hit calls the getter with the receiver.
- **Prototype-chain hit**: cache `(receiver-shape → holder-shape, slot/getter)`. Because a
  shape encodes its `proto` (§2.1), a receiver-shape match guarantees the same proto link;
  the cache still validates the *holder* shape so that a mutation on the prototype
  invalidates correctly. This is the standard prototype inline cache and it is where most
  of the method-dispatch speedup on the benchmarks comes from.

### 3.3 Write caching (property set)

Seam: the `js-set` call in the setter closure — emitter.lisp:271 (static),
emitter.lisp:275 (computed).

- **Existing own data property, writable**: cache `(shape → slot-index)`; hit stores into
  `slots[index]`.
- **New own property**: cache the *shape transition* `(old-shape → new-shape, slot-index)`.
  A hit performs the transition and store without touching the transition-tree map lookup.
- **Accessor / non-writable / would hit a proto setter**: cache the setter fn, or mark the
  site as needing the slow `ordinary-set` path (objects.lisp:172–200), which correctly
  handles the silent-fail / strict-throw cases.

### 3.4 Call caching

Seam: emitter.lisp:317 (static method `obj.m()`), :313 (computed method), :321 (direct
`f()`); secondary seam setup-frame emitter.lisp:704–714.

- **Method call**: cache `(receiver-shape → method fn)` — the method lookup is a property
  read, so it reuses the read-cache machinery, then feeds §4's direct-call path.
- **Direct call**: cache the callable identity to skip the `callable-p` check and the
  `jm-call` generic dispatch (objects.lisp:370).

### 3.5 Invalidation

Correctness of caches reduces to correctness of shape identity, so invalidation is
centralized:

- A property **add** moves an object to a new shape → existing cells simply miss (their
  cached shape no longer matches).
- A property **delete** moves the object to dict mode → its (former) shape never matches
  again; cells miss.
- A **prototype reassignment** (`jm-set-prototype-of`, objects.lisp:138–148) is a shape
  change (§2.1) → dependent cells miss.
- A **descriptor redefinition** that changes attributes forces a shape change or dict
  fallback → cells miss.
- **Megamorphic** sites and **dict-mode** objects never hit; they are always correct by
  construction.

No cache needs an explicit "flush" signal: because a cell only ever *hits* on an
exact-shape match and shapes are immutable once minted, any semantically-relevant change
produces a shape mismatch. This is the invariant the review panel should check.

---

## 4. Direct Call Paths and String Builder

### 4.1 Direct call paths for known arity

Today dispatch is untagged: `js-call` → `callable-p` → `jm-call` → the function's
`compiled-body` `(lambda (fn this args new-target))`, with `args` pre-allocated as a CL
list (compile-arguments-list, emitter.lisp:289–302) and `setup-frame`
(emitter.lisp:704–714) binding params, building the `arguments` object, and defaulting
missing params to `undefined`.

The `param-count` is already recorded on the function object (emitter.lisp:65, :743). When
a call site's inline cache has pinned a callable identity (§3.4) **and** the call's
argument count equals the callee's `param-count` **and** the callee does not need a
reified `arguments` object (a property already analyzable at compile time in scope
analysis), the site takes a **direct path**: pass arguments positionally into a
frame-binding fast path in `setup-frame`, skipping the exact-count/underflow/overflow
generality and the `arguments`-object allocation. Any mismatch (different callee,
different arity, callee uses `arguments`/rest/default params) falls back to the current
general path — again, transparent to semantics.

### 4.2 String builder for `+=` chains

`js-add` (operators.lisp:22–27) calls `concatenate 'string` on every `+`, so an accumulate
loop `s += t` is O(n²) in total allocation. Two attachment options, both behind the same
observable result:

- **Site-level (preferred)**: at the compound-assignment seam (emitter.lisp:438,
  `apply-binop "+"`), when the compiled reference reads and writes the *same* string
  variable, accumulate into an adjustable `string` with a fill-pointer and materialize a
  simple-string only when the value escapes (is read by anything other than the next
  `+=`). This turns the loop into amortized O(n).
- **Type-dispatch (fallback)**: at operators.lisp:26 detect `(string, string)` and route
  through a builder, without the escape analysis. Simpler, smaller win.

The value observed by JS is a normal string in both cases; the builder is an internal
representation that is flushed to an immutable string before it can be observed. Ropes are
explicitly *not* proposed for v1 — measure the fill-pointer builder first.

---

## 5. COMPILE Tiering — Measure First, Likely Deferred

PLAN §3.1 already settled that we **never** `COMPILE`-per-function at load: it was measured
at 0.16–0.5 ms/fn, i.e. 10–25 s startup on large bundles. The documented fallback is
"hot-function tiering via `COMPILE` on a background thread (P25)." This phase treats that
strictly as a **conditional, measured** option:

- It only makes sense *after* shapes + inline caches + direct calls, because those remove
  the interpreter overhead that a `COMPILE`d tier would otherwise still pay through the
  same generic call/property machinery.
- It adds real complexity: a background compiler thread, a tier-up trigger (call-count or
  time), on-stack replacement or next-call swap, and thread-safety of the swap against the
  running closure. That complexity is only justified if the benchmarks still miss **G2**
  after the cheaper optimizations.

**Decision:** implement tiering *only if* the benchmark suite is short of ≥5× after
milestones m2–m4 (§7). Otherwise it is deferred to post-v1. We do not build it
speculatively.

---

## 6. Benchmark Methodology

### 6.1 The three ports

The suite is the classic V8/Octane trio, ported to run on clun:

- **richards** — OS-scheduler simulation; polymorphic method dispatch and property
  access on a few object shapes. Stresses inline caches and shapes hardest.
- **deltablue** — one-way constraint solver; deep-ish prototype chains and many small
  polymorphic call sites. Stresses proto-chain caching and direct calls.
- **splay** — splay-tree insert/delete/lookup; allocation- and GC-heavy, string-keyed
  nodes. Stresses shape churn and the dict-fallback boundary.

State (m1 done): `bench/` contains `richards.js`, `deltablue.js`, `splay.js`, and `run.sh`, wired to
the `make bench` target. The frozen Phase-24 baseline (commit `b9a8a862`, SBCL 2.6.5, best of 5):
startup 17 ms; richards 3600.4 ms / 80 iters; deltablue 2942.0 ms / 40 iters; splay 1520.3 ms / 40
iters — recorded in `docs/benchmarks.md`, which the ≥5× gate (richards ≤720, deltablue ≤588, splay
≤304 ms) is measured against.

### 6.2 Self-relative clun-vs-clun on a fixed workload

The gate is **≥5× vs. the Phase-24 baseline**, measured **clun-against-clun**. This is the
only comparison we can make rigorously on this host, and it is the *right* one for a
"performance pass": each benchmark runs a **fixed, pinned workload** (fixed iteration
counts / tree sizes, committed in the benchmark file, not auto-scaled). The Phase-24
build's steady-state time on that exact workload is the frozen baseline recorded in
`docs/benchmarks.md`. Every subsequent build runs the identical workload; the ratio
`baseline_time / current_time` is the speedup and is meaningful precisely because the
workload never moves.

- **Steady-state timing**: warm up, then take the median of REPS runs (REPS overridable
  per Makefile note) to damp GC and JIT-of-SBCL noise.
- **Startup measured separately**: process start → first result, reported as its own
  number, never folded into the throughput ratio (they trade off — see the load-time
  COMPILE decision in §5).
- **Reproducible**: `make bench` (Makefile:61) → `bench/run.sh`, writing results to
  `docs/benchmarks.md` with the SBCL version and host recorded.

### 6.3 Honest limitation: no cross-runtime comparison

**node and bun are not installed on this host** (verified: both absent from `PATH`).
Therefore cross-runtime numbers (clun vs. node/bun, and any absolute claim about
"cl-js-era performance") are **deferred and omitted** — this doc contains **no fabricated
comparison numbers**. If a host with node/bun becomes available, the same fixed-workload
benchmark files run there unmodified and the comparison can be added to `docs/benchmarks.md`
as a separate, clearly-labeled table. Until then, the ≥5× gate is defined entirely
self-relative to the Phase-24 clun baseline, which is what makes it a valid, checkable
number.

---

## 7. Milestones

Each milestone is verified by a **specific slice**: a benchmark ratio, a pass-list delta,
or both. G1 (no pass-list regression) is re-checked at *every* milestone, not just once.

Note: after m1, a `sb-sprof` profile of the baseline redirected the order — several cheap,
low-risk hot spots (per-op FP-trap masking, the write validate path, un-inlined descriptor
predicates, generic `position`/`equal` in the key scan) were worth taking *before* the risky
shapes rewrite. That became **m2 (profile-guided fast paths)**; shapes/ICs shifted to m3/m4. The
profile is the authority here ("measure first"), not the original static ordering.

| # | Deliverable | Verification |
|---|---|---|
| **m1 — Measure first** ✓ | Benchmark harness: `bench/{richards,deltablue,splay}.js` + `bench/run.sh` + `make bench`; frozen Phase-24 baseline (steady-state + startup) in `docs/benchmarks.md`. | `make bench` green + committed baseline. No engine change → pass-list unchanged. |
| **m2 — Profile-guided fast paths** ✓ | Behavior-preserving, no kernel rewrite: `with-js-floats` masks once per call chain (`*fp-masked*` guard + coarse masks at `jm-call`/`jm-construct`); write fast-path mutating an existing own writable data descriptor in place (guarded `(eq o receiver)` + non-array); tight `ptable-pos` scan (direct `string=`/`eq`); inlined descriptor predicates. | **G1**: pass-list unchanged (conformance 22,643). **G2 slice**: richards 1.59×, deltablue 1.35×, splay 1.69× (geomean ≈1.53×). |
| **m3 — Shapes + READ inline caches** ✓ | A `pshape` transition tree (interned per property-add order) on the ptable + a per-site monomorphic READ inline cache: OWN-data hit reads `descs[slot]` directly; depth-1 PROTO hit (method dispatch) revalidates the direct-proto link + holder shape. Sound (re-reads the live descriptor; only a layout change flips the shape). | **G1**: pass-list unchanged (conformance 22,643); a 3-agent 86-probe soundness panel found 0 divergences. **G2 slice**: richards 2.11×, deltablue 1.49×, splay 1.72× (cumulative). |
| **m4 — array-index-key-p fast path** ✓ | The planned write IC was tried + REVERTED (it regressed the create-heavy deltablue/splay; a sound transition IC is deferred). Profiling redirected here: rewrote `array-index-key-p` (26% of splay) to fail-fast digit-scan + direct integer parse (no float/`princ-to-string` round-trip); removed the double index-parse in `ordinary-own-property-keys`. | **G1**: pass-list unchanged (conformance 22,643); 2-agent panel + 11 edge-case probes, 0 divergences. **G2 slice**: richards 2.35×, deltablue 1.64×, splay 2.69× (cumulative). |
| **m5 — Skip the unused `arguments` object** ✓ | The `setup-frame` cost (~44% of deltablue) was mostly an unconditional `make-arguments-object` per non-arrow call. Now built only when the body (or a nested arrow / default-param) textually references `arguments` — flagged during compilation via `comp-resolve`, gated in `setup-frame`. Sound (the object is unobservable in clun by any other channel). | **G1**: pass-list unchanged (conformance 22,643); soundness panel + probes, 0 divergences. **G2 slice**: richards 3.38×, deltablue 2.65×, splay 3.12× (cumulative) — the biggest single lift. |
| **m6 — ptable simple-vectors** ✓ | keys/descs moved from adjustable/fill-pointer vectors to parallel SIMPLE-VECTORs + a manual `count` (doubling growth); every access is now `svref` — kills the ~15% bounds-checked hairy `aref` on the read-IC hit + the scan. Behavior-neutral. | **G1**: pass-list unchanged (conformance 22,643); 6-invariant review, 0 HIGH/MEDIUM. **G2 slice**: richards 4.05× (crossed 4×), deltablue 2.95×, splay 3.58× (cumulative). |
| **m7 — create fast-path + update-only write IC** ✓ (partial) | Fast `create-data-property` (new default data prop on an extensible ordinary `:object` → straight to `obj-set-desc`). Revived write IC at `obj.x=v` sites, refilling ONLY on an update (shape unchanged) so creates pay nothing extra (fixes the m4 regression); stores in place after re-checking the live descriptor is data+writable. | **G1**: pass-list unchanged (22,643); 2-agent panel, 0 HIGH/MEDIUM. **G2 slice**: richards **5.18× (MET)**, deltablue 3.05×, splay 4.10×. |
| **m8 — array create fast-path + integer ToString** ✓ (partial) | Array-index create fast-path (new index + complete data desc + extensible → store direct + bump length, skip validate-and-apply; splay's `[0..9]` literal build ~33%). Integer `number->js-string` fast path (whole double ≤ 2^53 → plain decimal, skip Ryū). | **G1**: pass-list unchanged (22,643); 2-agent panel (number path vs Ryū over 4.3M values, 0 mismatches), 0 HIGH/MEDIUM. **G2 slice**: richards **6.21×**, deltablue 3.47×, splay 4.43×. |
| **m9 — Close the gate for deltablue + splay** | richards ✓. splay ~13% short, deltablue ~44% short. Levers: positional param binding (`nth`-walk O(n²)); a create/transition write IC to kill the constructor-write scan+proto-walk (subtle — proto-shadow invalidation); wider/polymorphic read ICs. | **G1** unchanged each step. **Gate G2 (≥5×)** across the trio (deltablue ≤588, splay ≤304 ms). |
| **(m10 — COMPILE tiering / scope note)** | If G2 stays unmet after m9 with behavior-preserving changes (§8.1: ≥5× "plausible, not guaranteed" for a tree-walker): the §5 background-thread `COMPILE` tier, OR a PLAN §2.4 scope note (accept the achieved multiple / adjust the gate). | **G2**: ≥5×, or an operator-approved gate adjustment. **G1** unchanged. |
| **Phase 25b — Conformance push to ≥90%** (separate phase, PLAN §5) | The former G3, split out (operator-approved). Failure-bucket analysis of the ~5,520 fail-gap tests → targeted correctness work; **not** performance. | **G3**: curated pass-rate ≥ 90%. **G1** monotonic. |

---

## 8. Risk Assessment (candid)

### 8.1 Is ≥5× realistic for a tree-walking closure interpreter?

**Plausible, but not guaranteed, and it is the tighter of the two performance-shaped
risks.** The current engine pays, on every hot operation, for: a linear/hash ptable scan
per property access, a full prototype-chain walk per method lookup, untyped generic
dispatch per call, and per-`+` string allocation. Shapes + inline caches on a polymorphic
OO workload have historically delivered order-of-magnitude improvements *in real VMs* —
but clun remains a closure interpreter with no machine-code tier, so the constant factors
are higher and the headroom is correspondingly real. A 5× steady-state improvement from
removing repeated ptable scans, proto walks, and dispatch on already-hot sites is a
reasonable target for a self-relative baseline that pays all of those costs today.

**Hardest benchmark: splay.** Richards and deltablue are dominated by repeated dispatch
and property access on a *stable, small* set of shapes — exactly what inline caches and
shapes target, so they should move the most. Splay is allocation- and GC-bound with
constant tree mutation (`delete` on nodes, churn of shapes), which pushes toward the
dict-fallback path and stresses the shape-invalidation boundary rather than the cache hit
path. Splay's speedup depends more on the dense/allocation work and SBCL's GC behavior
(PLAN §3 notes minor GC at 2–4 ms/1 GB) than on caches, so it is where the 5× is least
certain. If any single benchmark forces m6 (COMPILE tiering), it will be splay.

### 8.2 Is ≥90% curated test262 reachable as a Phase-25 sub-effort?

**This is a scope concern that should be flagged to the human per PLAN §2.4, not silently
absorbed.** Reasoning:

- G3 is a **correctness** gate (~2,700 additional passing tests, from 80.4% to 90%), while
  the entire *rest* of Phase 25 — its objective, its tasks, its name — is performance.
  Bundling a multi-thousand-test conformance lift under a "performance pass" mislabels a
  large, independent body of work.
- The 5,520 fail-gap tests are not uniform; they cluster by feature (regex classes,
  Intl-adjacent behavior, edge-case coercions, async/generator corners, etc.). Closing
  them is bucket-by-bucket feature work whose cost is only knowable after the failure
  analysis in m5 — it could be 2–3 phases of effort on its own.
- There is no engineering dependency between G3 and G1/G2: shapes/caches don't move the
  pass-rate, and conformance fixes don't move the benchmark ratio. Coupling them in one
  gate risks either shipping a performance win blocked on unrelated conformance work, or
  rushing conformance to unblock performance.

**Recommendation.** Execute the performance gate (G1 + G2) as the true Phase-25 body
(m1–m4, with m6 only if measured-necessary). Do **m5 as an explicitly separate track** and
raise the scope question to the human in the PLAN §2.4 form: *"G3 (≥90% curated test262) is
a ~2,700-test correctness effort with no engineering relationship to the Phase-25
performance work; it reads as its own phase. Propose splitting it out as Phase 25b (or
folding it into the conformance phase) so the performance gate can close on its own
schedule."* Record this under "Blocked/Open" in STATE.md and proceed with the performance
milestones rather than stalling on the conformance number.

**RESOLUTION (2026-07-14, operator-approved):** split accepted. G3 is now **Phase 25b —
Conformance push to ≥ 90%** (PLAN §5, deps: 25), starting with a failure-bucket analysis of
the ~5,520 `fail(gap)` tests. Phase 25's gate is G1 + G2 only; the m6 row above is Phase 25b.
DoD §1.4 point 2's "≥ 90% at Phase 25's close" now reads "Phase 25b's close".
