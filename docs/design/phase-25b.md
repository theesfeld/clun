# Phase 25b - Conformance Push to 90%

Status: **milestone 1 complete - failure inventory and costed order only.** Phase 25 is complete,
so the dependency is satisfied. This milestone changes no engine behavior and does not begin a
correctness bucket. Milestone 2 is next and remains unstarted.

## 1. Scope and invariant

Phase 25b owns the correctness-only lift required by PLAN section 5 and Definition of Done 1.4.2.
The execution runner's curated denominator is fixed for this phase: tests classified `pass` or
`fail` are eligible, while the runner's existing explicit `skip` rules remain excluded. Milestone 1
does not add skip tags, weaken the corpus, or count a scope exclusion as a pass.

The latest measured execution result on the Phase-25-complete tree is:

| Classification | Count |
|---|---:|
| Pass today | 22,677 |
| Fail/gap | 5,486 |
| Explicit skip | 12,491 |
| Crash | 0 |
| Total files | 40,654 |
| Eligible (`pass + fail`) | 28,163 |

The current live pass rate is `22,677 / 28,163 = 80.52%`. The hard target is
`ceil(28,163 * 0.90) = 25,347`, so Phase 25b needs **2,670 additional live passes**. The checked-in
monotonic pass list contains 22,643 entries; 34 tests already pass beyond that frozen baseline, so
the final regenerated list must grow by at least 2,704 entries and contain at least 25,347 tests.

These numbers come from executable classifications, not from subtracting the pass list from the
corpus. That subtraction produces the stale 5,520-candidate estimate because it mistakes the 34
unfrozen passes for failures.

## 2. Reproducible inventory

Milestone 1 adds `scripts/test262-buckets.lisp`, a standalone pure Common Lisp analyzer. Its input
is the sorted `PATH<TAB>CLASSIFICATION` ledger already emitted when
`CLUN_CONFORMANCE_CLASSIFICATIONS` is set. It validates the ledger against the pinned test262 tree,
parses each test's frontmatter, and writes two reviewable artifacts:

- `tests/conformance/exec-gaps.tsv`: one sorted row per live failure, with the path owner,
  orthogonal phase owner, exclusive work bucket, topic, and all raw `features`, `flags`, and
  `includes` metadata (`-` is the explicit empty-list sentinel);
- `docs/conformance/test262-execution.md`: exact totals and deterministic cross-tabs by work
  bucket, path owner, topic, raw feature, and harness include.

The full 40,654-row execution ledger stays a generated scratch artifact. `make conformance-buckets`
always deletes any prior ledger, reruns the execution corpus, and analyzes that fresh result in one
target, so stale classifications cannot acquire current-HEAD provenance. The checked-in gap-only
snapshot is smaller, is sufficient to reproduce this milestone's planning inputs, and records the
source revision, pinned test262 revision, and ledger digest. The source revision is computed from
the execution inputs: a clean tree records its commit, while a dirty engine/runner/corpus records
`working-tree@<base-commit>` instead of pretending the base commit contains those changes. CI and
release builds use
`make conformance-buckets-verify` to perform the same fresh run into temporary artifacts and compare
their semantic content with the checked-in snapshot/report; only the volatile ledger path and source
revision are ignored.

The analyzer enforces these invariants:

1. input paths are unique, sorted, and exactly equal the runner's complete pinned language plus
   built-ins `.js` corpus after its `_FIXTURE` exclusion;
2. classifications are limited to `pass`, `fail`, `skip`, and `crash`, with zero crashes;
3. every checked-in execution pass-list entry appears exactly once and still classifies `pass`;
   the report records both the frozen baseline and the 34 currently-unfrozen passes;
4. every failure receives exactly one exclusive work bucket and remains visible on orthogonal
   path-owner, phase-owner, topic, raw-feature, and raw-include axes; the exclusive axes reconcile
   to 5,486, while feature/include counts are non-additive tag frequencies and their report tables
   are deliberately top-25 truncated;
5. a row is `skip` if and only if the runner's feature, module, raw, or negative-parse rules select
   it, preventing either invented skips or impossible pass/fail classifications;
6. all output tables reconcile to the ledger totals and repeat generation is byte-identical.

The runner currently maps timeouts, parser/runtime JavaScript conditions, and incomplete async
completion to the same `fail` result. A bucket is therefore an ownership hypothesis, not a claimed
root cause, and the cost ranges are not failure-kind measurements. Coarse global labels would not
distinguish the assertion failures that dominate the corpus, so milestone 1 does not add a second
790-second diagnostic run. Every implementation milestone must diagnose its selected exact slice
with focused execution before changing code; m2 may add an opt-in detail sidecar if that diagnosis
needs stable timeout/JS/async categories.

## 3. Exclusive work buckets

