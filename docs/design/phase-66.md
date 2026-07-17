# Phase 66 - Jest-compatible test-runner parity

Status: accepted for incremental execution under canonical issue #40. The compatibility row remains
`Partial` until every milestone and the complete four-target gate pass.

## Contract and provenance

Phase 66 raises the existing pure-Common-Lisp `clun test` implementation to the pinned Bun/Jest-compatible
surface. The engineering inventory is Bun commit `c1076ce95effb909bfe9f596919b5dba5567d550` and covers
`docs/test/`, `packages/bun-types/test.d.ts`, `src/runtime/test_runner/`, and `test/js/bun/test/`. Clun reads
those sources as behavioral references; it does not copy their implementation.

The complete phase still includes matcher and asymmetric-matcher parity, external and inline snapshots,
function/spies/module mocks, fake timers, coverage with TS/JSX source mapping, retries, concurrent tests and
parallel files, setup/preload hooks, reporters/JUnit, sharding/randomization, watch hooks, CLI filters,
isolation, deterministic output, and the frozen licensed compatibility manifest required by `PLAN.md`.

## Milestone 66.1 - function mocks and spies

The first implementation unit adds host-owned mock records keyed by the callable object. Each record belongs
to the current test file's `test-context`; it stores default and FIFO one-shot behavior, calls, results,
contexts, constructor instances, invocation order, a display name, and optional spy restoration data.

The JavaScript surface is:

- `mock(implementation?)`, `jest.fn`, and `vi.fn` (the same function object);
- `spyOn(object, property)`, `jest.spyOn`, and `vi.spyOn`;
- `.mock` call/result/context/instance/order history and `.getMockName()`;
- clear, reset, restore, implementation, one-shot, return, resolved/rejected, return-this, and temporary
  implementation methods;
- `jest`/`vi` clear-all, reset-all, and restore-all lifecycle operations;
- Bun/Jest call and return matcher families, including documented aliases.

Mocks are native engine functions, not JavaScript implementation fixtures. Invocation records a call before
dispatch, records either the returned value or thrown JavaScript value, preserves `this`, and gives one-shot
actions FIFO priority over the default action. Resolved/rejected values use the realm's intrinsic Promise
surface. Constructors retain their instance in `.mock.instances` and return an explicit object result when
the implementation supplies one.

Spies retain whether the property was originally own or inherited. Restore writes the original own value or
deletes the temporary shadow so the inherited value becomes visible again. Every file cleanup restores all
remaining spies, removes every host registry entry, and only then tears down the realm. This prevents mock
state and object replacement from crossing file boundaries.

## Evidence and residuals

Milestone evidence must execute through `build/clun test` and cover histories, FIFO/default behavior,
throws, async values, spies, lifecycle operations, aliases, constructor instances, and cross-file cleanup.
Focused Lisp tests may supplement but cannot replace shipped-binary evidence.

Completing this milestone does not authorize `Yes`. Module mocks, fake timers, snapshots, coverage,
asymmetric/custom matchers, retries, true concurrency, setup/reporters/sharding/watch integration, the full
pinned meta-corpus, four-target receipts, and stress/RSS gates remain required by issue #40.

## Milestone 66.2 - expected-failure modifiers

`test.failing` and its `it.failing` alias invert only failures produced by the test callback: a synchronous
throw, an assertion thrown from the callback, or a rejected returned Promise counts as the expected failure.
An unexpectedly successful callback is a failure with Bun's diagnostic telling the author to remove
`.failing`. Framework failures remain failures and are never hidden by the modifier: timeouts, hook errors,
and `expect.assertions` / `expect.hasAssertions` contract violations keep their normal failure result.

`test.failingIf(condition)` selects expected-failure behavior when the condition is truthy and normal test
behavior otherwise. `test.failing.each(table)` applies the same semantics independently to every generated
row. Unlike `test.todo`, an expected-failure test requires a callable second argument and rejects an invalid
registration immediately. Executable fixtures cover synchronous, asynchronous, conditional, parameterized,
unexpected-pass, timeout, hook, and assertion-contract paths.

## Milestone 66.3 - array parameterization and qualifier binding

Every test qualifier now belongs to a bound family rather than returning a bare registration function.
Selection mode (`normal`, `skip`, `only`, or `todo`) and expected-failure state are independent, so chains
such as `test.only.failing.each(table)` preserve both behaviors. A bound `test.each(table)` retains its rows
through `if`, `skipIf`, `todoIf`, `failingIf`, and direct skip/only/todo/failing qualifiers. Generated tests
retain per-test options and execute in deterministic table order.

