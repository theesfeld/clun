# Shared-memory multithreading (Issue #338)

Status: accepted for implementation.

## Objective

Ship **proper** shared-memory multithreading:

| Surface | Behavior |
| --- | --- |
| `SharedArrayBuffer` | Shared data block; TypedArray/DataView may wrap it |
| `Atomics` | RMW + `wait`/`notify` with real cross-thread atomicity |
| `worker_threads` | Real `sb-thread` workers, isolated JS heaps, SAB share, MessagePort |

## Architecture

1. **One JS heap owner per realm/thread.** Ordinary JS objects are never shared across threads.
2. **Shared mutable state is only SAB data blocks** (`shared-data-block`: byte vector + mutex + waiter table).
3. **Per-thread wrappers.** Each realm has its own `js-shared-array-buffer` object pointing at the same block.
4. **Workers** create a fresh realm + event loop on an `sb-thread`. `postMessage` structured-clones (SAB = share block identity). `parentPort` / `Worker` ports use mailboxes + `loop-post` for delivery.
5. **Purity:** `sb-thread` / `sb-concurrency` only (already allowed). No CFFI.

## Files

- `src/engine/builtins-shared-memory.lisp` — SAB, Atomics, buffer protocol helpers used by TypedArray/DataView
- `src/runtime/node/worker_threads.lisp` — real Worker implementation
- Tests: Lisp engine suite + JS fixtures under `tests/js/worker-threads/`

## Non-goals (this unit)

- Web `Worker` global (substrate is reusable later)
- Growable SAB (`maxByteLength`)
- Full test262 Atomics/SAB pass-list promotion (fixtures first)

## Gates

`make build`, focused tests, `make test`, `make purity`.