Rules are ordered; the first match owns the failure. Binding patterns come first because the same
generated matrix appears under functions, classes, generators, async code, loops, and assignments;
assigning those rows by their surrounding construct would hide the shared binder work. The phase
owner remains a separate field, so an `Array.fromAsync` row can be visibly owned by Phase 37 while
its reusable semantic dependency remains in an async/iterator work bucket.

| Order | Work bucket | Primary ownership |
|---:|---|---|
| 1 | `binding-patterns` | destructuring binding/assignment and default parameters |
| 2 | `dynamic-scope-eval` | direct eval and `with` environment semantics |
| 3 | `async-iteration` | `for await`, AsyncFromSyncIterator, `Array.fromAsync` |
| 4 | `async-generators` | async-generator functions and prototypes |
| 5 | `generators` | synchronous generators and delegation |
| 6 | `classes` | construction, inheritance, `super`, and class environments |
| 7 | `binary-data` | TypedArray, ArrayBuffer, DataView, and BigInt interactions |
| 8 | `regexp` | RegExp protocol and supported expression semantics |
| 9 | `iterator-protocol` | iterator records, closing, and iterable consumers |
| 10 | `promises` | Promise construction, combinators, jobs, and species |
| 11 | `collections` | Map, Set, WeakMap, and WeakSet |
| 12 | `arrays` | remaining Array constructor/prototype algorithms |
| 13 | `objects` | object literals, descriptors, integrity, and meta operations |
| 14 | `functions-arguments` | calls, parameters, Function variants, and arguments objects |
| 15 | `operators-references` | references, assignment/update/delete, and template operations |
| 16 | `primitive-builtins` | String, Number, Math, Date, JSON, Symbol, Error, Boolean, URI |
| 17 | `other-runtime` | audited residual language and built-in behavior |

The exact measured counts are checked in with the completed inventory report at
`docs/conformance/test262-execution.md`; all 17 rows reconcile to 5,486 failures.

## 4. Costed correctness order

Counts are planning pools, not promised pass gains. Cross-cutting fixes can make rows assigned to a
later exclusive bucket pass, and one test can contain multiple masked failures. To prevent double
counting, every Phase-25b-owned failure keeps its milestone-1 origin bucket. A path is credited only
at the first milestone where it changes from fail to pass; later pool sizes subtract every earlier
win from that origin. Shared enabling work receives no separate pass credit.

| Milestone | Correctness wave | Frozen disjoint origin pool | Pool | Low / nominal / high lift | Cost |
|---:|---|---|---:|---:|---|
| m2 | Two Object integrity and four Annex-B meta APIs | `objects` (164 owned rows from 166 runnable controls) | 243 | 122 / 150 / 164 | M |
| m3 | IteratorRecord plus binding/destructuring | `binding-patterns` + `iterator-protocol` | 1,494 | 400 / 900 / 1,200 | XL |
| m4 | Functions, classes, parameters, `super`, arguments | `functions-arguments` + `classes` | 394 | 120 / 260 / 330 | L/XL |
| m5 | Synchronous generators and `yield*` | `generators` | 108 | 30 / 75 / 100 | L |
| m6 | Async generators and async iteration | `async-iteration` + `async-generators` | 468 | 120 / 320 / 420 | XL |
| m7 | Shared species and constructor protocol | enabling seam; wins retain their origin | 0 | 0 / 0 / 0 credited | L |
| m8 | Array generic-algorithm residual | `arrays` | 249 | 60 / 140 / 200 | L |
| m9 | TypedArray/DataView/ArrayBuffer/BigInt residual | `binary-data` | 500 | 100 / 280 / 400 | XL |
| m10 | RegExp generic protocol and in-tier edge semantics | `regexp` | 218 | 60 / 130 / 180 | L |
| m11 | Direct eval, `with`, global environment | `dynamic-scope-eval` | 319 | 60 / 170 / 250 | XL |
| m12 | Promise and collection residual | `promises` + `collections` | 59 | 10 / 40 / 55 | M/L |
| m13 | Operators and references | `operators-references` | 192 | 40 / 115 / 165 | L |
| m14 | Primitive built-ins | `primitive-builtins` | 154 | 30 / 95 / 135 | L |
| m15 | Audited residual | `other-runtime` | 201 | 40 / 125 / 175 | L/XL, split |

The disjoint pools sum to exactly 4,599 Phase-25b-owned failures. Range totals are 1,192 / 2,800 /
3,774. Only the nominal scenario clears the required 2,670 lift, by 130; the low scenario does not.
This is an uncertainty model, not a conservative guarantee. If measurement remains below target
after m15, m16+ is created from the exact remaining in-scope rows, never from a skip or denominator
change. After every milestone the fresh ledger replaces estimates and the remaining pools are
re-costed. For example, species wins in Array, binary, RegExp, or Promise tests are reported once at
m7 under those frozen origins and removed from the corresponding downstream pools.

### 4.1 Pinned Bun/JSC reference evidence

Bun commit `c1076ce95effb909bfe9f596919b5dba5567d550` pins JavaScriptCore/WebKit commit
`c9ad5813fd23bd8b98b0738abc3d037ec716aa92`. Read-only inspection of those exact revisions supports
the first two waves without importing implementation code:

