# Phase 25b - Conformance Push to 90%

Status: **milestones 1 through 6 are complete and published; only the evidence-handoff Pages deployment remains before Phase 25b closes.**
Phase 25 is complete, so the dependency is satisfied. Milestone 4 delivered the function, class,
parameter, arguments-object, and `super` wave specified in section 6.3 while leaving diagnosed
generator, species, global-environment, operator, primitive, and Phase-37 residuals visible for
their later owners.

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
so its disposition remains SemVer minor. The original `v0.1.0-dev.2` tag passed master CI, but the
darwin-arm64 release builder exposed an inverted FD-bound test before any release assets were
published. The issue-59/60 correction was published as immutable prerelease `0.1.0-dev.3` without
changing the m3 conformance evidence. At the verified dev.3 handoff, milestone 4 became the queued,
unstarted milestone.

#### 6.2.2 Release-gate and loop-ownership correction

Parachute's `is` form is `(is comparator expected form)` and calls the comparator with the evaluated
form first. The socket lifetime gate wrote `(is <= delta 1)`, which therefore asserted `1 <= delta`:
darwin-arm64 correctly produced a zero descriptor delta and failed, while a larger leak could have
passed. The corrected gate snapshots descriptors outside the event-loop lifetime, filters the
enumeration descriptor by rechecking each numeric entry with `fstat`, and requires exact set equality
after 400 connection cycles and loop destruction.

That stronger gate also made the underlying issue-59 runtime defect explicit. The last client close
can request `loop-stop` before its accepted peer consumes EOF; `destroy-event-loop` previously removed
the peer's reactor handler without closing its SBCL socket, leaving a finalizer able to close a later
recycled descriptor. Event loops now admit synchronous cleanup ownership and handle activation for TCPs
and listeners atomically under the lifecycle lock. Normal close detaches reactor handlers before closing
the descriptor, then deactivates its handle and unregisters the ownership token only after the descriptor
is closed. Destruction rejects new resource/timer/worker/signal/handle admission, joins workers, clears
timers, removes signals, detaches all reactor handlers, closes every still-owned resource object, waits for
in-flight posters, discards accepted mailbox completions, and finally closes the self-pipe. Concurrent destroy
callers wait for the single teardown owner. A persistent reactor-thread owner survives `run-loop` return
because SBCL fd-handler tables are thread-local; off-owner close queues to it, while off-owner destruction
with live handlers fails without mutating lifecycle state. Terminal TCP/listener state is assigned after
affinity-sensitive removal and close so a rejected attempt remains retryable. Teardown suppresses user
close callbacks, remains idempotent, cancels timers, and releases in-flight worker handles through
serialized accounting without overwriting aggregate refcount state. The deterministic regression
forces full GC after recycling the listener, client, and accepted-peer descriptor numbers, calls
destruction a second time, and proves every replacement descriptor stays open. The adjacent
stale-handler regression also closes both ends of its raw test pipe. Issue #60 was the deterministic
dev.3 blocker and is closed after verified publication; issue #59 remains open for the Phase-26 Darwin
soak matrix. Active async `Clun.spawn`
resource ownership is tracked separately rather than expanding this correction.

Because the remote annotated dev.2 tag already establishes publication under the versioning
contract, the correction uses the next prerelease suffix, dev.3; the dev.2 tag remains immutable and
has no GitHub release or assets.

### 6.3 Milestone 4 implementation design

Milestone 4 owns functions, classes, parameters, `super`, and arguments. Its pre-implementation
frozen-origin credit slice was exactly 390 live Phase-25b failures from `exec-gaps.tsv`: 213
`functions-arguments` rows and 177 `classes` rows. The original 394-row planning pool had already
lost four rows to shared m3 work, so 394 was not reused as a current failure claim. Twelve then-current
rows in the same two work buckets were Phase-37 controls and remained visible but excluded from m4
credit. A further 28 m3-origin controls still failing at that handoff were diagnosed as m4 dependencies:
27 async function/arrow/method default-parameter rows and
`expressions/object/method-definition/generator-super-prop-param.js`. The focused diagnostic
workset is therefore 418 Phase-25b failures, while accounting remains disjoint under their frozen
origin buckets.

The failure inventory resolves to six shared semantic defects rather than path-specific gaps:

1. Every `super-node` currently throws an emitter-time `SyntaxError`, and only explicit class
   constructors receive a home object. This owns the complete `expressions/super` family and masks
   subclass, object-method, accessor, static-method, arrow-capture, and derived-constructor behavior.
2. User functions have one undifferentiated call/construct path. `jm-construct` always preallocates
   `this`, so class calls, derived uninitialized `this`, `super()` binding, repeated/missing `super`,
   and derived return override rules cannot be represented.
3. Parameter, body-var, body-lexical, and named-function/class bindings share one compile-time scope
   and runtime frame. Non-simple parameter scope, immutable inner names, and async parameter-rejection
   timing are consequently wrong.