`describe.each(table)` creates one real suite per scalar or tuple row, passes row values into the registration
callback, and supports the same selection and conditional suite qualifiers. A todo suite propagates its mode
to every descendant: it is inert by default and, under `--todo`, runs hooks/tests while applying todo result
inversion to each child. Name formatting covers `%s`, `%d`, `%i`, `%f`, `%j`, `%o`, `%p`, `%#`, and `%%`.

This milestone did not yet claim the entire parameterization category. Milestone 66.6 supplies callback
injection for generated rows; concurrent/serial qualifier state remains explicit residual scope.

## Milestone 66.4 - retry and repeat policies

Test options now accept mutually exclusive non-negative `retry` and `repeats` counts. A retry count permits
that many attempts after the initial run and stops at the first semantic success. `--retry N` supplies the
file-wide default, while an explicit per-test count, including zero, overrides it. A repeat count always runs
the initial attempt plus N more iterations and retains the first failure after completing every iteration.

Every attempt executes the full beforeEach/body/afterEach sequence and gets a fresh assertion-count contract.
For expected-failure tests, a callback throw/rejection is semantic success and therefore stops retries; runner
failures and unexpected callback success remain retryable. Todo execution does not retry. The shipped fixtures
cover hook counts, assertion-contract recovery, global and local policy precedence, failed middle repeats,
continued repetition, expected failures, and conflicting-option rejection.

## Milestone 66.5 - object-table title interpolation

Array parameterization now expands `$property`, nested `$property.path`, and `$#` row indices from object
rows. Primitive values use JavaScript string coercion while object values retain the runner's deterministic
inspection format; `$$` emits a literal dollar sign. The expansion happens at registration while the bound
table remains rooted by the host closure, matching the existing deterministic percent-directive path.

## Milestone 66.6 - callback-style completion

The runner detects callback-style tests by comparing the JavaScript function arity with the number of bound
parameterized row arguments. It appends a native `done(error?)` function, uses a host Promise capability as
the single scheduler completion value, and applies the same path to before/after hooks. A nullish callback
argument fulfills; any other value rejects. Duplicate calls are inert after the first result.

If the callback also returns a Promise, success requires both that Promise and `done()` to fulfill. A
returned-Promise rejection fails even when `done()` ran first, which prevents an async throw after `done()`
from becoming a false pass. A missing callback reaches the existing per-test timeout and remains a framework
failure that `test.failing` cannot invert. Focused shipped-binary fixtures cover synchronous and delayed
callbacks, all hook paths, callback errors, async rejection before and after `done()`, parameterized arity,
dual completion, and timeout classification.

## Milestone 66.7 - synchronous asymmetric matcher protocol

Deep loose equality recognizes any object with a callable `asymmetricMatch` method on either side of a
comparison. That protocol composes recursively through arrays, objects, `toMatchObject`, property values,
contain-equal, mock call/return histories, and thrown-error matching. Built-in factories provide `any`,
`anything`, `arrayContaining`, `objectContaining`, `stringContaining`, `stringMatching`, and `closeTo`, with
the documented negated factories on `expect.not`.

Constructor matching distinguishes the realm's real primitive constructors from user functions that merely
reuse their names, includes primitive wrappers, and preserves Bun's `expect.any(Object)` `typeof` behavior.
Object subsets require property presence (so missing is distinct from present `undefined`), read inherited
properties, and include symbol keys. String regular expressions reset state before each match, and close-to
handles infinities plus Bun's non-number negated boundary. Factory type errors occur at construction.

## Milestone 66.8 - custom matcher registration

Each test file owns a custom matcher registry in its test context. `expect.extend(definitions)` walks own and
non-Object prototype layers, validates every named value before registration, and installs the same callable
as a symmetric matcher and a static asymmetric factory. Later extensions replace earlier definitions,
including built-in names, without allowing registry state to cross a file-realm boundary.

Matcher calls receive `isNot`, `equals`, and deterministic `printReceived`, `printExpected`, `stringify`, and
color utility functions. Results may settle synchronously or through a Promise and must contain a `pass`
property; failure messages may be strings or functions, with a stable default when omitted. Prototype/class
methods, numeric property names, the empty name, thrown errors, rejected results, and nested asynchronous
asymmetric comparisons use that same protocol.

## Milestone 66.9 - Promise-settlement asymmetric matchers

Loose equality now propagates a boolean-or-Promise result while descending arrays and objects. The
`expect.resolvesTo` and `expect.rejectsTo` namespaces wrap each built-in or custom asymmetric matcher and
match only the requested settlement path. Their `expect.not` forms invert the complete settlement predicate,
so a non-Promise or opposite settlement matches the negated form without producing an unhandled rejection.
Timer-driven and nested Promises remain under the existing scheduler rather than introducing a nested loop.

