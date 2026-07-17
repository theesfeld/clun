# Phase 08 — CLI shell, console, process

Objective (PLAN.md line 433): `clun` feels like a real CLI. Gate: run/eval fixture
matrix (exit codes, stacks, `-p` awaiting a promise) + console conformance vs a
**subset** of Bun's `test/js/web/console/console-log.expected.txt` (each deliberate
divergence documented). Distilled from a Plan-agent pass over the code; cited
`file:line` are anchors.

## 0. Layering

`make-realm` stays runtime-free (test262 conformance uses a bare realm). A separate
`clun.runtime:install-runtime (realm &key argv cwd silent colors)` hook augments a
fresh realm with `console`, the full `process`, and a `Clun` stub. The CLI
(`clun` package / `main.lisp`, helped by `clun.cli`) parses flags, installs
runtime, autoloads `.env`, runs the entry, and renders uncaught errors.

```
clun.engine (inspect-value)  ◄── clun.runtime (console/process/Clun)
       ▲                              ▲
       └──────────── clun.cli / main (dispatch, flags, uncaught, .env)
```

## 1. The inspector — `src/engine/inspect.lisp` (in clun.engine)

ONE shared inspector powers `console.*`, `util.inspect`, `Clun.inspect`, and test
diffs (§3.6). It lives in `clun.engine` (deep access to descriptors, Map/Set/Promise
internals, wrapper primitives) and exports just `inspect-value` + `*inspect-defaults*`.

```lisp
(defun inspect-value (v &key (depth 2) (colors nil) (breadth 100)) -> string)
```