4. Arguments are copied into an ordinary object. Sloppy simple-parameter mapping, duplicate-name
   selection, descriptor-driven map detachment, deletion, and strict `callee`/`caller` poison pills
   are absent.
5. Bound functions are anonymous native wrappers that are always constructable and always length
   zero. Function name/length/prototype inheritance, target validation, construction delegation,
   and OrdinaryHasInstance delegation are missing.
6. Function intrinsic metadata, method constructability/name assignment, AsyncFunction prototype
   identity, and callable `toString`/restricted-property behavior are incomplete.

The implementation uses the existing closure emitter, environment chain, and object internal-method
protocol; it does not add a second evaluator or Test262 branches:

1. Extend callable metadata with an explicit function kind and constructor kind. Ordinary functions
   retain normal call/base construction. Methods, arrows, generators, and async functions are never
   constructors. Base class constructors allocate before entry but reject ordinary calls. Derived
   class constructors enter with `this` uninitialized; `super()` constructs the active function's
   superclass with the current `new.target` and initializes `this` exactly once. An object return
   wins, undefined returns the initialized `this`, and every other primitive return throws.
2. Model the FunctionEnvironment state required by `this`, `new.target`, the active function, and
   home object in reserved lexical slots. Arrows inherit those slots; nested ordinary functions do
   not. Set the home object on every object-literal and class instance/static method and accessor.
   Compile SuperProperty as `[[Get]]`/`[[Set]]` on the home object's prototype with the actual `this`
   receiver. Compile SuperCall separately, preserving base/key/argument evaluation and abrupt order.
3. For a non-simple parameter list, compile defaults against a parameter scope parented to the
   closure environment, then execute body vars/functions and body lexicals in child frames. Simple
   parameters keep the shared var environment required by web-compatible semantics. Named function
   and class expressions receive a private immutable name environment. Async functions convert
   parameter-initialization failure into rejection instead of throwing before the Promise exists.
4. Add an arguments exotic behind the existing internal-method generics. Sloppy simple lists map
   only supplied indices selected by the last duplicate parameter name to frame cells. `[[Get]]`,
   `[[Set]]`, `[[GetOwnProperty]]`, `[[DefineOwnProperty]]`, and `[[Delete]]` keep mapped values in sync
   and sever mappings when required. Strict and non-simple lists are unmapped; their own `callee`
   uses the realm's shared `%ThrowTypeError%`, while `caller` is absent. Length and iterator
   descriptors retain the standard attributes.
5. Represent BoundFunction explicitly with target, bound `this`, and bound arguments. Validate the
   target at bind time, derive `name` and `length` observably, inherit the target function object's
   prototype, expose construction only when the target is a constructor, thread a distinct
   `new.target`, and delegate OrdinaryHasInstance to the target.
6. Centralize SetFunctionName for ordinary/computed/symbol method names and get/set prefixes. Correct
   Function.prototype metadata, restricted properties, non-generic `toString`, class constructor and
   prototype descriptors, extends validation, class evaluation order, and AsyncFunction constructor/
   prototype identity. Generators remain with m5, async generators/iteration with m6, species with
   m7, dynamic eval/`with` with m11, tagged templates with m13, AggregateError with m14, and private
   fields, coalescing/integer-separator syntax, WeakRef, and proposal-only APIs with Phase 37 unless a
   shared m4 operation is required by an owned row.

Implementation proceeds in that order because each later layer needs the callable and environment
state established before it. Focused Lisp regressions cover descriptors, method names and
nonconstructability, bound call/construct/instanceof behavior, parameter/body closure visibility,
mapped-arguments aliasing and detachment, strict poison accessors, super get/set/call evaluation
order, class heritage/name environments, every derived return category, repeated/missing `super`,
and async parameter rejection. The focused runner classifies all 418 owned diagnostic rows plus the
12 visible Phase-37 controls after each coherent layer; it does not regenerate the monotonic pass
list during implementation.

Completion requires zero focused crashes, preservation of every frozen pass, a fresh full ledger,
byte-identical off/eager classifications with zero eager fallback, parse conformance for parser or
early-error changes, monotonic pass-list regeneration only from the proven final ledger, and fresh
gap/report artifacts. The fixed denominator remains 28,163 and no skip rule changes. M4 adds
backward-compatible language behavior inside the already selected `0.1.0` minor train. Because
`v0.1.0-dev.3` was immutable and published, m4 selected exactly `0.1.0-dev.4` under
`v0.1.0-dev.4`.

#### 6.3.1 Milestone 4 local completion evidence

The implementation follows the shared-operation design rather than patching individual corpus rows.
Callable objects now distinguish ordinary functions, methods, arrows, base classes, and derived
classes, including callability, constructability, `new.target`, and derived `this` state. Reserved
FunctionEnvironment slots carry the active function, home object, `this`, and `new.target`; parameter,
body, and immutable name environments represent the required scope boundaries. Object and class
methods share the same home-object and `super` operations. Class evaluation covers heritage
validation, prototype wiring, default and explicit constructors, derived return overrides, and
pre-/repeated-/missing-`super()` behavior.