## Milestone 66.10 - immutable upstream denominator

The Phase 66 denominator is frozen at 52 result roots from Bun commit `c1076ce95e`. The committed manifest
records every source path, category, and SHA-256 digest and validates against the pinned checkout with
`CLUN_BUN_SOURCE=... make test-test-runner-manifest`. Bun and Clun pass/fail/skip fields remain explicitly
`pending` until an exact reproducible run fills them; freezing paths is not evidence that either pass set has
already been measured.

## Milestone 66.11 - per-test completion cleanup

`onTestFinished(callback)` registers cleanup against the current test attempt. Callbacks run in registration
order after inherited `afterEach` hooks, including when the test body throws or rejects. Each retry and repeat
attempt owns a fresh callback list, so completion work cannot leak into the next attempt or test.

The callbacks use the existing hook settlement path: synchronous returns, Promises, and `done(error?)` are
supported, the test timeout remains authoritative, and all completion work settles before the next test
starts. Registration outside an active test and non-callable callbacks fail immediately. Real concurrent
test scheduling is still residual scope, so the pinned concurrent-registration diagnostic is not claimed.

## Milestone 66.12 - extended matcher family

The matcher engine now provides 27 additional Bun and Jest Extended contracts: nil/type/boolean/number/
integer/object/finite/positive/negative/symbol/function/date/string predicates; array and exact-size checks;
BigInt-aware even/odd checks; exact-boolean `toSatisfy`; half-open `toBeWithin`; ASCII-whitespace-insensitive
equality; substring, prefix, suffix, and non-overlapping repetition matching.

Argument validation follows the pinned behavior, including the finite-integer array-size boundary, the eight
valid `typeof` strings, numeric range endpoints, string-only expected values, non-empty repeated substrings,
and rejection of fractional, infinite, NaN, negative, and negative-zero repetition counts. Focused evidence
covers every matcher, negation, wrapper/date behavior, BigInt parity, validation failures, and 103 assertions.
The same milestone closes an asynchronous deep-equality traversal defect: its cycle map now tracks only the
active recursion path and remains live until Promise-backed asymmetric matching settles, so shared aliases do
not become false cycles. A dedicated nested-alias regression receipt covers that Promise cleanup boundary.

The row remains `Partial`. Snapshot/inline updates, module mocks, fake timers, coverage/source maps,
concurrency/parallel files, setup/reporters/JUnit, sharding/randomization/watch behavior, exact 52-root Bun
and Clun counts, four-target receipts, serial/parallel agreement, and the 10k-test RSS gate remain explicit
residuals.

## Milestone 66.13 - external and inline snapshot lifecycle

Each discovered test file owns one snapshot state. It loads the sibling
`__snapshots__/<test-file>.snap` Bun v1 format before executing the module, assigns external keys from the
describe path, test name, optional hint, and per-attempt ordinal, and defers every write until the file tree
finishes. Retry and repeat attempts reset their ordinals against an explicit active-test owner instead of
depending on dynamic execution scope. External writes use a temporary sibling and rename; inline writes
verify that the source has not changed since load and apply non-overlapping edits from the highest byte
offset downward.

The emitter attaches source spans to executing call expressions. Synchronous and Promise-settlement matcher
paths capture that span before asynchronous callbacks can unwind it, allowing missing or stale
`toMatchInlineSnapshot` arguments to be inserted or replaced at the owning call site. Existing snapshots
compare without touching either file. Missing snapshots are created in local mode, rejected under CI, and
created or replaced under `--update-snapshots` / `-u`; mismatches without update leave source and snapshot
files byte-identical. Property matcher objects are validated before snapshot state mutates.

Focused checked-script evidence drives the shipped binary through local creation, CI reuse, immutable
mismatch failure, CI creation denial, long and short update flags, external hints, synchronous and
`.resolves` inline edits, and property validation. The public row remains `Partial`: Clun currently uses
its deterministic inspector rather than Bun's exact pretty-format representation. At this milestone,
property matchers validated received values without yet substituting `Any<Type>` tokens into snapshots.

## Milestone 66.14 - stable snapshot property tokens

Snapshot property matchers now traverse the received object or array together with the property matcher
shape after validation. A matched asymmetric value is serialized with its stable matcher label, including
constructor-aware labels such as `Any<String>`, while unmatched fields retain their received values. Nested
property objects and arrays are handled structurally instead of by replacing text in an already rendered
snapshot, so equal-looking values in unrelated fields cannot be changed accidentally.

