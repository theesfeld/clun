# Zero-stubs residuals (#339)

Honest inventory of **hollow** Node/runtime method sites after residual destub
passes (misc + remaining2).

**Hollow** here means: `declare (ignore this args)` (or ignore-args only) and
return a constant / `this` without doing real work for that API’s purpose.

Generated for tracking on Issue #339. Other agents own many of these files.

## Owned surfaces — status after remaining2 unit

| File | Status |
|------|--------|
| `src/runtime/node/tty.lisp` | Destubbed: color depth/env, ANSI clearLine/cursorTo/moveCursor/clearScreenDown, getWindowSize |
| `src/runtime/node/zlib.lisp` | Destubbed: real constants, create{Gzip,Gunzip,Deflate,Inflate,DeflateRaw,InflateRaw} |
| `src/runtime/node/stream.lisp` | Destubbed: pause/resume/isPaused flowing state + buffer drain |
| `src/runtime/node/net.lisp` | Destubbed: setTimeout timer, setNoDelay/setKeepAlive (sockopts + flags), ref/unref via loop handles |
| `src/runtime/node/worker_threads.lisp` | Destubbed: get/setEnvironmentData, markAsUntransferable, receiveMessageOnPort, BroadcastChannel, MessagePort ctor errors |
| `src/runtime/process.lisp` / `node/process.lisp` | No hollow product stubs remaining (module re-exports global process) |
| `src/runtime/node/remaining.lisp` | Destubbed: v8.takeCoverage/stopCoverage session; inspector Session requires `new` + connected flag; WASI fd_close/fd_seek/fd_fdstat_get + fd table; cli-args opts fix |
| `src/runtime/node/os.lisp` | Destubbed: setPriority/getPriority process-local store + range check + SystemError for foreign pid (no sb-posix setpriority) |
| `src/runtime/node/domain.lisp` | Destubbed: intercept Error-first routing (not alias of bind) |
| `src/runtime/node/diagnostics_channel.lisp` | Already non-hollow (subscribe/publish/stores) |

### Intentional / non-hollow notes (owned)

- `worker_threads` MessagePort `start` — no-op by design (auto-start delivery)
- `worker_threads` BroadcastChannel/Worker `ref`/`unref` — loop-handle based where a handle exists
- `zlib` create* ignore options arg for now (still builds a working Transform)
- `v8.startupSnapshot.isBuildingSnapshot` — honest `false` (Clun does not build V8 snapshots); callbacks are registered, not ignored
- `os.setPriority` — cannot change kernel niceness without setpriority syscall; self pid is tracked so getPriority matches setPriority; other pids throw SystemError
- WASI stdio fds are not seekable (ESPIPE); close marks table entry only (does not close host stdio)

## Remaining hollow sites (repo-wide, node builtins focus)

### http.lisp (http-family agent) — re-scan after #340 peers

- Residual ignore patterns may remain; verify live file before claiming Yes
- constructors used as empty stubs: check Agent/IncomingMessage/ServerResponse/ClientRequest/Server call-without-new paths

### http2.lisp (http-family agent)

- session/stream methods may still soft-return; re-scan after peer land

### https.lisp / tls.lisp (http-family agent)

- `tls.checkServerIdentity` and call-without-new empty bodies if still present

### timers.lisp (timers agent)

- legacy `timers.enroll` / `timers.unenroll` if still no-ops

### module.lisp (module agent)

- `module.syncBuiltinESMExports` → undefined if still present

### perf_hooks.lisp (timers/module agent)

- timeline store: clearMarks/clearMeasures/getEntries* may still be empty if not wired

### async_hooks.lisp

- `executionAsyncResource` → null (no resource tracking) if still present
- `AsyncResource#emitDestroy` may not fire destroy hooks

### readline.lisp

- `Interface#prompt` (no-op form)
- `readline.cursorTo` / `moveCursor` / `clearLine` / `clearScreenDown` → true without ANSI
- `readline.emitKeypressEvents` → undefined
- `Interface` constructor empty call path

### remaining.lisp (residual after this unit)

- `v8` coverage takes are simplified records (not full V8 precise coverage maps)
- WASI: no real host file open/path_open yet — only stdio fd table + args/env/clock/random/write
- inspector Session `post` does not implement full CDP; connected session returns structured acks
- cluster worker IPC is line-oriented best-effort (not full Node cluster channel)

### worker_threads.lisp (residual intentional)

- MessagePort `#start` → undefined (auto-start; listed for honesty)

## Outside node/ (brief)

- `src/runtime/web-platform.lisp` MessagePort `#start` auto-start no-op
- Some EventTarget helpers return true without full DOM propagation (by design subset)

## Test fixtures

- `tests/js/node/destub-misc.js` + `.out` — tty, zlib, stream pause/resume, net flags, worker env + BroadcastChannel
- `tests/js/node/destub-remaining2.js` + `.out` — v8 coverage, inspector Session, os.setPriority, domain.intercept, wasi fd_*

## Notes for #339

- **Qualified Yes is a No** — any of the above still `Partial` until filled with real behavior.
- Do not mark matrix rows Yes while listed hollow methods remain for that module’s claimed surface.
- Re-scan after http-family and timers/module agents land; this file is a snapshot, not SoT (Issues are SoT).