Arguments objects are a real object-model exotic. Simple sloppy lists map the last applicable
duplicate parameter through descriptor-aware cells; writes, definitions, and deletes synchronize or
detach the map as required. Strict and non-simple lists are unmapped, expose the poisoned `callee`
accessor, and do not synthesize a `caller` property. Bound functions retain their target, bound this,
and arguments, derive name and length, preserve target constructability, forward construction and
`new.target`, and re-enter the normal `instanceof` operation so a target's custom `@@hasInstance`
remains observable. Function, AsyncFunction, method, class, RegExp, and Symbol construction/metadata
paths use the same callable and naming operations. Source-text retention covers functions, methods,
accessors, static methods, classes, and dynamic async-family constructors without claiming the later
generator feature waves.

The final focused frozen workset contains 430 rows:

| Diagnostic group | Pass | Fail | Skip | Crash |
|---|---:|---:|---:|---:|
| `functions-arguments` | 169 | 44 | 0 | 0 |
| `classes` | 169 | 8 | 0 | 0 |
| m3-origin binding dependencies | 28 | 0 | 0 | 0 |
| Same-bucket Phase-37 controls | 0 | 12 | 0 | 0 |
| **Total** | **366** | **64** | **0** | **0** |

Conceptual diagnosis assigns those 64 failures to m7 species/constructor protocol (2), m11 direct
eval/`with`/global environments (46), m13 tagged templates (1), m14 AggregateError subclassing (2),
and Phase 37 (13), leaving **zero known m4-owned residuals**. The Phase-37 total includes the twelve
same-bucket controls plus an untagged Proxy heritage row. That row retains its frozen diagnostic
label but has an exact ownership override to Phase 37, so it is visible without being falsely
credited to m4.

Independent review and full-corpus regression diagnosis produced shared fixes, not exclusions:

1. An own `"use strict"` directive with non-simple parameters is an early error, and parameter/function
   names parsed before the directive are revalidated against strict binding-name rules.
2. `delete super[key]` first resolves `this`, then evaluates the computed key without applying
   `ToPropertyKey`, and finally throws `ReferenceError`.
3. The Annex-B `Object.prototype.__proto__` setter throws when immutable `[[SetPrototypeOf]]` returns
   false, while same-prototype requests remain successful.
4. Bound OrdinaryHasInstance re-enters `InstanceofOperator`, preserving a target's custom
   `@@hasInstance`; bound native-source fallback is valid anonymous NativeFunction syntax.
5. Static-method source spans exclude the `static` prefix and intervening comments while retaining
   `async`, `get`, `set`, and generator markers. Explicit class constructors stringify as the whole
   class, AsyncGeneratorFunction retains its correct intrinsic/dynamic source, and
   `Object.prototype` uses the immutable-prototype exotic.
6. The final documentation review corrected the unmapped-arguments contract: `callee` is poisoned;
   `caller` is absent rather than another poison accessor.
7. Final adversarial review found the source backend omitted exact source text for nested block and
   switch function declarations. Both eager-emitter call sites now pass the declaration source span,
   and focused off/eager regressions cover both paths.

Two apparent review findings were rejected after checking the normative behavior and Test262
assertions. An implicit/default class constructor may use the accepted native-function source
fallback. Generator and async-generator parameter initialization occurs synchronously at call time,
not when `.next()` first resumes the body. Neither path was changed merely to satisfy a mistaken
expectation.

The final execution comparison is byte-identical between default and eager modes across all 40,654
files, with zero crashes and zero eager fallback. Eager mode compiled 1,020,917 forms and classified
54,315 as ineligible:

| Classification | Count |
|---|---:|
| Pass | 25,008 |
| Fail/gap | 3,155 |
| Explicit skip | 12,491 |
| Crash | 0 |

Eligible remains 28,163. The exact rate is `25,008 / 28,163 = 88.797358%`, publicly truncated to
88.79%; 339 passes remain to the fixed 25,347 target. The monotonic pass list contains 25,008 rows,
up 504 from m3 and 2,365 from phase entry. The regenerated inventory assigns 2,270 gaps to Phase 25b
and 885 to Phase 37 and has canonical digest `B77552A66955B6C3`.

The parser gate is 23,713 total files: 17,688 live pass, 987 fail, 5,038 skip, and zero crash, with all
17,512 frozen parser passes holding. `make test-lisp` passes 3,120 assertions with zero failures.
These were the final local candidate results. The full local acceptance stack, including the post-review
40,654-file off/eager comparison and four-viewport Playwright audit, was green before publication. The
release-bearing unit is SemVer minor within the existing train and selected `0.1.0-dev.4` under
`v0.1.0-dev.4`.

#### 6.3.2 Milestone 4 publication evidence

