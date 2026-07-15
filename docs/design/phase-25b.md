# Phase 25b - Conformance Push to 90%

Status: **milestones 1, 2, and 3 complete; milestone 4 is next and has not started.** Phase 25 is
complete, so the dependency is satisfied. Milestone 3 delivered the shared IteratorRecord and
binding/destructuring wave specified in section 6.2 while leaving diagnosed function/class,
species, global-environment, and Phase-37 residuals visible for their later owners.

## 1. Scope and invariant

Phase 25b owns the correctness-only lift required by PLAN section 5 and Definition of Done 1.4.2.
The execution runner's curated denominator is fixed for this phase: tests classified `pass` or
`fail` are eligible, while the runner's existing explicit `skip` rules remain excluded. Milestone 1
does not add skip tags, weaken the corpus, or count a scope exclusion as a pass.

The milestone-1 baseline measured on the Phase-25-complete tree was:

| Classification | Count |
|---|---:|
| Pass at m1 baseline | 22,677 |
| Fail/gap | 5,486 |
| Explicit skip | 12,491 |
| Crash | 0 |
| Total files | 40,654 |
| Eligible (`pass + fail`) | 28,163 |

The milestone-1 baseline pass rate was `22,677 / 28,163 = 80.52%`. The hard target is
`ceil(28,163 * 0.90) = 25,347`, so the initial Phase-25b requirement was **2,670 additional live
passes**. The checked-in monotonic pass list then contained 22,643 entries; 34 tests passed beyond
that frozen list at m1, so the final Phase-25b list must contain at least 25,347 tests.

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
   the m1 report records both the frozen baseline and the 34 passes then beyond it;
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

The milestone-1 measured counts were checked in with the completed inventory report at
`docs/conformance/test262-execution.md`; its 17 rows reconciled to the 5,486-failure baseline. Each
later milestone replaces that generated report with a fresh, fully reconciled snapshot.

## 4. Costed correctness order

Counts are planning pools, not promised pass gains. Cross-cutting fixes can make rows assigned to a
later exclusive bucket pass, and one test can contain multiple masked failures. To prevent double
counting, every Phase-25b-owned failure keeps its milestone-1 origin bucket. A path is credited only
at the first milestone where it changes from fail to pass; later pool sizes subtract every earlier
win from that origin. Shared enabling work receives no separate pass credit.

| Milestone | Correctness wave | Frozen disjoint origin pool | Pool | Low / nominal / high lift | Cost |
|---:|---|---|---:|---:|---|
| m2 | Two Object integrity and four Annex-B meta APIs | `objects` (162 owned rows from 166 runnable controls) | 243 | 122 / 150 / 162 | M |
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

The corrected milestone-1 ownership pools sum to exactly 4,597 Phase-25b-owned failures. Range
totals are 1,192 / 2,800 / 3,772. Only the nominal scenario clears the initial required 2,670 lift,
by 130; the low scenario does not.
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
  The six pinned test262 directories contain 181 files, 15 static skips, and 166 runnable controls:
  162 m2-owned rows plus the four Phase-37 controls identified below. Before m2, Clun froze zero
  passes from them. The focused post-implementation run now passes all 162 owned controls while the
  four later-phase controls remain visible failures. This makes m2 bounded without copying JSC's
  object-layout fast paths into a correctness phase.
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

The milestone-1 runnable failure set included later-ECMAScript proposal tests that Phase 37 will
eventually own. The analyzer assigns an orthogonal phase owner from 25 conservative feature tags,
full inline-or-block frontmatter parsing, ten exact generated-test path overrides for untagged
coalescing/integer-separator syntax, and two exact Object-seal path overrides for untagged Proxy
dependencies. The ownership correction assigns **889** baseline failures to Phase 37 and
**4,597** to Phase 25b. The feature set covers set methods, change-array-by-copy,
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