Circular tracking: an `eq` hash of containers on the current path (push on enter,
pop on exit); a repeat → `[Circular]` (Bun's form — NOT Node's `[Circular *1]`).
Depth budget decremented per container; beyond it a container renders `[Object ...]`
/ `[Array]` (Bun's `[Object ...]` form — verified in the fixture).

**Value rendering (Bun-faithful, verified against the fixture):**
- number → `number->js-string`; `-0` → `"-0"`; NaN/±Infinity literal.
- string → double-quoted with escapes (top-level strings from `console.log` print
  RAW; only *nested* strings are quoted — handled by console, not the inspector).
- symbol → `Symbol(desc)`; boolean/null/undefined literals.
- `callable-p` → `[Function: name]`, anonymous → `[Function]` (Bun prints bare
  `[Function]`); class → `[class X]` / `[class (anonymous)]`.
- wrapper (`js-object-class` ∈ number/string/boolean) → `[Number: 5]` / `[String: "…"]`.
- array → inline `[ a, b, c ]`; holes coalesce to `<N empty items>`; `... N more
  items` past `breadth`. (Arrays are inline; **objects are multiline**.)
- ordinary object → **multiline with a trailing comma**, even single-property:
  `{\n  a: "",\n}`; empty → `{}`. Class instances → `Name {\n  …\n}` / `Name {}`.
  Keys: identifier-like unquoted, else double-quoted; accessor descriptors →
  `[Getter]`/`[Setter]`/`[Getter/Setter]` (never invoked); only enumerable own keys.
- `:map` → `Map(n) { k: v, … }` (Bun colon form); `:set` → `Set(n) { v, … }`;
  `:promise` → `Promise { <pending> }` / `{ value }` / `{ <rejected> reason }`;
  `:date` → ISO; `:error` → its `.stack` string.

**Deferred (documented divergences):** exact 80-column wrapping heuristic (we use
"objects always multiline, arrays inline unless they contain a multiline child");
`SetIterator`/`MapIterator` display objects; `%o/%O` showHidden nuances; BigInt
`123n` (Phase 11). The gate uses a curated fixture subset matching what we render.

## 2. console — `src/runtime/console.lisp`

`log/info/debug/dir` → `*standard-output*`; `warn/error/trace` → `*error-output*`;
`assert`, `count/countReset`, `group/groupEnd` (indent). `util.format` core
(`format-log-args`): arg0 string consumes `%s %d %i %f %j %o %O %c %%` from the
rest (`%c` consumed, emits nothing; `%%`→`%`, no consume; `%d`-on-string = Node
parseInt, TODO-marked); trailing args appended space-separated, non-strings via the
inspector, top-level strings raw. `finish-output` after each line. `--silent`
suppresses `log/info/debug` only (warn/error still print). Colors decided once at
install: `FORCE_COLOR`(≠"0") > `NO_COLOR` > TTY.

## 3. process — `src/runtime/process.lisp`

Augments the engine's stub `process` (which already has `nextTick`). Adds: `argv`
`[execPath, scriptAbsPath, ...rest]` (`[eval]` for `-e/-p`); `env` = plain snapshot
object from `sb-ext:posix-environ` (**no live OS interceptor** — documented);
`exit([code])`/`exitCode`; `platform`="linux"/`arch`="x64"/`pid`; `cwd()`/`chdir()`;
`versions` (`.node`="22.11.0" pinned, `.clun`); `version`="v22.11.0"; `stdout`/`stderr`
minimal writables (`.write`→bool, `.isTTY`, `.fd`); `hrtime([prev])`→`[s,ns]` +
`hrtime.bigint` stub (microsecond resolution via `get-time-of-day`, documented);
`memoryUsage()` (OS resident-set bytes plus SBCL `dynamic-usage` heap approximations);
a minimal `'exit'`
emitter (`on`/`emit` — only `'exit'` fires). `process.exit` throws a `process-exit`
CL condition that unwinds past the loop-owning drive path; `main` catches it, fires
`'exit'` once, `sb-ext:exit`s with `exitCode`.

## 4. CLI dispatch + flags — `src/cli/args.lisp` + `main.lisp`

Positional-stop grammar: global flags parsed until the first non-flag positional;
everything after passes through to `process.argv`. Flags: `-v/--version`,
`--revision`, `-h/--help`, `-e/--eval <code>`, `-p/--print <code>`, `--cwd <dir>`,
`--silent`, `--backtrace`. `clun <file>` file-first; `clun run <x>` (Phase 08: run a
file; script-name lookup is Phase 24). Extension routing → `run-module-file` for
`.js/.mjs/.cjs/.json` (ESM/CJS decided by the resolver's `"type"` logic); `.ts/.mts/
.cts` → "TypeScript lands in Phase 09" message. `--cwd` `chdir`s first. Exit codes:
0 ok, 1 uncaught error/rejection, 2 usage.

**`-p`/`-e` completion:** add a `realm-eval-completion` slot + a `capture-completion`
flag to `run-module-source`; `compile-esm-module` stores the last top-level
ExpressionStatement's value into the slot. `-p` inspects it post-drain (a settled
promise → its value; still-pending → print the pending promise, documented). `-e`
runs without printing.

## 5. Uncaught-error rendering — `main.lisp` handler-case

JS throws surface as `clun.engine:js-condition`; unhandled rejections re-throw the
reason the same way. `render-uncaught (v)`: an Error object → `Uncaught <name>:
<message>` + `.stack` to stderr; a non-Error → `Uncaught <inspected>`. Lisp
condition → `clun: <message>` (generic), backtrace ONLY with `--backtrace`. Exit 1.

## 6. .env autoload — `src/cli/dotenv.lisp`

Pure-CL parser of `./.env` (post-`--cwd`): `KEY=VALUE`, `export ` prefix stripped,
`#` comments, single-quote literal / double-quote with `\n\t\r\\` escapes / unquoted
trimmed, multiline quoted values. OS-set vars win over `.env` (no override —
documented). Mutates the `process.env` object before running.

## 7. JS-fixture harness — `scripts/run-js-fixtures.lisp` + `tests/js/`

`tests/js/<group>/<case>.{js,mjs,…}` + a sibling `<case>.expected` manifest
(`argv:`/`exit:`/`stdout:`/`stderr:`). The runner spawns `build/clun` via
`sb-ext:run-program` (`:wait t`, capture output+exit, cwd = group dir), compares
stdout/stderr/exit, exits nonzero on mismatch. Wired into `make test` (needs `build`
first). Seed corpus: `console/`, `process/`, `eval/`, `errors/`.

## 8. Milestone order (each keeps `make build && make test` green)

1. `src/engine/inspect.lisp` + engine exports + parachute suite. (disjoint)
2. `src/sys/` additions: `tty-p`, env-alist, getpid/cwd/chdir, hrtime, memory. (disjoint)
3. `src/runtime/` install + console + process + Clun stub + parachute suite. (deps 1,2)
4. `src/cli/` + `main.lisp` rewrite + `-p` completion + uncaught + `.env`. (deps 3)
5. `scripts/run-js-fixtures.lisp` + `tests/js/` corpus + Makefile. (deps 4)
6. Gate + adversarial review panel + STATE/DECISIONS + commit.

## 9. Verified SBCL facts (Appendix-C-style, recorded in DECISIONS)

- `sb-posix:isatty` does NOT exist → `sb-unix:unix-isatty (fd)` (fd of a stream via
  `sb-sys:fd-stream-fd`). Quarantined in `src/sys/sbcl-compat.lisp`.
- `hrtime` via `sb-ext:get-time-of-day` (µs wall; nanos end in 000 — documented).
- `memoryUsage().rss` via `/proc/self/statm` on Linux and `getrusage` peak RSS on
  Darwin; heap fields via `sb-kernel:dynamic-usage` / `sb-ext:get-bytes-consed`.
- `sb-posix:getpid/getcwd/chdir`, `sb-ext:posix-environ/posix-getenv` all exist.
- Node version pinned `22.11.0` ("Jod" LTS).

## 10. Top risks

1. `-p` completion plumbing touches Phase-07 codegen — keep surgical (one slot +
   flag); fall back to a `globalThis` wrap if it fights.
2. Inspector fidelity vs the Bun fixture — drive the suite off the real fixture
   lines; document every divergence.
3. `process.exit`/`on('exit')` unwinding through the loop-owning drive paths — model
   exit as a dedicated condition caught only in `main`; fire `'exit'` exactly once.