Candidate `486e0d8f15a0dca374b1e42bda7f5431a0cca31f` passed CI run `29471177997` and Documentation
run `29471177983`. The annotated `v0.1.0-dev.4` tag then passed release run `29471399138`: linux-x64,
linux-arm64, darwin-x64, and darwin-arm64 all built and verified, and the published prerelease contains
the four native archives plus `checksums.txt`. A fresh independent download passed `sha256sum -c` for
all four archives.

Pages run `29471177985` waited for those matching assets and deployed the site and installer. The hosted
landing page and `https://clun.sh/install` expose dev.4, and an isolated execution of
`curl -fsSL https://clun.sh/install | sh` installed a binary reporting `clun 0.1.0-dev.4`. This
post-publication synchronization changes only evidence and milestone status, so its SemVer impact is
`none`; source version, installer target, artifacts, behavior, and compatibility claims remain unchanged.
Milestone 5 is current. Phase 25b stays open because 88.797358% is below the fixed 90% gate.

### 6.4 Milestone 5 synchronous-generator design

Milestone 5 starts from the immutable dev.4 execution inventory rather than the original 108-row
planning estimate. Its frozen diagnostic set contains **56 failures: 0 pass / 56 fail / 0 skip /
0 crash**. The set is the 53 current `generators` bucket rows plus three generator-specific
binding-pattern dependencies. The single mixed `expressions/await/for-await-of-interleaved.js`
row is intentionally absent because its primary work bucket and semantics are async iteration,
owned by m6.

Conceptual ownership is independent of the frozen origin bucket:

| Owner and root cause | Rows | Milestone-5 disposition |
|---|---:|---|
| m5 synchronous `GeneratorFunction` intrinsic, dynamic construction, prototypes, and subclassing | 31 | pass |
| m5 generator-method own `.prototype` | 1 | pass |
| m5 contextual `yield` grammar and `yield *` newline handling | 7 | pass |
| m5 raw `yield*` iterator-result forwarding | 4 | pass |
| m11 direct eval, `with`, and global-environment semantics | 12 | retain as visible failures |
| Phase 37 `Math.sumPrecise` iterable control | 1 | retain as a visible failure |
| **Total** | **56** | **43 m5-owned / 13 controls** |

The two `GeneratorFunction` subclass rows are m5-owned. They directly specify the required
`GeneratorFunction` constructor and its `new.target`-derived function prototype; they use the class
and derived-construction machinery already completed in m4 and do not require the generic species or
constructor-result work assigned to m7. M5 does not expand that shared protocol beyond the new
generator intrinsic.

The 12 m11 controls are the three generator-specific `eval-var-scope-syntax-err` dependencies plus
nine generator-origin rows covering direct-eval lexical conflicts, strict named-function mutation,
`Symbol.unscopables`, and `with`. Clun's direct eval and dynamic scope remain intentionally incomplete
until m11; these rows stay failures and are never converted to skips. The Phase-37 Math control also
stays a failure in the fixed denominator.

#### 6.4.1 Reference behavior and root causes

The pinned Bun engineering tree remains `c1076ce95effb909bfe9f596919b5dba5567d550`, which pins its
JavaScriptCore dependency at `c9ad5813fd23bd8b98b0738abc3d037ec716aa92` in
`scripts/build/deps/webkit.ts`. Bun delegates runtime intrinsic and resumption semantics to
JavaScriptCore, while Bun's Rust parser handles the syntax. The pinned JSC reference graph and resume
behavior are defined by
`Source/JavaScriptCore/runtime/GeneratorFunctionConstructor.cpp`,
`GeneratorFunctionPrototype.cpp`, `GeneratorPrototype.cpp`, and `JSGlobalObject.cpp`, with generator
resumption in `Source/JavaScriptCore/builtins/GeneratorPrototype.js` and compilation in
`Source/JavaScriptCore/bytecompiler/BytecodeGenerator.cpp`. Bun's
`src/js_parser/parse/mod.rs::parse_yield_expr` directly preserves the no-line-terminator rule before
the delegation star while parsing the expression after it. Bun's `test/cli/run/syntax.test.ts`
provides public runtime smoke for generator syntax, `yield`, `yield*`,
try/finally, prototypes, for-of, dynamic functions, and generator methods. These references define
observable behavior only; Clun implements it independently in GPL-3.0-or-later Common Lisp.

The current failures reduce to four shared defects:

1. `src/engine/async/generator.lisp` creates only `%GeneratorPrototype%`. It omits the callable and
   constructable `%GeneratorFunction%` constructor, the ordinary non-callable
   `%GeneratorFunction.prototype%`, their descriptors and tags, and
   `%GeneratorPrototype%.constructor`. `instantiate-function` consequently gives synchronous
   generator functions `%Function.prototype%`, so reflection, dynamic construction, default
   prototypes, source text, and subclassing all observe the wrong graph.
2. Generator methods have semantic function kind `:generator` but syntactic kind `:method`.
   `instantiate-function` keys own `.prototype` creation from the latter, so object and class
   generator methods incorrectly omit their required fresh prototype object.