Milestone 1 stopped after generating and reviewing the inventory artifacts and passing every gate
above. On GitHub, the CI and release execution gate is the stronger fresh-ledger
`make conformance-buckets-verify`, which includes the full execution run, analyzer self-test, exact
corpus/skip validation, and semantic artifact comparison. Milestone 2 is limited to `Object.seal`,
`Object.isSealed`,
`Object.prototype.__defineGetter__`, `__defineSetter__`, `__lookupGetter__`, and `__lookupSetter__`.
Its target corpus is exactly those six test262 directories: 181 files, 15 static skips, and 166
runnable controls. Of those, 162 are m2-owned. Four controls remain assigned to Phase 37:
`seal-finalizationregistry.js`, `seal-weakref.js`, `seal-proxy.js`, and `throws-when-false.js`. The
first two require the later WeakRef/FinalizationRegistry globals; the latter two require Proxy even
though their frontmatter omits that feature tag. Run all 166 controls, but gate m2's lift against
the 162 owned rows. `Object.hasOwn`,
`Object.freeze`/`isFrozen`, `Object.preventExtensions`/`isExtensible`, Proxy/Reflect, `__proto__`, and
all other Object residuals are excluded from m2. It must not silently absorb m3 work; split m2a
(integrity) and m2b (Annex-B accessors) if either half exposes a cross-subsystem dependency.

### 6.1 Milestone 2 implementation design

The implementation stays behind Clun's existing object internal-method protocol. No object-layout
special case or Test262-specific branch is needed:

1. Add shared `set-integrity-level` and `test-integrity-level` abstract operations beside the object
   kernel. `set-integrity-level` first calls `[[PreventExtensions]]`, then snapshots
   `[[OwnPropertyKeys]]`. For `sealed`, it applies the partial descriptor
   `{ [[Configurable]]: false }` to every key with `DefinePropertyOrThrow`. The frozen branch is
   retained in the abstract operation for spec completeness and sets `[[Writable]]` false only for
   data descriptors. `test-integrity-level` first rejects an extensible object, then inspects every
   own descriptor without invoking accessors; sealed requires only non-configurable properties,
   while frozen also requires non-writable data properties.
2. Install `Object.seal` and `Object.isSealed` with arity 1 on the existing Object constructor.
   Primitives are returned unchanged by `seal` and report true from `isSealed`. A false integrity
   result becomes a `TypeError`; abrupt completions from internal methods propagate unchanged.
3. Install the four Annex-B methods on `Object.prototype` beside the existing `__proto__` accessor.
   `__defineGetter__` and `__defineSetter__` perform `ToObject(this)` before validating the callback,
   validate callability before coercing the key, then use `ToPropertyKey` and
   `DefinePropertyOrThrow`. Their descriptors contain only the requested `[[Get]]` or `[[Set]]`
   field plus enumerable/configurable true, so redefining one half preserves the other half.
4. `__lookupGetter__` and `__lookupSetter__` perform `ToObject(this)`, then `ToPropertyKey`, and walk
   `[[GetOwnProperty]]` / `[[GetPrototypeOf]]` directly. The first matching data descriptor stops the
   walk with undefined; an accessor returns its requested function or undefined. Lookup never calls
   the accessor and preserves symbol keys and prototype order.

Focused Lisp regressions cover primitive behavior, all integrity descriptor invariants, symbol and
prototype-chain lookup, accessor-half preservation, non-extensible/non-configurable failures, and
observable coercion order. The focused seal run also exposed a shared reference-semantics dependency:
strict-mode deletion must throw when an internal `[[Delete]]` returns false, while sloppy deletion
returns false. The emitter now routes member deletion through the shared `js-delete` operation and
preserves the reference evaluation order: evaluate the base expression, evaluate the computed key
expression, then apply `ToObject` before `ToPropertyKey`. This is required by the seal controls and
does not expand m2 into another Object API. The pre-existing failure to evaluate non-member `delete`
operands remains an explicit m13 operators/references residual.

Adversarial review also found that integer-indexed TypedArray `[[DefineOwnProperty]]` rejected
getter-only accessors but accidentally accepted setter-only descriptors. Because `__defineSetter__`
made that shared defect directly observable, m2 corrects the predicate to reject every accessor
descriptor and covers getter-only, setter-only, and ordinary non-index properties.

