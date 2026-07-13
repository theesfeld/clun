# Phase 14 — Async product wave

Objective (§5): the async floor the test runner and servers stand on — timers globals with real
ref/unref loop accounting, `node:timers` + `node:timers/promises`, `process.nextTick` wiring,
`events.once` + captureRejections, `assert.rejects`/`doesNotReject`, `Clun.sleep`/`sleepSync`,
`queueMicrotask`, and `AbortController`/`AbortSignal`. **Gate:** an ordering corpus (nextTick vs
microtask vs timer vs immediate) with exact output; an unref'd-timer process-exit test; abort fixtures.

Most of the substrate already exists (Phases 05/06/08/12). This phase is wiring + two new primitives
(the enriched Timer object and AbortSignal), grounded in the current source.

## 1. What already exists (do not rebuild)

- **Loop** (`src/loop/`): three JS queues — `next-tick`, `microtasks`, `tasks` — plus a binary-heap
  timer queue and handle refcounting. `drain-microtasks` drains nextTick FULLY, then one microtask,
  repeat (Node semantics). Per-iteration order (`run-loop`): poll → completions → signals →
  `expire-due-timers` → `process-tasks`, each callback at a dispatch point that drains microtasks.
  `loop-alive-p` = ref-count>0 ∨ immediate-work; an unref'd handle does not keep it alive.
- **Engine async globals** (`promise.lisp` `%bootstrap-async-globals`, run per realm): `Promise`,
  `queueMicrotask`, `setTimeout`/`setInterval` (returning an opaque Timer id boxing the CL timer),
  `clearTimeout`/`clearInterval`, and a stub `process` with `nextTick` (dedicated pre-microtask queue).
- **process** (`process.lisp`) augments that same object (nextTick survives). **Clun.sleep/sleepSync**
  (`clun-global.lisp`) already work. **events** static `once` returns a Promise. **assert** has the
  throws family but no async variants.

## 2. Ordering model (the gate's core)

The relationships Clun guarantees, matching Node where Node guarantees them:

1. sync code → `process.nextTick` callbacks (all of them) → Promise/`queueMicrotask` microtasks (FIFO
   in registration order) → macro phases. nextTick drains fully between each microtask.
2. Within a loop iteration, **timers fire before immediates** (`expire-due-timers` precedes
   `process-tasks`). Node does NOT guarantee the top-level `setTimeout(0)` vs `setImmediate` order;
   Clun makes it deterministic (timer first). **Documented divergence** — the corpus asserts Clun's
   order and DECISIONS records that Node leaves it unspecified.
3. `setImmediate` maps to the `tasks` queue; `process-tasks` snapshots its count, so an immediate that
   schedules another immediate defers to the next iteration (Node's check-phase semantics). A pending
   immediate keeps the loop alive (Node parity).

## 3. Enriched Timer id + setImmediate

`setTimeout`/`setInterval`/`setImmediate` return a Timer id object (a real js-object, never the raw CL
struct — that would crash string coercion). It boxes the underlying handle and gains:

- `ref()` / `unref()` / `hasRef()` — delegate to the loop handle via new `lp:timer-ref`/`timer-unref`/
  `timer-refd-p` (added to `timers.lisp`, keeping the handle encapsulated). `unref` on a timer makes it
  stop keeping the loop alive — the unref'd-timer exit test relies on this (`loop-alive-p` already
  ignores unref'd handles).
- `refresh()` — reset the deadline to now + the original delay (`lp:timer-refresh`); returns the id.
- `close()` — alias for clear. `[Symbol.toPrimitive]` — returns a small integer id for `+timer` / map
  keys (Node returns a number-coercible Timeout).

**setImmediate/clearImmediate**: enqueue the thunk to `tasks` wrapped in a cancellation box; the id
holds the box; `clearImmediate` sets it; the wrapper checks it before running. ref/unref/hasRef exist
on the immediate id; for liveness an immediate always counts while queued (documented: `unref` on an
Immediate is accepted but does not drop it from the pending `tasks` set — near-unobservable since
immediates run on the very next iteration).

## 4. AbortController / AbortSignal (new `src/runtime/abort.lisp`)

We have no EventTarget/DOMException, so AbortSignal is a minimal, self-contained EventTarget for the
single `abort` event:

- `AbortSignal`: `aborted` (bool getter), `reason`, `onabort` (settable), `addEventListener("abort",cb)`
  / `removeEventListener` / `dispatchEvent`, `throwIfAborted()` (throws `reason` when aborted).
- Statics: `AbortSignal.abort(reason?)` → an already-aborted signal; `AbortSignal.timeout(ms)` → a
  signal aborting after `ms` via the global `setTimeout` (unref'd — a pending timeout signal must not
  keep the process alive) with a `TimeoutError`; `AbortSignal.any(iter)` → aborts when any input does.
- `AbortController`: `.signal` (lazily one signal), `.abort(reason?)` — idempotent; sets `aborted`+
  `reason`, then fires `onabort` + `abort` listeners once.
- Default abort reason: an `Error` with `name = "AbortError"` (no DOMException in v1 — documented).

Installed by `install-globals` (alongside structuredClone/crypto), so it is a global on every runtime
realm; `node:timers/promises` and later `fetch` consume it.

## 5. node:timers + node:timers/promises (new `src/runtime/node/timers.lisp`)

- **node:timers** re-exports the realm globals (`setTimeout`/`setInterval`/`setImmediate`/`clear*`);
  legacy `active`/`unenroll`/`enroll` are no-ops (documented). It reads the globals off the realm
  (they are installed by the engine bootstrap for every realm).
- **node:timers/promises**: `setTimeout(delay, value, opts)` → a Promise resolving to `value` after
  `delay`; `setImmediate(value, opts)` → resolves on the next check; `setInterval(delay, value, opts)`
  → an async iterator yielding `value` each period. Each honours `opts.signal` (an AbortSignal →
  reject/return with the abort reason, and reject immediately if already aborted) and `opts.ref`
  (unref the underlying timer when false). Built over the global `setTimeout`/`setImmediate` + `Promise`
  + `AbortSignal`.

## 6. events.once + captureRejections; assert async

- `events.once(emitter, name, opts?)` → Promise: resolve with the event args array; **also** attach an
  `error` listener that rejects (removed on resolve, and vice-versa); support `opts.signal`
  (already-aborted → immediate reject; abort later → reject + detach). `EventEmitter.on` async-iterator
  is out of scope unless cheap.
- **captureRejections**: constructor `{captureRejections:true}` (and `EventEmitter.captureRejections`
  static default) → when a listener returns a thenable that rejects, route the rejection to an
  `error` emit on the emitter (subset of Node's `Symbol.for('nodejs.rejection')`). errorMonitor stays a
  documented gap (no fresh-Symbol mint exposed — carried over from Phase 12).
- **assert.rejects(fnOrPromise, error?, message?)** / **doesNotReject(...)** → Promises. Resolve the
  input (call it if callable), then assert it rejected (validating against the matcher via the existing
  `%assert-expected-ok`) / did not reject, throwing/failing with AssertionError shape.

## 7. Gate + risks

Fixtures under `tests/js/async/`: `ordering` (phase order, deterministic), `timers` (args, interval+
clear, ref/unref/hasRef/refresh, node:timers, timers/promises), `unref` (unref'd timer → process exits;
ref'd control), `abort` (controller/signal/timeout/any + timers/promises signal reject), `evonce`
(resolve/reject/signal). Risk: the timer-vs-immediate divergence (documented); AbortSignal is a partial
EventTarget (only `abort`); captureRejections is a subset. All are enumerated as deliberate gaps.