3. `parse-yield` applies ordinary-yield line-termination after consuming `*`, rejecting the legal
   `yield *\n expression` form. `parse-function` also parses a nested ordinary function expression's
   name under the enclosing generator's `Yield` context, rejecting sloppy `(function yield(){})`.
4. `%yield-delegate` extracts `IteratorValue` from every incomplete inner result and
   `%generator-step` synthesizes a new `{ value, done: false }` object. The language requires the
   validated inner result object itself to be forwarded while incomplete, without normalizing its
   `done` property or touching its `value` getter. Delegated `throw` and `return` also use raw
   property reads instead of `GetMethod`, conflating missing and non-callable methods and risking
   incorrect iterator-close precedence.

#### 6.4.2 Implementation shape

M5 adds one synchronous intrinsic family modeled on Clun's existing async-generator bootstrap, not a
second evaluator. `%GeneratorFunction%` uses `dynamic-function-source` in generator mode for both
call and construct, honors `new.target` through `nt-prototype`, and creates nonconstructable generator
function instances. `%GeneratorFunction.prototype%` is an ordinary non-callable object inheriting
`%Function.prototype%`; it exposes the exact non-writable `constructor`, `prototype`, and
`@@toStringTag` descriptors. `%GeneratorPrototype%` inherits `%IteratorPrototype%` and points its
`constructor` at `%GeneratorFunction.prototype%`. Synchronous generator declarations, expressions,
and methods inherit the function-prototype intrinsic and receive fresh own `.prototype` objects
inheriting `%GeneratorPrototype%`, while remaining nonconstructable.

Parser changes are grammar-context changes only. After recognizing an unseparated `yield *`, the
delegated AssignmentExpression is parsed even when its first token follows a line terminator. An
ordinary script function expression name is parsed with `Yield` and `Await` disabled for that binding
while module `Await` and strict reserved-word checks remain active; generator-expression names and
generator parameters keep their existing rejection rules.

Delegation gains a distinct coroutine output kind for an already-formed iterator result. Ordinary
`yield` remains `:yield` and is wrapped once; incomplete `yield*` results use the new kind and are
returned verbatim by the synchronous generator driver. Completion still reads `value` exactly once
after `done` becomes true. `%GeneratorPrototype%` inherits the exact `@@iterator` method from
`%IteratorPrototype%` without an observable own property. Delegated `throw` and `return` use the
shared `get-method` operation:
missing `throw` performs iterator close with a normal completion and throws the protocol `TypeError`
only after that close succeeds; an abrupt `return` getter/call or non-object close result propagates
instead. Non-callable methods throw immediately, and missing `return` propagates the outer return.
The existing explicit-`undefined` first `next` argument is preserved because generator delegation
intentionally calls inner `next` with one argument.

The emitter selects the raw result kind only for synchronous generators; async delegation retains
its existing value path. Async-generator delegation, awaiting, request queues, and async iteration
remain m6 and receive no m5 compatibility credit.
Cross-realm dynamic-generator construction also remains outside m5: Test262's `cross-realm` feature is
still skipped until callable objects carry their defining realm explicitly.

#### 6.4.3 Verification and release contract

Focused Lisp regressions cover the complete intrinsic graph and descriptors, dynamic call/construct,
source text, nonconstructable instances, `new.target` subclassing, declaration/expression/method
prototype relationships, default-prototype fallback, contextual `yield` positives and negatives,
all four newline forms, raw delegated result identity and access order for next/return/throw, missing
and non-callable delegated methods, close precedence, and existing try/finally behavior. The exact
56-row entry set is a tracked fail-closed gate; the complete frozen execution pass list runs
in the final full-corpus comparison so formerly passing GeneratorFunction, GeneratorPrototype, and
`yield*` behavior cannot regress.

M5 acceptance requires all **43 owned rows** to pass with zero crash while all 13 later-owner controls
remain visible and separately reported. Final verification then runs the complete parse corpus, fresh
default/eager 40,654-file execution comparison with zero fallback, frozen-pass preservation,
monotonic pass-list regeneration from the proven ledger, deterministic bucket artifacts, build/test/
purity, TLS and crypto, public claims, roadmap/live issue, installer/release, SemVer, shell/workflow,
and responsive-site gates. No denominator or skip rule changes.

This is backward-compatible functionality within the existing `0.1.0` minor train. Because dev.4 was
already immutable and published, the release-bearing unit selected source/release
`0.1.0-dev.5` and tag `v0.1.0-dev.5`. Publication is verified below.

#### 6.4.4 Completion and publication evidence

The tracked `tests/conformance/phase-25b-m5.tsv` manifest and `make phase-25b-m5-check` make the exact
entry boundary reproducible after global gap regeneration. The final gate reports **43 m5 pass / 12 m11
fail / 1 Phase-37 fail / 0 skip / 0 timeout / 0 crash**. All 31 intrinsic rows, the generator-method
prototype row, seven grammar rows, and four delegation rows pass; no control changed classification.