The focused milestone gate classifies all 181 files in the six pinned directories: 15 static skips,
162/162 passing m2-owned controls, and the four expected Phase-37 residual failures above. The full
40,654-file off/eager `make conformance-exec-compare` completed with byte-identical classifications:
22,862 pass, 5,301 fail, 12,491 skip, and zero crash in both modes, with zero eager fallback. The
monotonic execution pass list grew from 22,643 to 22,862 (`+219`); relative to the milestone-1 live
ledger, m2 gained 185 passes. Eligible remains fixed at 28,163, so the exact current rate is
81.177431% (publicly truncated to 81.17%) and the remaining lift to 25,347 is 2,485. The regenerated
gap inventory assigns 4,416 residuals to Phase 25b and 885 to Phase 37.

Milestone 2 began the `0.1.0` release train at `0.1.0-dev.1` because six backward-compatible public
APIs made the mixed API-plus-fix unit a SemVer minor change. Milestone 3 retained that minor core and
advanced the prerelease train to `0.1.0-dev.2`; its completed implementation and evidence follow.

### 6.2 Milestone 3 implementation design

Milestone 3 owns the frozen `binding-patterns` and `iterator-protocol` origin pools. At the
milestone-2 boundary those pools contain 1,412 and 85 live failures respectively. Surrounding
function, class, generator, async, and loop syntax does not move a generated binding test into a
later milestone: m3 fixes the shared binding operation while leaving unrelated surrounding-construct
residuals visible under their original phase owner.

The implementation order is deliberately semantic rather than path-specific:

1. Add `src/engine/iterator-operations.lisp` before the iterator and collection built-ins in the
   ASDF load plan. Its `iterator-record` caches `[[Iterator]]` and `[[NextMethod]]` exactly once and
   carries `[[Done]]`. Shared operations implement GetIteratorFromMethod, IteratorNext,
   IteratorComplete, IteratorValue, IteratorStep/StepValue, and IteratorClose. Step, `done`, and
   `value` abrupt completions mark the record done so a caller never incorrectly closes after an
   iterator-protocol failure. IteratorClose preserves an in-flight throw over `return` lookup/call
   failures, but a break/return/other non-throw completion observes close failures and rejects a
   non-object return result.
2. Remove the array/string eager shortcut from `iterable->list`; observable `@@iterator` lookup and
   the cached `next` method apply uniformly. Migrate synchronous `for-of` to lazy stepping. Only
   binding/body abrupt completion closes the iterator: failure in `next`, `done`, or `value` does
   not. An unlabelled continue stays inside the loop without closing, while break, return, throw,
   and control transfer to an outer label close exactly once.
3. Replace eager array-pattern materialization in declaration, parameter, catch, loop-head, and
   assignment binders. Empty patterns do not step. Elisions step without reading `value`. Ordinary
   elements step once, defaults run only for undefined, rest exhausts into a fresh Array, and a
   non-rest pattern closes an iterator left open by early pattern completion. Nested binding/default
   failure closes with the original throw taking precedence.
4. Keep object binding property-driven: ToObject once, computed keys in source order, Get before
   nested binding, and named evaluation for identifier defaults. Object-rest execution tests remain
   under the existing explicit `object-rest` skip and are not claimed by m3. Add anonymous
   function/arrow/class name inference at identifier defaults, parameter TDZ initialization before
   left-to-right binding, and the ECMAScript expected-argument-count rule for function `length`.
5. Migrate m3 iterable consumers that can fail after a value is produced: Array.from,
   Object.fromEntries, Map/Set/WeakMap/WeakSet constructors, and shipped Promise combinators. Each
   consumer processes one value at a time inside the shared close-on-abrupt boundary. TypedArray
   residual algorithms remain m9-owned; yield delegation and async-iterator expansion remain m5/m6,
   except that existing call sites may consume the shared record without claiming those later
   feature gaps.

