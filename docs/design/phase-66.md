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

The row remains `Partial`. Snapshot/inline updates, module mocks, fake timers, coverage/source maps,
concurrency/parallel files, setup/reporters/JUnit, sharding/randomization/watch behavior, exact 52-root Bun
and Clun counts, four-target receipts, serial/parallel agreement, and the 10k-test RSS gate remain explicit
residuals.