Independent review caught and corrected four shared-edge defects before evidence generation: raw delegated
results are routed only to synchronous generators while async generators retain their value path; module
code keeps `await` reserved in nested function-expression names; `%GeneratorPrototype%` inherits rather
than owns `@@iterator`; and teardown boundedly resumes or terminates a delegated generator whose inner
`return()` yields an incomplete result. Cross-realm dynamic construction remains an explicit skipped
architecture dependency, not an m5 claim.

The final off/eager execution ledgers are byte-identical across 40,654 files at **25,051 pass / 3,112 fail /
12,491 skip / 0 crash**. Eager mode compiled 1,021,895 forms, marked 54,494 ineligible, and recorded zero
fallback. Eligible remains 28,163; the exact rate is 88.950041% (public 88.95%), leaving 296 passes to the
25,347 target. The pass list grows monotonically by 43 to 25,051; residual ownership is 2,227 Phase-25b
and 885 Phase-37; canonical ledger digest `C104919DBAF109E4` binds the regenerated artifacts. Parse
conformance is 17,699 pass / 976 fail / 5,038 skip / 0 crash with all 17,512 frozen passes holding, and the
Common Lisp suite is 3,187 / 0.

Implementation commit `f814751b1afc30a58abea43d41ef3194b8dfe36c` passed CI `29476921973` and
Documentation `29476922006`. Annotated tag object `d24ec46602aee277f7226d0ae344f4a93964b604`
names `v0.1.0-dev.5` and targets that exact commit. Release run `29477285549` attempt 2 passed linux-x64,
linux-arm64, darwin-x64, and darwin-arm64 after attempt 1's linux-arm64 APT network failure. The published
archives independently match `checksums.txt`:

| Archive | SHA-256 |
|---|---|
| `clun-darwin-arm64.tar.gz` | `5e92df28e3f50690d13235f78b51dca6080a90b4d313197e02f8a35a730660b1` |
| `clun-darwin-x64.tar.gz` | `76f7f6719aa46abaf6d6bc8556be4ce50d6742d1d628b0766d7ca7c9a0d09fc8` |
| `clun-linux-arm64.tar.gz` | `befd73397fe749638f8d2e7cba67927220e0e4bffd29acc5f40231e539c6bbbd` |
| `clun-linux-x64.tar.gz` | `a1dbff991b9a2d9bdaf0be865f12ac96d004f3c029870ab23dd9d7c0330a3705` |

Pages run `29476921956` completed after the release and deployed the dev.5 candidate-status page plus the
release-gated installer. An isolated execution of `curl -fsSL https://clun.sh/install | sh` installed a
binary reporting `clun 0.1.0-dev.5`. Evidence-only handoff commit
`d3e114749655738ecbfbec21419d4dc0e5276614` then passed Pages run `29479561951`; the hosted page reports
dev.5 published and m6 current without candidate wording. The handoff changes evidence and milestone status
only, so its SemVer impact is `none`, source remains dev.5, and no tag is created. M5 is complete. Phase 25b
was still open at 88.950041%, 296 passes short of its fixed target at that handoff. M6 has since shipped
dev.6 above the fixed target; its publication evidence is recorded below.

### 6.5 Milestone 6 async-generator and async-iteration design

Milestone 6 starts from the immutable dev.5 inventory after the published-status handoff. The frozen
selection is every `exec-gaps.tsv` row whose work bucket is `async-iteration` or `async-generators`.
Bucket precedence currently labels every selected row `async-iteration`, including the async-generator
rows; ownership is therefore recorded separately and cannot be inferred from that one label. The sorted,
unique selection contains **509 rows: 0 pass / 509 fail / 0 skip / 0 timeout / 0 crash** at entry.

Conceptual ownership is exact and disjoint:

| Owner and first failing semantic operation | Rows | Milestone-6 disposition |
|---|---:|---|
| m6 async-generator `yield*` delegation | 328 | pass |
| m6 yielded-value awaiting and rejection injection | 47 | pass |
| m6 AsyncFromSync iterator wrapping | 9 | pass |
| m6 `for await` ordering and AsyncIteratorClose | 6 | pass |
| m6 FIFO request queue | 6 | pass |
| m6 invalid-receiver promise rejection | 6 | pass |
| m6 `.return()` value awaiting | 5 | pass |
| m11 direct eval and `with`/unscopables controls | 7 | retain as visible failures |
| Phase 37 `Array.fromAsync` controls | 95 | retain as visible failures |
| **Total** | **509** | **407 m6-owned / 102 controls** |

The 328/47 language split is reproducible rather than count-fitted. A selected async-generator path
containing `yield-star` enters delegation, except the 16
`yield-promise-reject-next-yield-star-*` rows: those first require an ordinary yielded rejection to be
awaited and injected, and use delegation only as the continuation that proves the result. All other
selected async-generator language rows enter the yield-await group. Seven exact direct-eval and
`Symbol.unscopables` paths remain m11 controls. The complete `built-ins/Array/fromAsync/**` subtree
remains Phase 37 even though it uses the same iterator plumbing.

