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