Focused Lisp tests cover cached-next behavior, result validation, `done` transitions, close
precedence, lazy pattern/elision/rest behavior, nested/default abrupt completion, function-name
inference, parameter TDZ, function length, and loop control. The focused test262 gate classifies
every current m3 origin row and reports Phase-25b versus Phase-37 ownership separately; no expected
failure is hidden or converted to a skip. Because parser/emitter/shared execution semantics change,
the final gate includes parse conformance, a complete off/eager execution comparison, a monotonic
pass-list regeneration from the proven ledger, and fresh deterministic gap/report artifacts.

This is backward-compatible functionality within the already selected `0.1.0` release train.
Milestone 3 therefore retains the minor core and advances the immutable prerelease target to
`0.1.0-dev.2`; it does not create a new minor core merely because it is a later push.

#### 6.2.1 Milestone 3 completion evidence

The implementation follows the shared design above. A single completion-aware iterator record now
drives lazy array binding and assignment, synchronous `for-of`, observable iterable-to-list
conversion, Array and Object consumers, collection constructors, and shipped Promise combinators.
It caches `next`, records terminal completion, and centralizes close precedence. Binding execution
now handles empty patterns, elisions, ordinary elements, rest, defaults, nested abrupt completion,
prepared assignment references, parameter and catch TDZ, immutable `const`, expected function
length, and anonymous-default name inference. Array iterators use live length, arguments objects are
iterable, and the related String and Symbol protocol behavior is covered by the same implementation.

The focused frozen-origin slice is 1,497 files:

| Origin | Pass | Fail | Skip | Crash |
|---|---:|---:|---:|---:|
| `binding-patterns` | 1,368 | 44 | 0 | 0 |
| `iterator-protocol` | 74 | 11 | 0 | 0 |
| **Total** | **1,442** | **55** | **0** | **0** |

Exact residual diagnosis finds zero known m3-owned failures. The 55 remaining rows are assigned to
m4 functions/classes/parameters/`super` (28), m7 constructor/species protocol (4), m11 direct eval
and global environment (19), and Phase 37 proposals (4). The m3 implementation does not convert any
of them into skips.

Current-Script lexical visibility uses a deliberately transient boundary. While a Script executes
synchronously, its per-program lexical frame is the active Script ancestry used by eval. The frame
is restored on normal and abrupt completion and is not installed as persistent realm state. Async
callbacks and later Scripts therefore do not falsely inherit it; complete cross-Script and async
global-environment semantics remain m11 work. This bounded choice avoids claiming the static
compiler can already resolve lexicals introduced by later Scripts.

Two gate diagnoses corrected shared infrastructure rather than weakening evidence. The `yield*`
regressions came from an incorrectly declared Common Lisp optional supplied-argument marker in the
new iterator step path; correcting it restored both strict and sloppy controls while generator
residuals remain m5-owned. Runtime-negative execution rows now pass only when execution throws the
declared error type. The corrected runner exposed and removed three older frozen false positives;
those rows remain live m11/m13 failures. The resulting monotonic pass list contains 24,504 entries,
a net gain of 1,642 from m2 after the three corrections and 1,861 from phase entry.

The prior parser gate remains green at 23,713 total files: 17,523 live pass, 1,152 fail, 5,038 skip,
and zero crash, with all 17,512 frozen parse passes holding. The complete execution comparison is
byte-identical between off and eager across 40,654 files, with zero eager fallback:

| Classification | Count |
|---|---:|
| Pass | 24,504 |
| Fail/gap | 3,659 |
| Explicit skip | 12,491 |
| Crash | 0 |

Eligible remains 28,163. The exact rate is `24,504 / 28,163 = 87.007776%`, publicly truncated to
87.00%; 843 more passes are required to reach the fixed 25,347 target. The regenerated gap inventory
assigns 2,775 failures to Phase 25b and 884 to Phase 37, and its canonical artifact digest is
`1DF243B2047FC7F1`. M3 is a backward-compatible functionality unit in the existing `0.1.0` train,
so its disposition remains SemVer minor and its release target is `0.1.0-dev.2`. Milestone 4 is next
and has not started.
