# Zero-stubs residuals (#339)

Honest inventory of **hollow** Node/runtime method sites after the misc destub
pass (tty / zlib / stream pause-resume / net sockopts / worker_threads helpers).

**Hollow** here means: `declare (ignore this args)` (or ignore-args only) and
return a constant / `this` without doing real work for that API’s purpose.

Generated for tracking on Issue #339. Other agents own many of these files.

## Owned surfaces — status after this unit

| File | Status |
|------|--------|
| `src/runtime/node/tty.lisp` | Destubbed: color depth/env, ANSI clearLine/cursorTo/moveCursor/clearScreenDown, getWindowSize |
| `src/runtime/node/zlib.lisp` | Destubbed: real constants, create{Gzip,Gunzip,Deflate,Inflate,DeflateRaw,InflateRaw} |
| `src/runtime/node/stream.lisp` | Destubbed: pause/resume/isPaused flowing state + buffer drain |
| `src/runtime/node/net.lisp` | Destubbed: setTimeout timer, setNoDelay/setKeepAlive (sockopts + flags), ref/unref via loop handles |
| `src/runtime/node/worker_threads.lisp` | Destubbed: get/setEnvironmentData, markAsUntransferable, receiveMessageOnPort, BroadcastChannel, MessagePort ctor errors |
| `src/runtime/process.lisp` / `node/process.lisp` | No hollow product stubs remaining (module re-exports global process) |

### Intentional / non-hollow notes (owned)

- `worker_threads` MessagePort `start` — no-op by design (auto-start delivery)
- `worker_threads` BroadcastChannel/Worker `ref`/`unref` — loop-handle based where a handle exists
- `zlib` create* ignore options arg for now (still builds a working Transform)

## Remaining hollow sites (repo-wide, node builtins focus)

### http.lisp (http-family agent)

- `IncomingMessage#setEncoding`
- `ServerResponse#write` (returns true, no body buffer)
- `ClientRequest#write`
- `ClientRequest#setHeader`
- `ClientRequest#abort`
- constructors used as empty stubs: `Agent`, `IncomingMessage`, `ServerResponse`, `ClientRequest`, `Server` (call-without-new paths)

### http2.lisp (http-family agent)

- session `request` stream `#write` → true
- session `#close` → undefined
- session `#ping` → undefined

### https.lisp / tls.lisp (http-family agent)

- `tls.checkServerIdentity` → undefined
- `TLSSocket` / `Server` / `SecureContext` call-without-new empty bodies
- (connect/createServer partially re-use net)

### timers.lisp (timers agent)

- legacy `timers.enroll` / `timers.unenroll` (if still present as no-ops — verify when editing)
- iterator helpers may ignore args while still performing real settle work (not listed as hollow)

### module.lisp (module agent)

- `module.syncBuiltinESMExports` → undefined

### perf_hooks.lisp (timers/module agent)

- `performance.clearMarks` / `clearMeasures` → undefined (if timeline not stored)
- `performance.getEntries` / `getEntriesByName` / `getEntriesByType` → empty array (no timeline store)
- `PerformanceObserver#observe` / `#disconnect` (when still no-op forms)
- `PerformanceObserver#takeRecords` → empty when pending not wired

### async_hooks.lisp

- `executionAsyncResource` → null (no resource tracking)
- `AsyncLocalStorage#disable` may be no-op depending on branch state
- `AsyncResource#emitDestroy` → undefined (no destroy hooks fired)

### readline.lisp

- `Interface#prompt` (no-op form)
- `readline.cursorTo` / `moveCursor` / `clearLine` / `clearScreenDown` → true without ANSI
- `readline.emitKeypressEvents` → undefined
- `Interface` constructor empty call path

### remaining.lisp (cluster/v8/wasi/inspector/… surface)

- `v8.takeCoverage` / `v8.stopCoverage` → undefined
- inspector `Session` constructor empty path (partial real open/close elsewhere)
- assorted profiler enable/disable no-ops if present

### os.lisp

- `os.setPriority` → undefined (cannot change process niceness in pure portable path)

### worker_threads.lisp (residual intentional)

- MessagePort `#start` → undefined (auto-start; listed for honesty)

## Outside node/ (brief)

- `src/runtime/web-platform.lisp` MessagePort `#start` auto-start no-op
- Some EventTarget helpers return true without full DOM propagation (by design subset)

## Test fixtures added this unit

- `tests/js/node/destub-misc.js` + `.out` — tty, zlib constants/create*, stream pause/resume, net flags, worker env + BroadcastChannel surface

## Notes for #339

- **Qualified Yes is a No** — any of the above still `Partial` until filled with real behavior.
- Do not mark matrix rows Yes while listed hollow methods remain for that module’s claimed surface.
- Re-scan after http-family and timers/module agents land; this file is a snapshot, not SoT (Issues are SoT).
