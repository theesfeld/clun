# Phase 24 — Spawn + package scripts

**Objective (PLAN §5/§3.3/§3.6):** the daily-driver workflow — `Clun.spawn`/`spawnSync` (subprocess
over `sb-ext:run-program`) and `clun run <script>` (package.json scripts). ~2k LOC, milestoned.

**Gate:** a spawn matrix (echo/cat/exit/signal); a 10 MB dual-pipe child drained concurrently without
deadlock; 1,000 spawns → zero zombies; a scripts fixture (pre-fail aborts, env asserted, exit
propagation); `examples/e2e.sh` (install → run build via a `.bin` tool → clun test) green + hermetic.

## Milestones

1. **`Clun.spawnSync`** (this milestone): the blocking subprocess primitive — the spawn matrix,
   temp-file stdio (no pipe deadlock), env/cwd, exit + signal mapping.
2. **`Clun.spawn`** (async): `run-program :wait nil`, non-blocking stdout/stderr/stdin pipes on the
   reactor, an `.exited` promise, `exitCode`/`signalCode`/`kill`/`onExit`; the `:status-hook` marshals
   the child-exit to the loop thread via `lp:loop-post` (mailbox + self-pipe — the §6 iron rule:
   status-hook enqueues ONLY). Gate: 10 MB dual-pipe no-deadlock; 1,000 spawns → zero zombies.
3. **`clun run <script>`** + dispatcher merge: `/bin/sh -c`, ancestor `.bin` PATH walk, `pre`/`post`
   (failing `pre` aborts), `npm_*` env, `--if-present`, arg passthrough; file-vs-script dispatch.
   Then `examples/e2e.sh` (install → run build via a `.bin` tool → clun test) — the v1 workflow demo.

## 1. `Clun.spawnSync` (`src/runtime/spawn.lisp`, package `clun.runtime`)

`Clun.spawnSync(cmd, opts)` — `cmd` is `[program, ...args]` (Bun's array form). Returns a plain JS
object `{ pid, exitCode, signalCode, success, stdout, stderr }`:
- `stdout`/`stderr` default `"pipe"` → captured as a `Uint8Array` (`eng:u8-from-octets`); `"inherit"`
  → to the terminal (returned prop is `null`); `"ignore"` → `/dev/null`.
- To avoid the classic full-pipe deadlock on a SYNC call, piped stdout/stderr are redirected to
  **temp files** (`:output <path>` with `:wait t` — the file absorbs any size), read back after exit,
  and removed. stdin (a string/Uint8Array/ArrayBuffer in `opts.stdin`) is written to a temp file used
  as `:input`.
- `opts.cwd` → `:directory`; `opts.env` (a JS object) → `:environment` as `K=V` (via `Object.keys`);
  absent env inherits the current process environment. `:search t` for a PATH lookup of `program`.
- Exit mapping: `sb-ext:process-status` `:exited` → `exitCode` = the code, `signalCode` = `null`;
  `:signaled` → `exitCode` = `null`, `signalCode` = the signal NAME (a small number→name map).
  `success` = `(exitCode == 0)`.
- Errors (program not found, bad cwd) → a catchable JS error, never a raw Lisp backtrace (§6).

`install-spawn (realm rt)` adds `spawnSync` (and, in M2, `spawn`) to the `Clun` global; called from
`install-clun-global`.

## 2/3. deferred to milestones 2/3 (design above; async pipe drain mirrors the Phase-16 tcp reader:
`reactor-add fd :input` → non-blocking `sb-unix:unix-read` → buffer/close on EOF; stdin writes are
EAGAIN-safe non-blocking, backpressured via `reactor-add fd :output`).

## Risks / notes

- `run-program` reaps zombies automatically (verified, §3.3); the async M2 must not leak child watchers
  (handle refcount released on exit).
- The status-hook fires in interrupt context — it may ONLY `lp:loop-post` (no JS, no allocation beyond
  the enqueue), per §6. The promise settle + `onExit` run on the loop thread when the post is dispatched.
- Temp files (M1) use `sys:make-temp-dir` + a unique name; always cleaned up in an unwind-protect.
