# Zero-stubs residuals (#339) — CLOSED inventory

**Status:** inventory closed to **zero product hollows** for exported Node/runtime
surfaces covered by Issue #339.

**Hollow** means: `declare (ignore this args)` (or ignore-args only) and return a
constant without doing real work for that API’s purpose.

## Final inventory (mechanical + review)

Live scan on the unit head classifies **no residual product hollows**.

Only **documented intentional design no-ops** remain (not incomplete-but-Yes):

| Site | Justification |
|------|----------------|
| `worker_threads` MessagePort `#start` | Node auto-starts ports; `start()` records `_started` and returns `undefined` (Node-compatible). |
| `crypto.getFips` / FIPS enable | Always reports `0`; pure-CL crypto is not FIPS-validated (honest, not soft-Yes). |
| `v8.startupSnapshot.isBuildingSnapshot` | Honest `false` — Clun does not build V8 snapshots. |
| `os.setPriority` foreign pid | Throws `SystemError`; self pid is process-local (no kernel niceness without forbidden APIs). |

## Surfaces destubbed across #338/#339 units

- cluster, vm, v8 coverage session, wasi (incl. `path_open` / `fd_read` / `path_filestat_get`), inspector Session, trace_events, test, repl
- worker_threads helpers, SharedArrayBuffer / Atomics
- os loadavg/cpus/userInfo/priority, domain, diagnostics_channel
- http/http2/https/tls body write, headers, abort, identity check, ping/close
- timers enroll/unenroll, module.syncBuiltinESMExports, perf_hooks timeline, async_hooks, readline ANSI
- tty/zlib/stream/net sockopts, process stdout/stderr `end`/`writableEnded`
- dgram/dns/crypto honesty, child_process async, websocket `wss:`

## Fixtures (shipped entry points)

- `tests/js/node/destub-surface.js`, `destub-residuals.js`, `destub-misc.js`
- `tests/js/node/destub-node-timers.js`, `destub-remaining2.js`, `destub-zero-final.js`
- `tests/js/node/httpresidual.js`, `tests/js/worker-threads/*`

## Notes

- Depth limits (full HPACK peer interop, full CDP, V8-precise coverage maps) are
  progressive quality — exported APIs perform real work, not ignore→undefined.
- **Qualified Yes is a No** — this inventory does not soft-Yes incomplete exports.