The focused implementation closes all 407 owned rows without changing the skip set. The confirmed
default/off corpus additionally gains three Promise `finally` rows, producing **25,461 / 28,163 =
90.405852%**, 114 passes above the fixed 25,347 target. The monotonic pass-list gain is +410 from m5
and +2,818 from the frozen 22,643-row Phase-25b entry list.

#### 6.5.1 Pinned reference architecture and dev.5 root causes

The reference boundary remains Bun `c1076ce95effb909bfe9f596919b5dba5567d550`, whose
`scripts/build/deps/webkit.ts` pins JavaScriptCore/WebKit
`c9ad5813fd23bd8b98b0738abc3d037ec716aa92`. Bun's `test/cli/run/syntax.test.ts` and
`test/regression/issue/014187.test.ts` provide only public syntax/resumption smoke; Bun delegates the
runtime semantics to JSC. At the pinned JSC revision,
`Source/JavaScriptCore/runtime/JSAsyncGenerator.h/.cpp` stores explicit generator state and a FIFO of
value/mode/promise requests; `Source/JavaScriptCore/builtins/AsyncGeneratorPrototype.js` enqueues requests,
resumes only a resumable generator, and drains completion through promise jobs in
`Source/JavaScriptCore/runtime/JSMicrotask.cpp`.
`Source/JavaScriptCore/builtins/AsyncFromSyncIteratorPrototype.js` and
`Source/JavaScriptCore/runtime/JSAsyncFromSyncIterator.h` define the sync-wrapper boundary.
`Source/JavaScriptCore/bytecompiler/BytecodeGenerator.cpp` prefers `@@asyncIterator` for async consumption,
falls back to that wrapper, and emits the `for await` close path. Shared iterator operations remain in
`Source/JavaScriptCore/runtime/IteratorOperations.h/.cpp`. Clun adopts that state/queue/wrapper scheme only;
it does not copy JSC source, storage layout, built-in code, or Bun parser code. The implementation is
independent GPL-3.0-or-later Common Lisp and is judged by observable Test262 behavior.

The immutable dev.5 implementation has four shared defects:

1. `js-async-generator` stores only a coroutine and a `done` bit. `%async-gen-step` immediately drives
   each call, so concurrent `next`/`return`/`throw` requests can resume an executing coroutine and have no
   per-request promise capability or FIFO settlement order. `this-async-generator` throws before a
   promise exists, so invalid receivers escape synchronously instead of returning rejected promises.
2. `%async-gen-drive` resolves a yielded iterator-result immediately and marks return/throw completion
   directly. It does not adopt ordinary yielded values before exposing them, inject rejected yields at the
   suspended expression, await `.return()` values in start/yield/completed states, or drain queued requests
   after completion.
3. `get-iterator` represents async-from-sync as a boolean beside the original synchronous iterator record.
   It has no wrapper object with promise-returning `next`/`return`/`throw`, so wrapper identity, poisoned
   result access, rejection, missing-method, and close precedence cannot be expressed once and reused.
4. Async `yield*` asks for an ordinary iterator and suspends on a raw inner value without awaiting the
   inner result promise or applying async-generator resumption rules. `for await` separately awaits and
   performs best-effort cleanup under `ignore-errors`; it does not implement completion-aware
   AsyncIteratorClose, including awaited return results and the distinct throw/non-throw precedence.

#### 6.5.2 Implementation shape

Clun keeps the existing thread-backed coroutine as the single body evaluator. `js-async-generator` gains
an explicit state (`suspended-start`, `executing`, `awaiting`, `suspended-yield`, or `completed`) and a FIFO
of request records holding resume kind, value, and promise capability. Each prototype method allocates its
promise before validating the receiver, rejects that promise for an incompatible receiver, enqueues a
valid request, and starts the driver only from a resumable state. Exactly one driver transition owns the
coroutine at a time. Completion settles and removes the head request, then drains completed-state requests
without re-entering the coroutine.

Ordinary async-generator `yield` first adopts its operand. Fulfillment exposes `{ value, done: false }` for
the head request and suspends; rejection resumes the body as `throw` at the yield expression. Resumption
values are adopted at the grammar-required points. `.return(value)` awaits `value` before closing a
suspended-start or completed generator and before injecting return at suspended-yield; a rejected value
rejects that request without corrupting the remaining queue. Body return and throw complete the generator
once and drain all pending requests with the required completed-state results.

One async iterator record owns iterator object, cached next method, and whether it is native async or an
AsyncFromSync wrapper. Selection performs `GetMethod(@@asyncIterator)` first and falls back only when it is
absent. The wrapper's `next`, `return`, and `throw` always return promises, validate object results, adopt
their `value`, preserve argument presence, and implement missing-throw close before protocol rejection.
Async `yield*` uses this same record, awaits each method result, validates it, forwards incomplete results
through AsyncGeneratorYield, and preserves `GetMethod`, missing-method, and close precedence for normal,
throw, and return resumptions.

