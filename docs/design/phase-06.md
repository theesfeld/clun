# Phase 06 — Async engine: generators, promises, async/await, ESM

Objective: modern control flow (§3.1) on the Phase 05 loop. Gate: test262
Promise/generator/async/for-await-of dirs ≥ 75%, zero pass-list regressions, and an
ordering corpus (microtask vs timer vs nextTick) passing.

## Central decision — thread-per-coroutine, NOT state-machine lowering

The plan's primary bet is regenerator-style AST→AST state-machine lowering; §3.1 lists
**thread-per-generator (sb-thread + semaphore handoff)** as the sanctioned fallback. We take the
fallback **deliberately and up front** (logged in DECISIONS). Rationale specific to this engine:

- Clun compiles AST **directly to CL closures** that run on the real CL stack; its try/finally,
  loops, labels, and TDZ are already implemented via CL `unwind-protect`/`catch`/`handler-case`
  (emitter.lisp). State-machine lowering would require **reimplementing all of that a second time**
  in resumable switch-state form with try-entry tables — the exact "try/finally × yield × return"
  correctness risk the Risk Register flags, with silent-wrong-answer failure modes, on the critical
  path of a phase whose gate is only ≥75% and whose real content is Promises + ESM.
- A coroutine runs the **ordinary** compiled body closure on a dedicated thread; `yield`/`await`
  become plain calls that suspend via a semaphore handoff. try/finally × yield × return works **for
  free** because the CL stack is preserved across suspension. ~150 LOC for the primitive vs
  ~1500–2000 for lowering.
- Cooperative single-heap-owner is preserved: strict semaphore alternation means exactly one of
  {driver, coroutine} is runnable at any instant — never concurrent heap mutation.
- Cost: two context switches per yield/await (slow). §3.1 rules this acceptable; generators are rare
  and async is I/O-bound; **Phase 25** may revisit hot-path generators behind the same object contract.

The one genuine liability — parked threads for never-finished generators in the 30k-test run — is
mechanical (pool + teardown + finalizers), not a correctness risk.

## Coroutine primitive (`src/engine/async/coroutine.lisp`)

```
(defstruct coroutine thread (state :suspended-start) resume-sem yield-sem
                     in-box out-box body realm)
```
Two `sb-thread:semaphore`s at count 0. **Strict alternation**: `coroutine-resume` (driver thread)
sets `in-box=(mode . value)`, posts `resume-sem` (or lazily spawns the thread on first resume), then
`(semaphore-wait yield-sem)` — blocked until the coroutine hands back. The coroutine, after
`(semaphore-wait resume-sem)`, runs until `coroutine-suspend` posts `yield-sem` and waits. `in-box`/
`out-box` need no lock (the semaphore is the fence — same discipline as the Phase 05 worker mailbox).

