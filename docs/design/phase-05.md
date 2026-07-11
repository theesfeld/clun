# Phase 05 — Event loop core

Objective: the pure-SBCL reactor of §3.2 — the substrate every async product feature (Phase 06
promises, 14 timers, 16 sockets, 17 server, 24 spawn) sits on. Independent of the engine (deps: 01
only, and only nominally — the loop traffics in CL thunks; Phase 06 wires JS jobs into the queues).
All facts below are Appendix C (do not re-verify).

## Model (§3.2)

One **JS thread** owns the heap, timers, microtasks, and a `serve-event` reactor for fds. A small
**worker pool** (sb-thread) runs blocking ops; completions return via `sb-concurrency:mailbox` +
**self-pipe wakeup** (Appendix C.5: signals do NOT wake serve-event; a self-pipe byte does). fd and
signal handlers **enqueue only** — JS/CL callbacks run solely at loop *dispatch points*, each
followed by a full microtask drain, with `process.nextTick`'s dedicated queue drained first.

Callbacks in Phase 05 are opaque CL thunks (the "stub queue" the gate names); Phase 06 replaces the
thunks with JS job invocations without changing this file's contract.

## Files (`src/loop/`, package `:clun.loop`; raw fd bits quarantined in `src/sys/sbcl-compat.lisp`)

- **`src/sys/sbcl-compat.lisp`** (`:clun.sys`) — the only place internal SBCL APIs live (§3.2/§6).
  `self-pipe`: `sb-posix:pipe` → non-blocking read end wrapped as an `(unsigned-byte 8)` fd-stream
  (loop-thread-only drain via `listen`/`read-byte`), write end kept raw for `self-pipe-wake`
  (`sb-unix:unix-write` of one byte from a pinned static buffer — allocation-free, so it is legal
  from signal/interrupt context). `poll-backend-p` = `(fboundp 'sb-unix:unix-poll)` (Appendix C.5).
- **`loop-core.lisp`** — the `event-loop` struct (all slots), the O(1) `fifo` (head/tail cons
  queue), the `handle` refcount object, the three JS-facing queues (next-tick, microtask, task) +
  `drain-microtasks`, `now-ms`, and `loop-alive-p`.
- **`timers.lisp`** — binary min-heap keyed `(deadline . seq)` (seq breaks ties FIFO, Node-faithful);
  `set-timer`/`clear-timer` (lazy cancel), `expire-due-timers`, `next-timer-delay`.
- **`reactor.lisp`** — `reactor-add`/`reactor-remove` (`sb-sys:add-fd-handler`) and `reactor-poll`
  (`sb-sys:serve-event` with a seconds timeout); startup `probe-reactor` (Appendix C.5).
- **`signals.lisp`** — `install-signal-handler`: `sb-sys:enable-interrupt` body does **only**
  `(sb-ext:atomic-incf (aref counts signo))` + `self-pipe-wake` (iron rule §6). `drain-signals`
  reads the atomic counts on the loop thread and enqueues each pending signal's listener as a task.
- **`workers.lisp`** — fixed pool of N `sb-thread`s draining a job mailbox; `worker-submit` runs a
  blocking fn on a worker, captures `(:ok v)`/`(:err condition)`, and `loop-post`s the on-done
  thunk back. An in-flight ref'd handle keeps the loop alive until completion. `stop-workers` joins.
- **`event-loop.lisp`** — `make-event-loop` (creates self-pipe + registers its reactor handler +
  completion mailbox + worker pool + probe), `run-loop`, `loop-post` (thread-safe: mailbox + wake),
  `loop-stop` (graceful), and the per-iteration drivers.

## The loop iteration (`run-loop`)

```
drain-microtasks                      ; honor any work queued before run
while (loop-alive-p):
  timeout = loop-timeout              ; 0 if immediate work; else min(next-timer, cap=1s); cap if only refs
  reactor-poll timeout                ; blocks in poll; dispatches fd handlers (self-pipe drain, later sockets)
  process-completions                 ; drain mailbox -> each done-thunk at a dispatch point
  drain-signals                       ; atomic counts -> signal listeners at dispatch points
  expire-due-timers                   ; each fired timer at a dispatch point (repeating re-inserted)
  process-tasks                       ; queued macrotasks, each at a dispatch point
```

A **dispatch point** = run one thunk, then `drain-microtasks` (next-tick fully, then one microtask,
repeat — nextTick has priority and is re-checked between microtasks). `loop-alive-p` =
`ref-count > 0 OR immediate-work-p` (macro/micro/next-tick/task queues non-empty). Ref'd timers and
in-flight workers contribute to `ref-count`; **unref'd timers do not keep the loop alive** but fire
if it is already running. `loop-timeout` caps at 1 s so a missed wake cannot hang the loop; the
self-pipe makes signal/worker latency ~immediate (Appendix C.5), not timeout-bound.

## Handles & refcounting (§3.2 lifetime)

A `handle` has `refd`/`active`/`counted` flags. `activate` (refd+active → counted, `incf ref-count`),
`deactivate` (clears counted), `ref`/`unref` toggle contribution live. A ref'd timer owns a handle
(deactivated when a one-shot fires); each worker job owns one (deactivated on completion). Sockets
(Phase 16) and child watchers (Phase 24) will own handles the same way. Loop exits at
`ref-count = 0 ∧ all queues empty`.

## Interrupt-context discipline (§6 iron rule; reviewer hunts violations)

Signal handlers and, later, `run-program :status-hook` bodies (Appendix C.11) touch only the atomic
counter and the raw self-pipe write. No consing, no locks, no CL callbacks. `self-pipe-wake` uses a
`load-time-value` pinned buffer and `sb-unix:unix-write` — allocation-free and syscall-only.

## Reactor / thread gotcha (verified this phase — Phase 16 must respect it)

SBCL's `serve-event` dispatches an fd handler **only on the thread that registered it** with
`add-fd-handler` (a cross-thread registration silently never fires — measured: a wake byte written to
a pipe watched by a handler registered on another thread left `serve-event` blocked the full timeout).
Therefore `run-loop` registers the self-pipe handler itself, on the loop thread, and Phase 16 must add
socket handlers from the loop thread too (e.g. via a `loop-post`, never directly from a worker).

## Risks

- serve-event is process-global (`add-fd-handler` mutates SBCL's descriptor table). v1 has one loop;
  documented, revisit only if multi-loop is ever needed (non-goal).
- Multi-thread wakes race on the write fd: safe because a 1-byte pipe write is atomic and the raw
  path shares no stream state (the loop thread alone owns the read stream).
- Timeout cap (1 s) trades a hair of idle wakeups for robustness against a dropped wake.

## Gate

parachute suites in `tests/lisp/loop/`: timer ordering (FIFO ties, repeating, clear); cross-thread
wake < 5 ms (worker/loop-post latency while the loop blocks on a far timer); process alive iff
refs > 0 (unref'd-only exits immediately; ref'd keeps alive then exits); SIGINT → enqueued loop event;
microtask/nextTick drain ordering (macro → nextTick → micro → macro). Plus `make build/test/purity`
green and zero test262 exec-passlist regressions.