The checked lifecycle creates an external snapshot with a dynamic string property, verifies the stored
token rather than the runtime string, then reuses the snapshot with a different runtime value. The row
remains `Partial`: ordinary snapshots still use Clun's deterministic inspector, and Bun-exact formatting
across the complete supported-value corpus remains open.

## Milestone 66.15 - reproducible randomized execution

`clun test --randomize` now chooses and prints an unsigned 32-bit seed, while `--seed N` and `--seed=N`
imply randomization and reproduce the same run. Seed parsing rejects missing, non-decimal, negative, and
out-of-range values instead of silently falling back. File order uses Bun's pinned descending Fisher-Yates
reduction. Each test file derives independent state from the wrapping sum of its basename wyhash and the
printed seed, then every describe scope uses Bun's forward Fisher-Yates with Lemire's debiased range
reduction. The independent per-file state keeps a file reproducible when parallel scheduling arrives.

Checked shipped-binary evidence locks a pinned nested two-file order, both seed spellings, generated-seed
replay, distinct-seed order divergence, summary output, and validation failure. Randomization is therefore
no longer a Phase 66 residual. Sharding, watch integration, real concurrent/parallel scheduling, and the
other published blockers remain open, so the compatibility row remains `Partial`.

## Milestone 66.16 - dots and JUnit reporters

The test CLI now accepts `--dots`, `--reporter=dot`, and `--reporter=dots`, collapsing successful, skipped,
and todo results into a dot stream while retaining complete failure output and the ordinary summary. The
pinned `--reporter=junit` contract requires `--reporter-outfile` and leaves console output unchanged. JUnit
records retain file ownership, full test names, final-attempt assertion counts, pass/failure/skip/todo
status, CI and commit properties, aggregate/per-file metrics, and hostname metadata.

XML attribute content is escaped structurally, including hostile names, environment values, whitespace,
and invalid XML control characters. Reports use deterministic zero timing because Clun's public reporter
already omits unstable per-test timing, and they replace the target through the same sibling-temporary
atomic write boundary as snapshots. Checked shipped-binary evidence covers both reporter aliases, exact
console preservation, failure-path report creation, metrics, escaping, repeated overwrite, missing and
unsupported options, and unwritable destinations. Built-in reporter/JUnit scope is complete; custom
Inspector-protocol reporters remain outside this milestone, and the row remains `Partial` for the other
published blockers.

## Milestone 66.17 - deterministic file sharding

`clun test --shard INDEX/COUNT` and `--shard=INDEX/COUNT` now partition the sorted discovered file list by
zero-based ordinal modulo `COUNT`, with the public index expressed from one. Selection occurs after all
path/filter discovery and before seeded file shuffling, so shards are disjoint and exhaustive while every
individual shard remains reproducible under `--seed`. Strict decimal u32 parsing rejects zero, inverted,
overflowing, malformed, and multiply-delimited specifications before any test file loads.

Checked shipped-binary evidence freezes the exact membership of three shards over six files, proves their
union and non-overlap, covers both CLI spellings and argument order with randomization, and exercises the
invalid matrix. Sharding is therefore no longer a Phase 66 residual. Real parallel workers and their
serial/parallel agreement gate remain open, so the compatibility row remains `Partial`.

## Milestone 66.18 - per-realm module mocks

`mock.module(specifier, factory)` now installs a replacement module namespace in the current test-file
realm. Argument validation precedes resolution, so missing or non-callable factories cannot trigger package
lookup. Synchronous and Promise factories must fulfill with an object; throws, rejections, timeouts, and
primitive results remain ordinary test failures with stable diagnostics. `jest.mock` and `vi.mock` share the
same registration path, while `mock.restore()` restores function spies without removing module overrides.

Resolved import and require condition paths, builtin aliases, lexical relative paths, and unresolved bare or
relative specifiers map to the same realm-owned registry. Already-required CommonJS objects retain identity
while their enumerable surface changes in place. Existing ESM default and named binding thunks consult the
current replacement, namespace objects refresh, and re-export thunks remain live across repeated mocks.
Every test file still receives a fresh module registry, so neither replacement values nor synthetic missing
modules cross a file boundary.

Checked shipped-binary evidence covers 8 tests and 46 assertions across CommonJS, ESM, builtin, missing,
Promise, validation, replacement, restoration, and isolation paths. Module mocking is therefore no longer a
Phase 66 residual. Setup/preload, dynamic import in the core module engine, fake timers, coverage/source maps,
watch integration, real concurrent/parallel scheduling, and the remaining quantitative gates stay open, so
the compatibility row remains `Partial`.