Thread body (spawned lazily): **rebinds `*realm*` and re-enters `with-js-floats`** (both required —
the coroutine runs outside the caller's dynamic extent), waits for the first resume, then
```
(catch '%coroutine-return%                       ; .return(v) unwinds here through finalizers
  (handler-case (cons :return (funcall body))    ; normal completion / return-tag value
    (js-condition (c) (cons :throw (js-condition-value c)))))
```
`coroutine-suspend (co value)` (coroutine thread): `out-box=(:yield . value)`, post `yield-sem`, wait
`resume-sem`, then dispatch the injection: `:next`→return value; `:throw`→`throw-js-value`; `:return`
→`(throw '%coroutine-return% (cons :return v))`. Because `.return`/`.throw` re-enter the real stack,
enclosing `try/finally`/`try/catch` in the body run correctly with zero extra machinery.

`coroutine-resume` returns `(values kind value)` — `:yield`/`:return`/`:throw`; on the latter two the
thread retires to the pool.

**Leak control:** threads are **pooled per realm** and reused (return to `(semaphore-wait resume-sem)`
for a fresh body); lazy spawn (never-resumed generators cost no thread); `teardown-coroutines` in
`run-source`'s unwind-protect force-injects `:return` into every live coroutine and joins the pool;
`sb-ext:finalize` backstops coroutines GC'd mid-suspend (posts the return sentinel). The runner's
existing gc-every-500 triggers finalizers.

## Emitter changes (`emitter.lisp`)

- Thread `:generator`/`:async` from the parser flags through `compile-function-expr`, the
  `function-node` decl branch, `global-instantiate`, block func-decls, `compile-arrow` (async only),
  and methods into `compile-function-common` (`&key generator async`).
- Reserve a hidden frame slot `%coro%` (like `%this%`) in generator/async functions; a dynamic
  `*compiling-coro-kind*` tells the yield/await compilers their target.
- At the tail of `compile-function-common`, keep the existing inner thunk
  `(lambda () (catch return-tag (funcall body-fn frame) +undefined+))` and **wrap** it:
  `wrap-generator` / `wrap-async` / `wrap-async-generator` set `%coro%` and build the right object.
  Normal functions are unchanged. Because the body thunk is untouched, every statement compiler works
  verbatim inside a coroutine.
- `yield-expression` → `(coroutine-suspend %coro% arg)`; `yield*` delegation drives an inner iterator
  step-wise, threading the driver's injected mode into inner next/throw/return.
- `await-expression` → `(await-value %coro% arg)` (§async).
- `for-of-statement` gains an `await` field (parser already accepts the keyword); `compile-for-of`
  branches to a lazy async-iterator loop that awaits each step.

## Promise + job queue (`src/engine/async/promise.lisp`) and the drive path

`(defstruct (js-promise (:include js-object (class :promise))) (pstate :pending) value
             (fulfill-reactions '()) (reject-reactions '()) (handled nil))`. Resolve does thenable
adoption (callable `then` → adopt via a microtask); settling schedules each reaction as a microtask
via `(enqueue-microtask (realm-loop *realm*) …)` — the single seam to Phase 05. then/catch/finally +
all/race/allSettled/any (`any` needs an `AggregateError` intrinsic). nextTick sits ahead of
microtasks **for free** (Phase 05 `drain-microtasks` already does nextTick-fully-then-one-microtask).

Realm gains slots: `loop` (event-loop, lazy, **`:workers 0`** — coroutines use their own threads),
`coroutine-pool`, `pending-rejections`. `run-source`/`eval-source` change to:
```
bind *realm*; loop = (or (realm-loop r) (setf (realm-loop r) (make-event-loop :workers 0)))
unwind-protect
  run top-level (may schedule microtasks/timers; module path wraps in an async coroutine for TLA)
  (run-loop loop)                       ; drain micro/macro/timers/nextTick to idle
  (report-unhandled-rejections r)       ; still-unhandled reject → js-condition (→ exit 1 at CLI)
  cleanup: (teardown-coroutines r) (destroy-event-loop loop)
```
`eval-source` keeps returning the top-level completion value (drives the loop after capturing it).
`queueMicrotask` / `Promise` / (minimal) `setTimeout`+`queueMicrotask`+`process.nextTick` globals are
wired for the ordering corpus.

## async function / async generator / Generator object

- **Generator**: `(defstruct (js-generator (:include js-object (class :generator))) coroutine)`;
  `%GeneratorPrototype%` next/return/throw → `coroutine-resume :next/:return/:throw` → `{value,done}`
  (`done` when kind is `:return`); `@@iterator` returns this; `%GeneratorFunction%` intrinsic.
- **async function**: returns a promise `P`; body runs in a coroutine driven as microtasks.
  `await-value (co v)`: `then` the resolved `v` with reactions that `coroutine-resume` `:next`/`:throw`
  on the loop thread (never concurrent). `:return`→resolve `P`; `:throw`→reject `P`.
- **async generator**: `@@asyncIterator`; next/throw/return return promises; a request queue
  serializes overlapping `next()`; `yield` suspends to the consumer, `await` to a promise reaction.

## ESM (in-memory) + TLA — Phase 06 scope

Module **resolution** is Phase 07. Phase 06 builds only the in-memory linking/evaluation to run
module-flagged 262 tests + prove TLA: a module env frame, `import`/`export` binding within the
provided source set, module-body evaluation **inside a coroutine** so top-level `await` is just
`await` at module scope. Deferred to Phase 07: file resolution, node_modules, exports maps, CJS
`require`, ESM↔CJS interop, `import.meta`.

## test262 runner (`scripts/test262.lisp`)

Unskip `generators`/`async-functions`/`async-iteration`/`top-level-await` incrementally per milestone;
route the `module` flag to the module path; implement the `async` flag (include `doneprintHandle.js`,
expose `$DONE`, run then drive the loop to idle, pass iff `$DONE()` called with no arg before timeout).

## Milestones (build+test+purity green after each; zero pass-list regressions)

1. Coroutine primitive + Generator object + emitter flag plumbing + yield (no delegate). Parachute
   tests only (no 262 unskip) → passlist untouched.
2. yield* delegation; unskip `generators`; regenerate passlist.
3. Promise + job queue + run-source/eval-source loop hosting; ordering parachute tests; Promise
   built-ins.
4. async/await + for-await + async generators; unskip async dirs; runner `async`/`$DONE`.
5. ESM in-memory linking + TLA; route `module`.
6. Gate: full exec run, regenerate passlists, thread-count leak assertion, adversarial review panel,
   DECISIONS entry (the (B)-over-(A) fallback), commit.

## Risks

- Thread leak (mitigated: pool + teardown + finalizer + gc-every-500).
- Deadlock if a reaction resumes a `:running` coroutine — `coroutine-resume` asserts state ∈
  {suspended-start, suspended-yield}; async-generator request queue serializes `next()`.
- `*realm*` / float-trap not rebound in the thread — both are required one-liners at the thread top;
  unit-tested (a generator reads the right realm's globals; a generator doing float math doesn't trap).