`for await` also uses the shared async record. Each loop step awaits `next()`, validates the result, then
binds the value in job order. Abrupt exit calls and awaits `return()` when present and requires its result
to be an object. For a non-throw completion, a close getter/call/rejection/non-object failure replaces the
pending completion; for a throw completion, the original throw is preserved after attempting close. No
cleanup path uses blanket error suppression.

#### 6.5.3 Verification and release contract

The tracked `tests/conformance/phase-25b-m6.tsv` manifest freezes all 509 paths, entry labels, conceptual
owners, root causes, and required final classifications. Path-list FNV-1a-64
`D9A872B337562D21` binds the exact sorted selection. `make phase-25b-m6-check` is the final gate;
`CLUN_PHASE_25B_M6_MODE=entry make phase-25b-m6-check` reproduces the all-fail dev.5 entry boundary. The
runner rejects malformed, unsorted, duplicate, missing, remapped, count-shifted, or path-digest-shifted
manifests before executing a test.

The focused m6 gate passes exactly **407 m6 pass / 7 m11 fail / 95 Phase-37 fail / 0 skip /
0 timeout / 0 crash**.
Focused regressions must additionally cover overlapping requests, completed-state next/return/throw,
promise-first brand rejection, yielded and returned thenables, rejection injection, AsyncFromSync argument
presence and poisoned results, async `yield*` method/close precedence, and `for await` ordering and abrupt
close. Review-driven regressions specifically bind synchronous PromiseResolve setup abrupts and the second
Await when native-async `yield*` receives a completed delegated `return` or `throw`.
The suspended-start `return`/`throw` path completes and unregisters its underlying coroutine without
spawning a thread; regressions cover return, throw, repetition, completed-state behavior, and nil-thread
cleanup.

The confirmed default/off 40,654-path ledger is **25,461 pass / 2,702 fail / 12,491 skip / 0 crash**.
Eligible remains **28,163**, the exact rate is **90.405852%**, and residual ownership is **1,817
Phase-25b / 885 Phase 37**. All 25,051 dev.5 passes remain. The three incidental passes beyond the 407
owned rows are `built-ins/Promise/prototype/finally/species-constructor.js`,
`built-ins/Promise/prototype/finally/subclass-reject-count.js`, and
`built-ins/Promise/prototype/finally/subclass-resolve-count.js`. The base PromiseResolve correction required
by async generators exposed `Promise.prototype.finally`'s species-constructor bug; the implementation now
also preserves its specified job order and object handling, with focused coverage.

The full default/off and eager ledgers are byte-identical across all 40,654 paths. Eager mode compiled
**1,030,545** forms, classified **56,018** as ineligible, and fell back **0** times. The regenerated
monotonic pass list contains **25,461** paths, **+410** from m5; canonical digest
`A742D885346DA23C` binds the exact residual artifacts. Parse conformance is green at **23,713 total /
17,699 pass / 976 fail / 5,038 skip / 0 crash**, with every frozen parser pass preserved. The integrated
Lisp gate is green at **3,234 pass / 0 fail / 0 skip**. The build, full-test, purity, security,
public-claim, roadmap, installer, conformance, visual, committed-range SemVer, exact `master` CI and
Documentation, release-asset, Pages, and hosted-installer gates are green.

This is backward-compatible functionality in the existing `0.1.0` minor train. Dev.5 is immutable, so m6
selected source/release `0.1.0-dev.6` and tag `v0.1.0-dev.6`.

#### 6.5.4 Publication evidence

Candidate commit `4d2b714c1a459264ca9e77f5f25979bb41b50c76` passed CI `29488866153` and
Documentation `29488866083`. Annotated tag `v0.1.0-dev.6` peels to that exact commit. Release run
`29489277258` passed all four native builders and published dev.6 as a prerelease. Fresh downloads matched
`checksums.txt`:

| Archive | SHA-256 |
|---|---|
| `clun-darwin-arm64.tar.gz` | `1df087c75a9b335172371196a3553ab568cd85ff0b89921e35c98b467e137f1d` |
| `clun-darwin-x64.tar.gz` | `8588ee870948ad1de7fd3c3a86e66de58a3e00945897a90a4ad06e83fa978ffc` |
| `clun-linux-arm64.tar.gz` | `4eaa6c94f1364f7a07318d52e80e01dc538cbdc489e993353049c195401f5a31` |
| `clun-linux-x64.tar.gz` | `243dfc96bd5a163707c982bfe61d6054a784fe9bbd52bb72b6436d4ba9774935` |

Pages run `29488866091` succeeded for the exact candidate after release assets existed. An isolated
`curl -fsSL https://clun.sh/install | sh` installation reported `clun 0.1.0-dev.6`. Phase 25b runtime and
release scope is complete. This evidence-only handoff has SemVer impact `none`; source and installer remain
dev.6 and no new tag is created. Only this handoff commit's own Pages deployment must be verified in issue
#57 before Phase 25b closes and Phase 27 begins. Phase 26 is deferred until after Phase 82 and will be
re-baselined for the then-current system.