- JSC centralizes `SetIntegrityLevel` and `TestIntegrityLevel` in
  `Source/JavaScriptCore/runtime/ObjectConstructor.cpp`, then uses those shared algorithms for
  `Object.seal` and `Object.isSealed`. The four Annex-B accessor methods are registered and
  implemented together in `ObjectPrototype.cpp`; lookup walks descriptors without invoking getters.
  The six pinned test262 directories contain 181 files, 15 current static skips, and 166 runnable
  controls: 164 m2-owned rows plus the two Phase-37 controls identified below. Clun freezes zero
  passes from them today. This makes m2 bounded and supports a nominal 150-pass lift without copying
  JSC's object-layout fast paths into a correctness phase.
- JSC's runtime built-ins use `IterationRecord` plus shared open/next/step/close operations in
  `IteratorOperations.h/.cpp`. Its language `for-of` and array-destructuring paths implement the
  same semantic shape through bytecompiler helpers in `BytecodeGenerator.cpp` and
  `NodesCodegen.cpp`, caching the iterator and `next` method in registers rather than directly
  consuming that runtime C++ record. Clun should adopt the shared semantic record discipline, not
  claim those JSC layers are one call path. Clun currently materializes several iterable paths
  eagerly, re-reads `next`, and suppresses close errors in `src/engine/emitter.lisp`. M3 must
  therefore land a completion-aware iterator record first, migrate consumers second, and layer
  lazy binding/assignment semantics on it third.

## 5. Scope ownership without denominator gaming

The current runnable failure set includes later-ECMAScript proposal tests that Phase 37 will
eventually own. The analyzer assigns an orthogonal phase owner from 25 conservative feature tags,
full inline-or-block frontmatter parsing, and ten exact generated-test path overrides for untagged
coalescing/integer-separator syntax. That classifier finds **887** Phase-37-owned failures and
**4,599** Phase-25b-owned failures. The feature set covers set methods, change-array-by-copy,
`Array.fromAsync`, immutable ArrayBuffer, Float16Array, array grouping, RegExp.escape, newer Promise
helpers, Temporal, WeakRef/FinalizationRegistry, and the other exact tags encoded in the analyzer.

Milestone 1 does **not** convert any of these failures to skips. PLAN's Phase-25b estimate and 90%
target were approved against the existing curation, and that denominator already leaves room for
2,816 residual failures at the gate. The ordered plan can reach the target through in-scope shared
semantics while leaving proposal-specific residuals visible for Phase 37. Any future skip-set change
requires an explicit, reviewed PLAN/DECISIONS scope amendment; it is never reported as a pass gain.

Hard in-scope work remains counted even when expensive: iterator closing, species for shipped APIs,
coercion and detachment order, direct eval, `with`, mapped arguments, and bounded resource behavior.

## 6. Per-milestone verification protocol

Milestone 1 is complete only when the authoritative gap snapshot and inventory are generated, the
cost order is reviewed, and these documentation-only/tooling gates pass:

```sh
make conformance-buckets-check
make build
make test
make purity
make conformance
make conformance-exec
make public-claims-check
make roadmap-check
```

Every later correctness milestone additionally requires focused tests for the selected subsystem,
a fresh full classification ledger, zero crashes, every previously frozen pass still green, and a
monotonic `CLUN_GEN=1` pass-list update only after that proof. Public pass counts change only after
the regenerated checked-in list is green. Parser, lexer, analyzer, or early-error changes always run
both parse and execution conformance. Emitter or shared execution-semantic changes also run
`make conformance-exec-compare` so the maintained eager tier cannot diverge from the default tier.

Milestone 1 stops after generating and reviewing the inventory artifacts and passing every gate
above. On GitHub, the CI and release execution gate is the stronger fresh-ledger
`make conformance-buckets-verify`, which includes the full execution run, analyzer self-test, exact
corpus/skip validation, and semantic artifact comparison. The next `phase` invocation starts m2 and
is limited to `Object.seal`, `Object.isSealed`,
`Object.prototype.__defineGetter__`, `__defineSetter__`, `__lookupGetter__`, and `__lookupSetter__`.
Its target corpus is exactly those six test262 directories: 181 files, 15 current static skips, and
166 runnable controls. Of those, 164 are m2-owned; `seal-finalizationregistry.js` and
`seal-weakref.js` remain expected Phase-37 gaps because their missing globals are outside m2. Run
all 166 controls, but gate m2's lift against the 164 owned rows. `Object.hasOwn`,
`Object.freeze`/`isFrozen`, `Object.preventExtensions`/`isExtensible`, Proxy/Reflect, `__proto__`, and
all other Object residuals are excluded from m2. It must not silently absorb m3 work; split m2a
(integrity) and m2b (Annex-B accessors) if either half exposes a cross-subsystem dependency.