## Milestone 66.19 - setup and preload lifecycle

`clun test` now accepts repeated `--preload`, `--require`, and `-r` module paths in separated or equals form.
The runner also reads `test.preload` and `[test] preload` from the working directory's `bunfig.toml`, accepting
a string or an ordered, multiline array of basic and literal strings. Configuration preloads execute before
CLI additions. Invalid values, duplicate declarations, missing arguments, and unresolved modules fail before
ordinary test execution with deterministic diagnostics.

Every setup module executes in each test file's fresh realm before the file module loads. This makes setup
globals, `expect.extend`, and `mock.module` replacements visible to imports without allowing state to leak to
the next file. Preload `beforeAll` and `afterAll` callbacks bracket the complete selected suite, while preload
`beforeEach` and `afterEach` callbacks wrap each file's own hooks in Bun order. Bail still runs the suite
teardown. The explicit preload phase rejects test and describe registration while continuing to allow global
lifecycle hooks.

Exact-output evidence covers two isolated file realms, two ordered CLI preloads, lifecycle placement, eight
assertions, custom matchers, mocked ESM imports, and fresh-realm state. Checked shipped-binary evidence adds
multiline and dotted-key bunfig forms, CLI aliases and config ordering, bail teardown, and the validation
matrix. Setup/preload is therefore no longer a Phase 66 residual. Dynamic import, fake timers,
coverage/source maps, watch integration, real concurrent/parallel scheduling, exact 52-root counts, target
receipts, serial/parallel agreement, and the quantitative RSS gate remain open, so the row stays `Partial`.

## Milestone 66.20 - realm-local fake timers

The `jest` and `vi` objects now expose the complete pinned Bun fake-timer control family:
`useFakeTimers`, `useRealTimers`, `advanceTimersToNextTimer`, `advanceTimersByTime`,
`runOnlyPendingTimers`, `runAllTimers`, `getTimerCount`, `clearAllTimers`, and `isFakeTimers`.
`jest.setSystemTime` and `jest.now` share the same realm clock. Activating fake time replaces only that
realm's timeout and interval globals, preserves callback arguments and Timeout ref/refresh behavior, and
restores the original functions at `useRealTimers` or unconditional file teardown.

The virtual queue orders entries by deadline and registration sequence. Interval callbacks reschedule before
dispatch so callback-side cancellation is observable; pending drains stop at the latest deadline present at
entry, while complete drains include nested timers and reject a 100,000-callback runaway. Virtual monotonic
time starts at zero, wall time starts at the host clock or an explicit Number/Date, and both `Date` construction
and `Date.now` advance with `performance.now` without replacing the Date constructor.

Exact shipped-binary evidence executes 10 tests and 58 assertions across three independently torn-down file
realms. It covers every control, sorted and nested timeouts, repeated intervals, pending and complete drains,
clearing, custom time, Date/performance callback observations, timer handles, argument forwarding, strict
errors, and cross-file isolation. Fake timers are therefore no longer a Phase 66 residual. Coverage/source
maps, watch integration, real concurrent/parallel scheduling, exact 52-root counts, complete snapshot
serialization, target receipts, serial/parallel agreement, and the quantitative RSS gate keep the row
`Partial`.

## Milestone 66.21 - Bun-specific snapshot value serialization

Snapshots no longer reuse the console inspector. A dedicated, cycle-aware formatter now emits pinned Bun
snapshot structure: string keys are quoted and sorted, non-empty arrays and objects are indented with trailing
commas, class instances retain their constructor label, and Map/Set preserve insertion order with their
snapshot-specific separators. Date, Error, Promise, RegExp, typed arrays, ArrayBuffer, DataView, boxed values,
weak collections, functions, BigInt, Symbol, and Buffer each use their Bun snapshot representation.

External snapshots add the Bun multiline boundary inside the template literal while inline comparison uses
the normalized value directly. This keeps create/update output exact without introducing blank lines into
inline matching. Existing property-matcher substitution still occurs at the owning structural path before
ordinary value serialization.

Exact shipped-binary evidence exercises 33 inline snapshots across six tests, including sorted nested
containers, circular references, signed typed-array values, empty and populated collections, numeric edge
values, and empty/populated Buffer output. The existing checked lifecycle also passes unchanged. Remaining
descriptor/accessor and pathological string/Unicode cases, coverage/source maps, watch integration, real
concurrent/parallel scheduling, exact 52-root counts, target receipts, serial/parallel agreement, and the 10k
RSS gate keep the public row `Partial`.
