# Clun — Bun, Rewritten in Pure Common Lisp

**This document is the operating manual for the agent building Clun.** It was authored by the
project's engineer/PM (with four parallel research agents whose empirical findings are baked in —
see Appendix C) and is designed to be executed by Claude Opus 4.8 running in Claude Code,
iterating the phase loop in §2 until v1 ships. Read §2 at the start of every session.

- **This repo:** `/home/glenda/Projects/clun` (you are building this; git is already initialized)
- **Reference implementation:** `/home/glenda/Projects/bun` (read-only — never modify it; matrix
  comparisons pin its commit `c1076ce95e`)
- **Host toolchain:** SBCL 2.6.4 on PATH (`:sb-thread`, `:mark-region-gc`, poll-backed
  serve-event — all verified). Linux x86-64. Pin this SBCL version.

### How to drive this plan (note to the human operator)

Kick off each working session with:

> Read PLAN.md and STATE.md in this repo, then execute the loop in PLAN.md §2. Continue until the
> current phase gate passes.

Append `ultracode` to that prompt if you want workflow-grade multi-agent orchestration that
session; the plan works either way (§2 explains how the executing agent should adapt).

---

## 1. Mission, Scope, and the Purity Contract

Bun is ~1M lines of Rust/C++ on top of JavaScriptCore. Clun is **not** a literal port. It is a
sharply scoped, faithful-in-spirit JavaScript/TypeScript runtime and toolkit written in **pure
Common Lisp** — including a from-scratch ECMAScript engine. Correctness of the scoped surface and
purity of the implementation beat breadth and speed.

### 1.1 The Purity Contract (constitutional — every phase gate re-checks it)

- **ALLOWED:** ANSI Common Lisp; SBCL built-in contribs (`sb-bsd-sockets`, `sb-posix`,
  `sb-thread`, `sb-concurrency`, `sb-ext`, `serve-event`, …); third-party libraries written
  entirely in CL (zero CFFI, zero foreign libraries, zero C shims), vendored and pinned
  (Appendix B is the approved list).
- **FORBIDDEN:** CFFI or any foreign library (no QuickJS, no libuv, no OpenSSL, no zlib); any
  JavaScript source as part of the *implementation* — every builtin module and global is
  implemented in CL against the engine's object API. JS/TS appears **only** as test fixtures and
  conformance corpora. Shelling out to system tools (tar, curl, git, node) as an implementation
  crutch is forbidden; `sb-ext:run-program` exists only to implement the user-facing subprocess
  features (`Clun.spawn`, package scripts).
- **ENFORCED MECHANICALLY:** `make purity` (built in Phase 00) scans the full ASDF load plan and
  all vendored sources for `cffi`, `foreign-funcall`, `sb-alien`, `define-alien` outside SBCL
  itself, and fails CI on any hit. It runs as part of every phase gate.

### 1.2 v1 delivers (the `clun` binary)

| Command | Behavior |
|---|---|
| `clun <file>` / `clun run <file>` | Execute `.js` / `.mjs` / `.cjs` / `.ts` / `.mts` / `.cts` / `.json` |
| `clun run <script>` | Run a `package.json` script (`/bin/sh -c`, ancestor `.bin` PATH, pre/post) |
| `clun -e '<code>'` / `clun -p '<code>'` | Evaluate; `-p` prints the (awaited) completion value |
| `clun test` | Jest-lite runner: hooks, `.skip/.todo/.only`, `-t <regex>`, `--timeout`, `--bail`, ~22 matchers |
| `clun install` / `add` / `remove` | npm registry (HTTPS via pure-CL TLS 1.3), hoisted `node_modules`, `clun.lock` |
| `clun --version` / `--revision` / `--help` | The obvious |

Runtime surface: ES2017-tier engine (§3.1) with strict *and* sloppy modes; ESM + CJS + JSON
modules with Node resolution; TypeScript by erasable-syntax type stripping; event loop with
Node-faithful micro/macrotask + `nextTick` ordering; `console` (Bun-faithful formatting), timers
(+`ref`/`unref`), `process`, `fetch` (HTTP + experimental HTTPS), WHATWG `URL`/`URLSearchParams`
(minus IDNA), `TextEncoder/TextDecoder` (UTF-8), `AbortController`, `crypto.randomUUID`/
`getRandomValues`; node-compat: `path` (posix), `fs` (sync core + promises subset + callback
shims), `os`, `events`, `util` (subset), `url`, `buffer` (subset), `querystring`, `assert`,
timers modules; a 14-member `Clun` global (`version`, `revision`, `env`, `argv`, `main`, `sleep`,
`sleepSync`, `file`, `write`, `spawn`, `spawnSync`, `serve`, `inspect`, `deepEquals`, plus
`which`/`nanoseconds`/`fileURLToPath`/`pathToFileURL`).

### 1.3 Explicit non-goals for v1 (do not build; do not partially build)

Bundler/minifier, CSS, HTML rewriter, dev server, N-API, `bun:ffi`, `bun:sqlite`, WebSocket,
HTTP/2/3, shell language (`Bun.$`), workers, macros, `--compile`, watch/hot reload, snapshots,
coverage, mocks (v1), `clun x`/bunx, REPL, JSX/`.tsx`, sourcemaps (by design — whitespace-
preserving TS strip makes them unnecessary), Proxy/Reflect, Intl, Temporal, Atomics/SAB,
`node:stream`/`net`/`http`/`crypto`/`child_process`/`worker_threads`/`vm`/`zlib`, workspaces,
git/file dependencies, lifecycle scripts (never executed — stricter than Bun), and Windows.
Linux and macOS 13+ release builds target x86-64 and arm64; platform-specific APIs may remain partial.
If a v1 task appears to require one of these non-goals, it doesn't — rescope and
record why in `DECISIONS.md`. Post-v1 backlog lives in Appendix E.

### 1.4 Definition of Done for v1

1. All phase gates 00–26 pass (each is a concrete command sequence).
2. test262: the checked-in pass-list contains every passing test (monotonically grown, zero
   regressions), with overall curated pass rate ≥ 90% at Phase 25's close.
3. End-to-end demo (`examples/e2e.sh`): `clun install` against the local registry fixture →
   `clun run build` (a script invoking a `.bin` tool) → `clun test` — all green, hermetic.
4. `Clun.serve` example survives 1k sequential + 500 concurrent requests, RSS plateaus.
5. One logged live smoke: `clun add ms` against real npm over pure-CL HTTPS, then run it.
6. README with install, quickstart, architecture, honest compat matrix (Appendix A), and the
   TLS security-posture statement (§3.4).
7. Tagged `v0.1.0`.

**Scale honesty:** ~65–70k LOC of new CL plus vendored pure-CL deps. Expect *hundreds* of loop
iterations. The loop protocol and state files below are what make that sustainable.

---

## 2. Execution Protocol — THE LOOP (read every session)

You (the executing agent) drive this project with a deterministic outer loop. One iteration ≈ one
phase, or one milestone of a large phase. Do not freelance outside the loop.

### 2.1 State files (the only session-to-session memory)

- `PLAN.md` — this file. Read-mostly. You may append clarifications; never rewrite intent.
- `STATE.md` — living checklist: every phase and task with `[ ]`/`[x]`, current-phase marker, a
  "Blocked" section, and a **"Next action"** line so a cold session resumes instantly. Created in
  Phase 00 by copying every task list from §5. Updated before every commit.
- `DECISIONS.md` — append-only log: dated one-paragraph entries for every architectural choice,
  library pin (name + version + SHA), fallback taken, scope call. Decision, why, alternative rejected.
- `docs/design/phase-NN.md` — written before implementing any non-trivial phase: data structures,
  ownership/lifetime notes, file layout, risks. The engine phases (01–04, 06, 10, 11) and TLS
  phase (19–20) always get one.

### 2.2 The loop

```
while v1 not done:
  1. ORIENT   Read STATE.md and this file's section for the current phase. Pick the first phase
              whose Dependencies are all DONE. If the current phase is blocked, pick the next
              unblocked phase (§5 marks which are independent) and record why in STATE.md.
  2. DESIGN   If docs/design/phase-NN.md doesn't exist and the phase is non-trivial: spawn a Plan
              agent with the phase spec + references; distill its output into the design doc.
  3. RESEARCH As needed, spawn Explore agents (read-only) against /home/glenda/Projects/bun and
              vendored sources for behavior questions. Check Appendix C FIRST — many facts are
              already verified; do not re-derive them.
  4. BUILD    Implement task by task. After EVERY task: `make build && make test` green before
              the next task. Fan out to parallel implementer subagents ONLY for disjoint files
              (§5 marks fan-out phases); otherwise work serially in the main loop.
  5. GATE     Run the phase's Acceptance Gate exactly as written — all commands, plus
              `make purity`. For engine phases, also: zero test262 pass-list regressions.
  6. REVIEW   Code-review the phase's diff: use the code-review skill if this session has one;
              otherwise spawn a reviewer subagent prompted adversarially (§2.3). Fix findings,
              re-run the gate.
  7. RECORD   Update STATE.md (tasks, phase status, next action), append DECISIONS.md entries,
              commit `phase-NN: <summary>`. Commit only on green.
  8. LOOP     Never skip a gate. Never mark done on red. Never start a dependent phase while a
              dependency's gate is failing.
```

### 2.3 Agents, skills, and orchestration

- **Explore agents** (read-only search): all reference mining in `/home/glenda/Projects/bun`
  (its own CLAUDE.md describes the layout) and in vendored sources. Ask for conclusions with
  cited file:line, not file dumps.
- **Plan agents**: phase designs and any §3 decision that lists a fallback — have the agent argue
  both sides; you decide and log it.
- **Implementer subagents** (general-purpose): parallel fan-out for disjoint work. Give each:
  exact files it owns, the standards in §6, and the command proving its slice green. Re-run the
  full suite yourself after merging — never trust "it passes".
- **Reviewer subagents**: after every phase and after any change to the engine object kernel,
  the event loop, TLS, or tar extraction. Prompt them to hunt: condition-handling gaps
  (`ignore-errors` around fallible work), interrupt-context violations (JS or allocation in
  signal/status-hook handlers), path-discipline violations (raw namestrings), purity leaks,
  untested claims, and pass-list regressions.
- **Skills**: if the session exposes a code-review skill, use it at step 6; if a verify/run
  skill exists, use it for the serve/e2e gates. Never invent skill names — use what's listed.
- **Workflow orchestration (ultracode)**: if the session has the Workflow tool / ultracode
  enabled, use it for the fan-out-heavy steps — the node-compat module wave (Phase 12), fixture
  corpus authoring (Phases 02, 09, 21, 22), and end-of-phase adversarial review panels
  (find → independently verify each finding). If not enabled, do the same work with parallel
  Agent calls; the protocol is identical, only the mechanism differs.
- **Context discipline**: each iteration, re-read only STATE.md + the current phase section +
  its design doc + Appendix C. Don't re-read the whole plan or re-litigate settled decisions.

### 2.4 When blocked

Timebox spikes to one iteration. If a primary bet fails, execute the documented fallback (§3) and
log it — that is your decision, not a user question. Ask the human ONLY for genuine scope changes
("gate X is impossible as written because Y; propose Z"). Record open questions in STATE.md under
"Blocked" and move to the next unblocked phase rather than stalling.

---

## 3. Settled Architecture Decisions (do not relitigate; fallbacks noted)

Research verified these empirically on this exact host — evidence in Appendix C.

### 3.1 The engine (from-scratch ECMAScript in CL)

| Topic | Decision | Fallback |
|---|---|---|
| Execution | **Compile analyzed AST → CL closures** (pre-resolved variable slots; one closure per node; no per-node dispatch). Never `COMPILE`-per-function at load (measured 0.16–0.5 ms/fn → 10–25 s startup on big bundles). cl-js (`github.com/akapav/js`) is the design blueprint — study, don't vendor (it's ES3) | Hot-function tiering via `COMPILE` on a background thread (P25); plain tree-walker for `with`-containing functions if the emitter fights |
| Strings | **CL strings, one character = one UTF-16 code unit** (astral → surrogate pairs; lone surrogates are legal SBCL chars — verified). `.length` = `length`. UTF-8⇄code-units (WTF-8 for lone surrogates) at host boundaries only | `(unsigned-byte 16)` vectors if memory (4 B/unit) ever dominates — costs bespoke hashing/printing/regex bridge |
| Numbers | `double-float` + `sb-int:with-float-traps-masked (:overflow :invalid :divide-by-zero)` at engine entry points (verified: Inf/NaN/−0 correct). Int32 ops via `(ldb (byte 32 0) …)` + sign fix. NaN via `sb-ext:float-nan-p`. **BigInt IN, late phase** (CL bignums make it cheap). Number→String: **port Ryū** (naive bignum shortest-round-trip as fallback). Emitter must never emit constant-foldable trapping float literals (SBCL folds at compile time — verified) | Per-operation trap wrapping (cl-js's `wrap-js`) if entry-point masking leaks through callbacks |
| Object model | Spec internal-methods protocol ([[Get]]/[[Set]]/[[GetOwnProperty]]/[[DefineOwnProperty]]…) as struct-dispatched functions, **deliberately Proxy-shaped** for post-v1. v1 storage: per-object property table (small simple-vector → `equal` hash-table promotion), full descriptors, prototype as struct slot. **Structs, never hash-table-per-object** (measured 4× memory + 2.7× GC win). Arrays: dense adjustable vector + sparse hash overflow. Shapes/inline-caches deferred to Phase 25 behind the protocol (cl-js's scls/hcls proves the design) | Lift cl-js's shape tree early if property-table perf blocks a gate |
| Scoping/modes | Parser does full scope analysis (hoisting, let/const slot indices, TDZ sentinel, eval/with/arguments flags); frames are simple-vectors; `with`/direct-eval scopes use hash-backed slow frames. **Strict AND sloppy from day 1, including `with` and direct eval** — test262 runs both modes; npm CJS is sloppy | None — design constraint, not a bet |
| Async/generators | **Regenerator-style state-machine lowering** as an AST→AST pass before closure emission (hoisted locals, `switch(state)` loop, try-entry tables — copy `facebook/regenerator`'s scheme exactly). Engine owns the microtask/job queue; async generators & for-await desugar per spec | Thread-per-generator (sb-thread + semaphore handoff) — semantically safe, slow; acceptable for rare generators if lowering is buggy |
| RegExp | v1: own JS-regex parser → **CL-PPCRE parse trees** (pure CL, zero deps — verified; supports fixed-length lookbehind, named groups, backrefs, `:start` for lastIndex/sticky). Documented gaps that **error loudly** (SyntaxError), never silently mismatch: variable-length lookbehind, `\p{…}` until own UCD tables. Known silent gap to fix earliest: unparticipated-group backrefs (PPCRE fails where JS matches empty — verified) | Phase-25+ own backtracking VM over code-unit strings; the regex parser and RegExp object survive the swap |
| Unicode data | **Own build-time UCD table generator** (vendor current Unicode data files, emit Lisp tables). cl-unicode is Unicode 6.2 (2012) — reference for technique only | — |
| Conformance | Vendor **test262 pinned @ `d1d583d`** (53,690 test files measured): `harness/` + `test/language/**` + built-ins for implemented globals. Skip by `features:` tags (Proxy, Reflect, Temporal, Atomics, SharedArrayBuffer, Intl…) and `$262.createRealm`. Own runner: ~200-LOC YAML-frontmatter parser per test262 INTERPRETING.md; default = run each test in both sloppy+strict; async via `doneprintHandle.js`. **Gate mechanism: checked-in sorted pass-list — CI fails if any test leaves it; it only grows** | Skip-list polarity if curation churns |
| v1 language tier | ES2017-ish: full ES2015 minus Proxy/Reflect/tail-calls, plus async/await, `**`, Object.entries/values, trailing commas; Symbols incl. iterator/toPrimitive/toStringTag/hasInstance; BigInt (late); no Intl/Temporal/Atomics. Per-realm intrinsics indirection designed in from Phase 03 (cheap now, painful later) | Proxy/Reflect is the v1.1 headline |
| Date/TZ | UTC-correct core in Phase 04; pure-CL TZif (`/etc/localtime`) parser as a Phase 26 task, deferrable to post-v1 with `getTimezoneOffset() = 0` documented | — |

### 3.2 The substrate (event loop, I/O — pure SBCL)

| Topic | Decision | Fallback |
|---|---|---|
| Event loop | **Hybrid**: one JS thread owns the heap, timers, microtasks, and a `serve-event`-based reactor for sockets & child pipes (poll backend verified — no 1024-fd cap on this build; startup capability probe required); small worker pool (sb-thread) for blocking ops (DNS, async fs, TLS v1); completions via `sb-concurrency:mailbox` + **self-pipe wakeup** (signals do NOT wake serve-event — verified). fd/signal handlers **enqueue only** — JS runs solely at loop dispatch points, each followed by a full microtask drain, with `process.nextTick`'s dedicated queue drained first | All-blocking-I/O-on-workers model (simpler, 2 context switches per op) if reactor integration stalls |
| Timers | **Own binary-heap timer queue**; loop timeout = `min(next-timer − now, cap)`. `sb-ext:timer` is unusable for JS callbacks (runs via `interrupt-thread`, unspecified thread, interrupts disabled — verified docstring) | — |
| Lifetime | Handle refcounting (listeners, sockets, ref'd timers, in-flight work, child watchers); loop exits at refs=0 ∧ queues empty. `ref()`/`unref()` are real | — |
| Paths | **Every user-supplied path goes through `sb-ext:parse-native-namestring`/`native-namestring`** — raw strings with `[` crash SBCL pathname parsing (verified). CI grep-gate for raw namestring constructors outside `src/sys/` | — |
| Files | `sb-posix` (coverage verified near-complete) + CL streams (11 GB/s cached reads measured — not a bottleneck). realpath via `truename` with dangling-symlink handler. mtime is second-granularity (no nanosec in sb-posix) — documented. No inotify → `fs.watch` is out of v1 | readlink-loop realpath |
| Processes | `sb-ext:run-program :wait nil` (verified: `:stream` pipes, `process-kill`, `:status-hook` fires in interrupt context, zombies auto-reaped, fds closed-by-default + `:preserve-fds`). status-hook enqueues to mailbox + self-pipe only. Pipe fds go non-blocking into the reactor | Worker-thread blocking pipe drains |
| Signals | `sb-sys:enable-interrupt` handlers: push to queue + 1 byte to self-pipe, nothing else (handlers run in arbitrary threads — verified). SIGPIPE already neutralized by SBCL (write-to-closed-peer → catchable `SB-INT:BROKEN-PIPE` — verified) | Flag polled each loop iteration |
| HTTP server | Event-driven on the JS-thread reactor, non-blocking sockets, **own incremental HTTP/1.1 parser** (~1k LOC; study fast-http and Hunchentoot's taskmaster/shedding — both pure-CL, neither fits the reactor). Keep-alive, chunked both ways, 16KB header / configurable body limits (fail 431/413), graceful shutdown, port 0 via `socket-name`. Substrate ceiling measured 325k req/s — target ≥30k with real parsing | Thread-per-connection with cap (measured fast) + handler marshaling to the JS thread |
| HTTP client | Same reactor; pool keyed `(host, port, family, tls-config)`; connect/header/body timeouts via the timer heap; gzip via chipz; redirects follow (max 20, drop auth cross-origin) | Blocking client on worker pool for v1 fetch |
| DNS | v4 via `sb-bsd-sockets:get-host-by-name` on the worker pool (blocking; no getaddrinfo in SBCL — verified). IPv6 literals parsed in-process; AAAA lookup is post-v1 | Pure-CL DNS resolver (verify `dns-client` purity first) post-v1 |
| GC discipline | Never `gc :full` on hot paths; minor GCs measured 2–4 ms at 1 GB live; struct-based objects keep the heap small. Internal SBCL APIs (`sb-unix:unix-realpath`, `fd-stream-fd`) isolated in one `src/sys/sbcl-compat.lisp` | — |

### 3.3 TypeScript (type stripping, not transpilation)

Node/amaro semantics exactly: erase annotations, `interface`, `type`, generics, `as`/`satisfies`,
non-null `!`, `declare`, `import type`/`export type` + type-only specifiers, `implements`,
`abstract`, accessibility modifiers, overload signatures, type-only namespaces — each replaced by
**exact-length whitespace preserving newlines**, so line *and column* survive with **no
sourcemaps**. Hard error (mirroring `ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX`) on: `enum`,
namespace/module with runtime code, parameter properties, `import x = require()` / `export =`,
all decorators. `.ts`/`.mts`/`.cts` only; `.tsx` rejected. No cross-file analysis
(verbatimModuleSyntax semantics). The stripper **shares the engine lexer** (which therefore needs:
exact token offsets, parser-driven regex-vs-divide, template mode stack, trivia retention, no
global state). Note: Bun transpiles enums — this divergence is a documented 🟡 in the matrix.

### 3.4 TLS & crypto (the enabling discovery)

**Vendor [pure-tls](https://github.com/atgreen/pure-tls)** (MIT, actively maintained, TLS 1.3
client+server in pure CL atop ironclad: own ASN.1/DER + X.509 chain validation, SAN/wildcard
hostname matching, Linux trust store, RFC 8448 + OpenSSL-interop test suites) plus a **~40-line
purity patch**: its dep `cl-cancel` → `precise-time` calls `cffi:foreign-funcall("clock_gettime")`
on Linux — replace with `sb-unix:clock-gettime`/`get-internal-real-time`, and strip the
`:if-feature :windows/:darwin` CFFI verify files from the vendored tree. Ironclad (pure CL on
SBCL — its SBCL fast paths are Lisp VOPs) covers every primitive; pure-tls already composes the
two gaps (ChaCha20-Poly1305 AEAD, PKCS#1 v1.5 verify). Default cipher preference:
TLS_CHACHA20_POLY1305_SHA256 (ARX — friendlier to constant-time pure Lisp than table-based AES).
Randomness: ironclad `os-prng` (/dev/urandom via plain CL streams — verified pure).

Live npm over plain HTTP is **dead** (verified: registry.npmjs.org and npmmirror 301→HTTPS
including tarball paths). So TLS is on the v1 critical path for live installs; all install
*tests* are hermetic against a local registry fixture regardless, and pure-tls's server side lets
tests exercise the real HTTPS client path in-process against a test CA.

**Security posture (verbatim in README and `clun install` docs):** Clun's TLS stack (pure-tls +
ironclad) is unaudited and not hardened against side-channel adversaries; package integrity is
independently enforced by SRI sha512 verification of every tarball. Treat HTTPS as experimental.
Certificate errors always fail closed.

From-scratch TLS fallback (only if vendoring fails): x25519 + ChaCha20-Poly1305 + minimal X.509 —
~6–9k LOC, high risk. The plan bets on vendoring precisely to avoid this.

### 3.5 Package manager

npm registry protocol with `Accept: application/vnd.npm.install-v1+json` (abbreviated metadata —
field list verified against npm/registry docs); scoped names URL-encode as `@scope%2Fname`.
Own semver port conformance-tested against **node-semver's fixtures** (ISC — vendorable).
**Hand-rolled read-only ustar/pax tar reader** (~300–450 LOC; cl-tar's extraction needs
osicat/CFFI — disqualified) with the full path-traversal hardening suite of §5/Phase 22.
SRI sha512 verified **before** extraction commits (extract to temp dir, rename in). Hoisted
`node_modules` layout only; `bin` symlinks + chmod; content-addressed download cache in
`~/.clun/cache/`. `clun.lock`: versioned JSON (resolved version, tarball URL, integrity),
deterministic ordering; `--frozen-lockfile` errors on drift. **Lifecycle scripts are never
executed** (logged at install end) — stricter than Bun, documented loudly. JSON for CL-side needs
(lockfile, registry, package.json): one hand-rolled `src/sys/json.lisp` (~400 LOC) — no extra dep.

### 3.6 Product behavior (Bun-faithful, citations in Appendix D)

- **CLI**: exact Bun spellings — `-e/--eval`, `-p/--print` (runs as ESM module `[eval]`, awaits
  promise completion values), `--cwd`, `--silent`, `-v/--version`, `--revision`; flags stop at
  the first positional so `clun run script --flag` passes through. `clun <x>` is file-first;
  `clun run <x>` is script-first. `.env` autoloaded.
- **Console/inspect**: ONE shared CL inspector powers `console.*`, `util.inspect`,
  `Clun.inspect`, and test diffs — Bun-native semantics (depth 2, `[Circular]`, double-quoted
  strings, `Map(2) { "a": 1 }` colon form, `... N more items` at 100, `empty item` holes,
  `[Function: name]`, `-0`, `123n`, `Promise { <pending> }`). Specifiers `%s %d %i %f %j %o %O %%`
  (`%c` consumed silently; `%d`-on-string follows Node's parseInt behavior — Bun's own is marked
  TODO). log/info/debug→stdout, warn/error→stderr. Colors iff TTY, `FORCE_COLOR` > `NO_COLOR`.
  Bun's `test/js/web/console/console-log.expected.txt` is a free conformance fixture.
- **Test runner**: Bun's hook order (File beforeAll → outer→inner beforeAll → outer→inner
  beforeEach → test → inner→outer afterEach → inner→outer afterAll → File afterAll); beforeAll
  failure skips scope's tests straight to afterAll; failed beforeEach still runs afterEach.
  `.skip` never runs; `.todo` runs only with `--todo` and **fails if it passes**; `.only` works
  in-file without flags; `.skipIf/.todoIf/.if`; `.only`+`CI=true` throws. `-t` is a regex over
  the space-joined describe path + name; 0 matches → exit 1. Timeout precedence: per-test arg >
  setDefaultTimeout > `--timeout` > 5000 ms (async-enforced; runaway sync tests documented as
  non-preemptible). Reporter: `(pass)|(fail)|(skip)|(todo) outer > inner > name [1.23ms]` lines,
  `- Expected/+ Received` LCS line diffs, Bun's summary block, exit 0/1 (1 also on zero tests).
  Matchers (~22): toBe, toEqual, toStrictEqual, toBeTruthy/Falsy/Null/Undefined/Defined/NaN,
  toBeInstanceOf, toBeGreaterThan/LessThan(OrEqual), toBeCloseTo, toMatch, toContain(Equal),
  toHaveLength, toHaveProperty, toMatchObject, toThrow (class/message/regex), `.not`,
  `.resolves`/`.rejects` (Jest async semantics — returned promise must be awaited; we do NOT
  replicate Bun's sync loop-pumping), expect.assertions/hasAssertions. No snapshots/mocks in v1.
- **Scripts**: `/bin/sh -c`; PATH = script pkg dir + `node_modules/.bin` for **every ancestor of
  cwd** + original PATH; `pre`/`post` scripts run (failing pre aborts); `npm_lifecycle_event`,
  `npm_package_name/version/json`, `npm_config_user_agent`, `npm_execpath` env vars; exit code
  propagates. Divergence: always `/bin/sh` (Bun searches bash first) — documented.
- **process**: argv `[execPath, scriptAbsPath, ...]`; `process.env` is a **plain object**
  snapshot (no exotic interceptor — coerce at spawn/read boundaries; documented divergence);
  `nextTick` gets a dedicated pre-microtask queue; `process.versions.node` pinned to the Node LTS
  whose docs we target (record in DECISIONS.md).
- **Module resolution ownership**: the Node resolution algorithm is a standalone pure-CL library
  (`src/resolver/`, no engine dependency, maximally unit-testable); the engine's loader hooks and
  the CJS `require` both call it.

### 3.7 Repository layout (created in Phase 00)

```
clun/
├── PLAN.md  STATE.md  DECISIONS.md  README.md  LICENSE (GPL-3.0-or-later)
├── clun.asd  Makefile                          # build | test | purity | bench | clean
├── scripts/            build.lisp (save-lisp-and-die), purity-scan.lisp, gen-unicode-tables.lisp
├── vendor/             cl-ppcre/ ironclad/ pure-tls/ (+patched cl-cancel + dep closure)
│                       chipz/ cl-base64/ parachute/ …   (pinned; Appendix B)
├── vendor-data/        test262/ (pinned slice)  ucd/  semver-fixtures/  ts-strip-fixtures/
├── src/
│   ├── main.lisp       toplevel: argv dispatch, condition→exit-code, --backtrace flag
│   ├── cli/            arg parsing (per-command), help/version, .env loader
│   ├── sys/            pathname discipline, json.lisp, errors, sbcl-compat.lisp, platform
│   ├── engine/         lexer/ parser/ analyzer/ emitter/ objects/ (kernel+descriptors)
│   │   stdlib/ (Object, Array, String, JSON+ryu, Math, Date, Map…) regexp/ (parser+ppcre bridge)
│   │   async/ (lowering, promises, jobs) modules/ (ESM linking, CJS) values.lisp conditions.lisp
│   ├── loop/           reactor.lisp, timers.lisp, mailbox.lisp, handles.lisp, signals.lisp, workers.lisp
│   ├── resolver/       pure-CL Node resolution (no engine dep)
│   ├── transpiler/     TS strip (shares engine lexer)
│   ├── runtime/        globals wiring, console/inspector, process, timers-js, clun-global,
│   │                   node/ (path fs events buffer os util url querystring assert …)
│   ├── net/            sockets.lisp, http-parser.lisp, server.lisp (Clun.serve), client.lisp,
│   │                   fetch.lisp, tls-integration.lisp
│   ├── test-runner/    discovery, scheduler, matchers, diff, reporter
│   └── install/        semver.lisp registry.lisp tarball.lisp integrity.lisp linker.lisp
│                       lockfile.lisp cache.lisp scripts-run.lisp
├── tests/
│   ├── lisp/           parachute suites mirroring src/
│   ├── conformance/    test262 runner + pass-list.txt (checked in, sorted)
│   ├── js/             clun-run fixtures (stdout/exit-code harness; later migrated to clun test)
│   └── fixtures/       resolution-trees/ registry/ (local npm fixture) tarballs/ certs/ (test CA)
├── examples/           serve.ts, e2e.sh
└── docs/design/        phase-NN.md; benchmarks.md
```

---

## 4. (reserved — section intentionally folded into §3; do not renumber)

---

## 5. Phases

Every phase lists Dependencies, objective, tasks (seed STATE.md from these), and an **Acceptance
Gate** (`make` targets — literal commands, all of them, plus `make purity` always). LOC figures
are informed estimates, not promises. Phases marked ⚡ are fan-out-friendly (disjoint files —
parallel subagents / ultracode). Phases marked ◇ are **independent early**: pull them forward
whenever the main track is blocked.

---

### Phase 00 — Scaffold, toolchain, purity gate  *(deps: none)*
Objective: empty-but-real project; every later gate has rails.
Tasks: `.gitignore`/LICENSE/README stub; `clun.asd` + package skeletons per §3.7; `Makefile`
(`build` → `build/clun` via save-lisp-and-die, `test`, `purity`, `clean`); `scripts/purity-scan.lisp`
(ASDF plan + vendored source scan per §1.1); vendor + pin cl-ppcre, parachute (record versions/SHAs
in DECISIONS.md); parachute smoke suite; `tests/js/` stdout/exit-code harness design
(docs/design/phase-00.md); GitHub Actions (ubuntu, pinned SBCL, `make build test purity`);
**create STATE.md seeded with every task list in this §5**; seed DECISIONS.md with §3's pins.
**Gate:** `make build` → `./build/clun --version` prints `clun 0.0.1-dev`; `make test` green;
`make purity` green; fresh-clone build documented.

### Phase 01 — Engine values & coercions  *(deps: 00)* ~2k LOC
Objective: the value substrate everything sits on.
Tasks: value representation decision (keywords vs tagged structs — micro-benchmark typecase
dispatch, log in DECISIONS.md); UTF-16-code-unit strings + UTF-8/WTF-8 boundary converters;
doubles + trap-mask entry macro; NaN/Inf/−0 helpers; JS-exception-as-CL-condition bridge;
ToPrimitive/ToNumber/ToString/ToInt32/ToUint32/ToBoolean kernel.
**Gate:** parachute suites over every abstract-op edge (NaN, −0, "", "0x10", huge strings);
UTF-8⇄code-unit round-trips incl. lone surrogates.

### Phase 02 — Lexer + parser + scope analysis  *(deps: 01)* ~7k LOC ⚡(fixture authoring)
Objective: source → analyzed AST; the lexer doubles as the TS-strip lexer (§3.3 requirements).
Tasks: tokenizer (ASI newline flags, parser-driven regex-vs-divide, template mode stack, all
escapes, exact offsets, trivia retention, no global state); full ES2017 parser (classes,
destructuring, arrows, generator/async syntax, modules, spread, computed props); scope analyzer
(hoisting, slot indices, TDZ, eval/with/arguments flags, strict directives); AST printer;
**vendor test262 slice pinned @ `d1d583d`** + frontmatter parser + runner skeleton.
**Gate:** parse all vendored `language/**` without crashes; all `negative:{phase:parse}` →
SyntaxError; token-span property test (slice source by spans ≡ token text).

### Phase 03 — Core evaluator + object kernel  *(deps: 02)* ~8k LOC
Objective: run ES5-ish code, both modes; conformance machinery live.
Tasks: closure emitter; frames + TDZ sentinel; slow frames (with/direct eval); property tables +
full descriptors + defineProperty machinery; prototype chains; per-realm intrinsics indirection;
functions (call/construct, `this` both modes, arguments incl. sloppy aliasing); Array exotic;
operators (`==` table, `+`, relational, instanceof, in, typeof, delete); try/catch/finally,
labels, switch, for-in order; Error objects with `.stack`.
**Gate:** curated `language/` slice (minus generators/async/modules) ≥ 70% both modes;
**pass-list workflow live in CI from here on** (`make conformance` fails on any regression).

### Phase 04 — Stdlib core  *(deps: 03)* ~9k LOC ⚡
Objective: the globals real code touches first.
Tasks: Object, Function, Array (ES2017 methods), String (code-unit exact), Number, Boolean, Math,
JSON (own parser/printer + **Ryū port** for Number→String, known-answer vectors), Error hierarchy,
Symbol + well-knowns, Map/Set/WeakMap/WeakSet (SBCL weak tables), iterator protocol, Date (UTC
core; TZif deferred per §3.1), global wiring, `eval`/`Function` (parser is in-image).
**Gate:** built-ins slices for these globals ≥ 65%; overall curated ≥ 55%; Ryū vectors pass.

### Phase 05 — Event loop core  *(deps: 01; independent of 02–04)* ◇ ~2.3k LOC
Objective: the reactor per §3.2.
Tasks: serve-event wrapper + startup capability probe (poll backend, fd>1023); self-pipe; mailbox
integration; binary-heap timers; handle refcounting + ref/unref; signal delivery (enqueue-only);
worker pool; graceful stop.
**Gate:** timer-ordering tests; cross-thread wake < 5 ms; process alive iff refs>0; SIGINT →
loop event; microtask-drain points honored (stub queue).

### Phase 06 — Async engine: generators, promises, modules  *(deps: 04, 05)* ~2.5k LOC
Objective: modern control flow + ESM.
Tasks: regenerator-style lowering (state machine + try-entry tables — copy the scheme exactly);
Generator objects; Promise + job queue (engine-owned, drained at loop dispatch points; nextTick
queue ahead of microtasks); async functions; for-await; async generators; ESM linking +
evaluation + TLA; unhandled-rejection tracking → error + exit 1; async-test262 runner support.
**Gate:** Promise/generator/async/for-await-of 262 dirs ≥ 75%; zero regressions; ordering
corpus (microtask vs timer vs nextTick) passes.

### Phase 07 — Module resolution & CJS  *(deps: 06)* ~2.5k LOC ⚡(fixtures)
Objective: run real multi-file projects from `node_modules`.
Tasks: `src/resolver/` pure CL (relative/absolute/bare, extension probing, directory index,
`main`/`exports`/`imports` conditions, self-refs, scoped, symlink realpath) + ~40-tree fixture
corpus (engine-free parachute tests); loader-hook wiring; CJS `require` (Node wrapper-function
idiom, cache, cycles→partial exports, `.cjs`/`.mjs`/`"type"` gating); ESM↔CJS interop (import-of-
CJS = default export only — documented 🟡; require-of-ESM errors clearly); JSON modules;
`import.meta.url/dirname/filename/main`.
**Gate:** resolution corpus green; fixture app (ESM entry importing CJS dep from hand-placed
node_modules with exports maps + scoped pkg) runs.

### Phase 08 — CLI shell, console, process  *(deps: 07)* ~3k LOC
Objective: `clun` feels like a real CLI.
Tasks: dispatcher + exact flags per §3.6 (`-e`/`-p` as `[eval]` module, positional-stop, `--cwd`,
`--silent`, `--revision`, `--backtrace`); `.env` autoload; **the shared inspector** + full console
spec (§3.6); process core (argv/env/exit/exitCode/platform/arch/pid/cwd/chdir/versions/
stdout.write/stderr.write/isTTY/hrtime/memoryUsage/on('exit')); uncaught-error rendering (message
+ JS stack, exit 1; no Lisp backtrace without `--backtrace`); exit codes 0/1/2(usage).
**Gate:** run/eval fixture matrix (exit codes, stacks, `-p` awaiting a promise); console
conformance vs the Bun expected-output fixture subset (document each deliberate divergence).

### Phase 09 — TypeScript stripping  *(deps: 08)* ~2.5k LOC ⚡(corpus)
Objective: `.ts` runs; non-erasable syntax errors exactly like Node.
Tasks: strip pass per §3.3 sharing the engine lexer; error catalog (enum/namespace/param-props/
decorators/`import =`); `.tsx` rejection; ≥ 60-pair corpus (vendor amaro/TS-conformance fixtures,
licenses noted) incl. adversarial (`<` ambiguity, generics in arrows, multi-line annotations);
loader wiring for `.ts/.mts/.cts`.
**Gate:** corpus green; stack-trace property test — strip → run → throwing line:col identical to
source; each catalog error fires with the documented message.

### Phase 10 — RegExp  *(deps: 04)* ~3k LOC
Objective: working RegExp for real-world code, honestly scoped.
Tasks: JS regex parser → own AST; AST → CL-PPCRE parse trees (own group numbering, named-group
map, i/m/s flags; `u` via regexpu-style down-translation over code-unit strings); RegExp object
(lastIndex, exec/test, indices); String match/matchAll/replace/replaceAll/split/search with `$1`/
`$<name>` templates; loud SyntaxError for documented gaps (§3.1); UCD table generator for later
`\p{…}`.
**Gate:** `built-ins/RegExp/**` ≥ 60% with gaps enumerated in the expectations file; String
regex methods ≥ 75%; zero regressions.

### Phase 11 — Binary data + BigInt  *(deps: 04)* ~3k LOC
Objective: what Buffer and fetch will need.
Tasks: ArrayBuffer (ub8 vectors), DataView + all TypedArray kinds (ldb/dpb byte assembly;
`sb-kernel:make-double-float` fast path), detach semantics; TextEncoder/TextDecoder (UTF-8);
BigInt (literals, ops, ToBigInt, mixing TypeErrors, toString radix, BigInt64Array).
**Gate:** TypedArray/DataView/BigInt curated slices ≥ 65%; overall curated ≥ 80%.

### Phase 12 — Node-compat wave 1 (sync)  *(deps: 08; 10 for assert.match)* ~4k LOC ⚡⚡
Objective: the engine-light stdlib floor. **This is the flagship fan-out phase** — one subagent
per module, disjoint files, each ships module + conformance tests.
Tasks: node:path (posix; win32 present-but-throwing), node:os, node:querystring (null-prototype
parse), node:util (format/formatWithOptions/inspect→shared/promisify+custom/callbackify/inherits/
deprecate/isDeepStrictEqual/types subset/stripVTControlCharacters), node:events (full sync
EventEmitter per §3.6 subtleties: snapshot iteration, once-wrapper removal, newListener-before-
insert, error-throw, errorMonitor), node:assert (strict family, throws/match, AssertionError with
shared inspector), `Clun.inspect/deepEquals/which/nanoseconds/fileURLToPath/pathToFileURL`;
`structuredClone` (JSON-grade); `crypto.randomUUID`/`getRandomValues` (ironclad os-prng — vendor
ironclad here with KATs, fronting Phase 19).
**Gate:** per-module conformance suites (values asserted exactly, derived from Node docs);
kitchen-sink fixture runs identically under `node` where semantics are shared (divergences → matrix).

### Phase 13 — Files: fs substrate + node:fs + Buffer surface  *(deps: 11, 12; loop 05 for async)* ~4.5k LOC
Objective: real file work.
Tasks: `src/sys` fs layer (path discipline per §3.2, errno→`.code/.errno/.syscall/.path` errors,
worker-pool async); node:buffer (Buffer extends Uint8Array; alloc/from/concat/compare/copy/fill/
indexOf/subarray/toString+write with utf8/ascii/latin1/hex/base64/base64url/utf16le; numeric
read/write family); node:fs sync core (23 fns per research list), fs/promises (14), callback
shims; Stats/Dirent/constants; `Clun.file`/`Clun.write` (lazy file, createPath default);
mkdtemp/tmp helpers for tests.
**Gate:** ~60-case fs conformance incl. `has[bracket].txt`-class paths, symlink chains, ENOENT
codes; Buffer encode/decode known-answer vectors; Clun.file lazy semantics fixtures.

### Phase 14 — Async product wave  *(deps: 06, 12, 13)* ~1.5k LOC
Objective: the async floor for the runner and servers.
Tasks: timers globals + Timer ref/unref real loop accounting + node:timers + timers/promises;
process.nextTick dedicated queue wiring; events.once + captureRejections; assert.rejects/
doesNotReject; Clun.sleep/sleepSync; queueMicrotask; AbortController/AbortSignal.
**Gate:** extended ordering corpus (nextTick vs microtask vs timer vs immediate) exact-output;
unref'd-timer process-exit test; abort fixtures.

### Phase 15 — Test runner  *(deps: 14; 10 for `-t`)* ~4k LOC
Objective: `clun test` per §3.6, good enough to self-host.
Tasks: discovery (`*.test.*`/`*_test.*`/`*.spec.*`/`*_spec.*`; positional substring filters);
collection + hook scheduler (exact ordering + failure semantics); modifiers incl. only-bubbling
and CI-guard; matchers (~22) on shared deepEquals/inspector; `.resolves/.rejects` (Jest-async);
timeout machinery; reporter + diffs + summary + exit codes per §3.6; `--bail`, `--todo`;
**self-hosting migration**: move `tests/js/` conformance suites onto `clun test` where the
expect-model fits (keep the stdout harness for ordering/exit-code cases); meta-tests asserting
the runner's own output/exit codes from parachute via the built binary.
**Gate:** meta-test matrix (pass/fail/skip/todo/only/bail/zero-tests→1); hook-order fixture
byte-exact; self-hosted suites green via `make test`.

### Phase 16 — Sockets  *(deps: 05)* ◇ ~1.8k LOC
Objective: TCP handle layer on the reactor.
Tasks: non-blocking connect (EINPROGRESS)/accept/read/write with EAGAIN→NIL semantics; write
queues + backpressure; IPv6; port-0 real-port reporting; error mapping to JS-visible codes
(ECONNREFUSED…); BROKEN-PIPE handling.
**Gate:** echo server 2,000 sequential + 500 concurrent connections; `/proc/self/fd` count
stable (zero leaks); ≥ 100 MB/s single-connection loopback.

### Phase 17 — HTTP server + `Clun.serve`  *(deps: 14, 16)* ~3.5k LOC
Objective: Bun-shaped serving.
Tasks: own incremental HTTP/1.1 parser (adversarial lengths per §6); Request/Response/Headers
classes (shared with fetch); `Clun.serve({port, hostname, fetch, error})` → Server{stop(
graceful), url, port}; keep-alive, chunked both ways, limits (431/413), HEAD, date header;
`Clun.file` responses via chunked worker-pool reads; 503 shedding.
**Gate:** curl interop; malformed-request suite; ≥ 30k req/s loopback with real parsing +
JS handler; graceful shutdown completes in-flight under load; 1k-request RSS plateau;
examples/serve.ts manual browser smoke logged in STATE.md.

### Phase 18 — HTTP client, fetch, URL  *(deps: 14, 16; 11 for bodies)* ~3.5k LOC
Objective: `fetch` against real servers (plaintext; TLS next).
Tasks: WHATWG URL/URLSearchParams minus IDNA (loud "IDNA not supported" error on non-ASCII
hosts; IPv4/IPv6 host parsing; relative resolution; full percent-encode sets) + node:url +
fileURLToPath/pathToFileURL; reactor HTTP client (pool per §3.2, timeout matrix, redirects,
chunked decode, gzip via **chipz** — vendor+pin here); fetch API (Request/Response/Headers,
text/json/arrayBuffer/bytes buffered, AbortSignal, network errors → TypeError).
**Gate:** fetch vs own Phase-17 server: JSON round-trip, redirect chains, 4xx/5xx, gzip,
abort mid-flight → AbortError, timeouts within 1.5× nominal; URL corpus (WPT-derived subset).

### Phase 19 — Crypto foundation: ironclad KATs + pure-tls vendoring  *(deps: 00; ironclad landed in 12)* ◇ ~1k LOC glue
Objective: the §3.4 stack in-tree and proven.
Tasks: KAT suites (SHA-2/HMAC FIPS vectors, HKDF RFC 5869, AES-GCM NIST subset, x25519 RFC 7748,
ChaCha20-Poly1305 RFC 8439); vendor pure-tls + Linux dep closure (Appendix B) pinned; **the
cl-cancel purity patch** (replace precise-time/CFFI with sb-unix:clock-gettime); strip
windows/macos verify files; run pure-tls's own crypto/record/handshake/certificate suites in our
CI; extend `make purity` over the new tree; file the upstream patch issue (log in DECISIONS.md).
**Gate:** all KATs pass; pure-tls suites pass; `make purity` green over the full closure.

### Phase 20 — HTTPS  *(deps: 18, 19)* ~1.5k LOC
Objective: `fetch("https://…")` and the registry client's transport.
Tasks: TLS streams integrated via worker pool (blocking gray-stream handshake/IO off the JS
thread; reactor-native TLS is post-v1); trust store (system PEM bundle, `SSL_CERT_FILE`/
`SSL_CERT_DIR` overrides); hostname verification; connection-pool keys gain TLS config
(monotonic — never downgrade); test CA + in-process pure-tls **server** fixtures; negative
matrix; posture labeling (§3.4) in README + errors.
**Gate:** hermetic HTTPS round-trip against in-process server w/ test CA (chain + hostname
exercised); negative tests — expired, wrong hostname, self-signed, bad chain each fail closed
with distinct errors; one live smoke (`fetch("https://registry.npmjs.org/left-pad")` → parseable
JSON) executed once and logged in STATE.md.

### Phase 21 — Semver + registry client + local registry fixture  *(deps: 00 for semver; 18 for client)* ◇(semver) ~2.5k LOC ⚡(fixtures)
Objective: the install pipeline's front half, hermetic-first.
Tasks: semver port (versions, prerelease precedence, ranges `^ ~ - || * x`, includePrerelease) +
**vendored node-semver fixture corpus at 100%** (deviations enumerated); registry client
(abbreviated-metadata Accept header, scoped `%2F` encoding, retries, `--registry` override,
`.npmrc`-lite); **local registry fixture** (`tests/fixtures/registry/`): in-process server
(HTTP; HTTPS variant once 20 lands) serving metadata + hand-built `.tgz` for ~8 fake packages
with real semver/dep relationships incl. a version conflict forcing nesting, a scoped package, a
`bin`-bearing package, a pax-longname package; tarball URLs templated to the server's base;
`dist.integrity` computed from real bytes; gzip + ETag/304 paths.
**Gate:** semver corpus 100%; metadata round-trips incl. scoped/gzip/304; fixture server
reusable as a `make` target for later phases.

### Phase 22 — Tarball + integrity  *(deps: 13; 21 for fixtures)* ◇ ~700 LOC
Objective: safe extraction.
Tasks: streaming chipz-inflate → hand-rolled ustar/pax reader (pax `path`/`linkpath`/`size`
overrides, gnu `L` longname, `package/` prefix strip, mode-bit capture); SRI sha512
verify-then-commit (temp dir + rename); content-addressed cache.
**Gate:** real-package corpus (lodash-scale fixture, bin package, pax-longname) extracts
correctly; **mandated traversal suite** — absolute names, `..` plain/embedded/via-pax-path,
longname `..`, symlink-escape then write-through, hardlink escape, pax linkpath escape, NUL/
empty/`.` names, device/FIFO entries rejected, setuid stripped, size-field overflow + base-256,
duplicate entries last-wins, header-before-pax ordering — every case rejected/handled per spec.

### Phase 23 — Install: resolver, linker, lockfile, CLI  *(deps: 20, 21, 22)* ~4k LOC
Objective: `clun install` / `add` / `remove` for real.
Tasks: breadth-first resolution (highest-satisfying, cycle-safe), hoisted layout + nested
conflict dirs, `os`/`cpu` optional-dep filtering; `bin` symlinks + chmod into `node_modules/.bin`;
`clun.lock` (versioned JSON, deterministic order) honored when fresh; `--frozen-lockfile` drift
error; `add`/`remove` edit package.json (`-d/-D`, `-E/--exact`) + reinstall; `--dry-run`,
`--production`, `--no-save`; lifecycle scripts skipped + logged; hoist-conflict honest error.
**Gate:** fixture-graph e2e — install → `clun run` an app importing results → exact output;
delete node_modules → reinstall from lock offline (fixture server down) → byte-identical lock;
frozen-mode drift errors; live smoke `clun add ms` in a tmp dir behind an opt-in flag, logged.

### Phase 24 — Spawn + package scripts  *(deps: 14; 23 for e2e)* ~2k LOC
Objective: the daily-driver workflow.
Tasks: `Clun.spawn` (run-program wrapper: cmd/cwd/env, stdin/stdout/stderr pipe|inherit|ignore,
pipes non-blocking into the reactor, `.exited` promise, exitCode/signalCode, kill, onExit) +
`spawnSync`; `clun run <script>` per §3.6 (sh -c, ancestor `.bin` PATH walk, pre/post, npm_* env,
`--if-present`, arg passthrough after script name); dispatcher merge (script-first vs file-first).
**Gate:** spawn matrix (echo/cat/exit/signal); **10 MB dual-pipe child drained concurrently
without deadlock**; 1,000 spawns → zero zombies; scripts fixture (pre-fail aborts, env vars
asserted, exit propagation); `examples/e2e.sh` (install → run build via `.bin` tool → clun test)
green and hermetic — this is the v1 workflow demo.

### Phase 25 — Performance pass  *(deps: all engine phases)* ~3k LOC
Objective: close the gap toward cl-js-era performance claims; no correctness cost.
Tasks: shapes (cl-js scls/hcls-style tree + dict fallback) behind the storage protocol; inline
caches at property sites in emitted closures; direct call paths for known arities; string-builder
for `+=` loops; optional `COMPILE` tiering (background thread) — measure first; benchmark suite
(Richards/DeltaBlue/splay ports) + `docs/benchmarks.md` (honest: startup vs node, serve req/s,
install time; methodology recorded; no marketing).
**Gate:** conformance pass-list unchanged or grown; ≥ 5× on the benchmark suite vs Phase-24
baseline; overall curated test262 ≥ 90%.

> **SCOPE AMENDMENT (2026-07-14, operator-approved):** the `curated test262 ≥ 90%` clause is SPLIT
> OUT of Phase 25 into a new **Phase 25b** (below). Phase 25's gate is therefore **only**: pass-list
> unchanged or grown + ≥ 5× on the benchmark suite. Rationale: ≥ 90% is a ~2,700-test *correctness*
> lift (curated is ~80.4% at Phase-25 start) with no engineering relationship to the shapes/inline-
> cache *performance* work — coupling them would block a finished perf win on unrelated conformance
> fixes. DoD §1.4 point 2's "≥ 90% at Phase 25's close" now reads "at Phase 25b's close". Recorded in
> DECISIONS.md.

### Phase 25b — Conformance push to ≥ 90%  *(deps: 25)*
Objective: lift overall curated test262 from ~80.4% to ≥ 90% (DoD §1.4 point 2), correctness only.
Tasks: bucket the ~5,520 `fail(gap)` tests by feature/subsystem (a small analysis pass over the
runner output) to estimate cost and order the work; then targeted correctness fixes bucket by bucket
(no performance work); grow the checked-in pass-list monotonically. Faster iteration because the
Phase-25 engine is quicker. **Gate:** overall curated test262 ≥ 90%; zero pass-list regressions
(monotonic); `make purity` clean. (May itself be milestoned; the bucket analysis is milestone 1.)

### Phase 26 — Hardening, docs, release  *(deps: everything)*
Objective: shippable v0.1.0.
Tasks: error-message audit (every user-reachable failure: named resource, violated constraint
with rejected value, `note:` remedy; no Lisp backtraces without `--backtrace`); stress pass
(50k-eval loop, long-run serve, biggest fixture tree ×20 — RSS plateaus); Ctrl-C mid-serve/
mid-install exits cleanly, partial installs don't corrupt; TZif local-time task (or explicitly
defer with matrix note); README (what/why, install-from-source, quickstart, architecture, compat
matrix from Appendix A, TLS posture, contributing); CI release jobs (Linux/macOS, x64/arm64);
final adversarial review sweep over the whole tree (§2.3 reviewer profile; ultracode panel if
available); triage → fix safety/error-path findings, log style findings.
**Gate:** §1.4 Definition of Done, every item checked with evidence links in STATE.md; tag `v0.1.0`.

---

## 6. Cross-cutting Engineering Standards (enforced at every review)

**Testing**
- Every behavioral change ships an automated test in the same commit. "Verified manually" counts
  only where a gate explicitly says so, logged in STATE.md.
- Hermetic: no external network anywhere except the two logged live smokes; no leftover tmp
  files (`unwind-protect` cleanup registered before assertions); ephemeral ports only, read the
  real one; no order dependence.
- Never sleep-and-check; await the condition. For "X does not happen", poll a bounded window.
- Assert the strongest invariant: exact values/strings, error condition TYPE + message. For each
  fix, spot-check that reverting it fails the new test (note in the phase commit).
- Subprocess tests drain all pipes concurrently with awaiting exit.
- test262 pass-list discipline: the list is sorted, checked in, and only grows; any test leaving
  it fails CI; never hand-edit it to green a build.

**Lisp/runtime safety (this project's equivalent of memory safety)**
- Interrupt-context iron rule: signal handlers and `:status-hook` bodies only enqueue + write the
  self-pipe. No JS, no locks, no allocation-heavy work. Reviewer hunts violations every phase.
- Path discipline: `parse-native-namestring`/`native-namestring` at every user-path boundary;
  CI grep-gate outside `src/sys/`.
- Float-trap discipline: engine entry points masked; the emitter never emits constant-foldable
  trapping literals (regression test exists).
- Every JS-visible failure is a catchable JS error via the condition bridge; a Lisp backtrace
  reaching a user is a bug. Never bare `ignore-errors` around fallible work; map only the
  specific expected errno to a benign path.
- Adversarial lengths: every size/count from the wire, tarballs, or headers is bounds-checked
  before use; widen before multiplying; clamp to capacity (HTTP parser, tar reader, TLS records).
- GC discipline: no hash-table-per-JS-object; no `gc :full` in steady state; weak tables only
  where spec'd (WeakMap); internal SBCL APIs quarantined in `sbcl-compat.lisp`.

**Errors**
- Message style: name the resource (quoted path/URL), the violated constraint with the rejected
  value echoed, a remedy on a `note:` line. No "Please". Exit nonzero after printing.

**Code**
- Fix the whole class of a bug (grep sibling sites — parallel node-compat modules, sync/async
  twins, strict/sloppy branches) in the same commit. Delete code your change makes dead, same
  commit. One source of truth — derive, don't mirror (e.g., one inspector, one deepEquals).
- Comments ≤ 3 lines, only for invariants, ownership/lifetime contracts, and deliberate
  deviations (from Node/Bun/spec — cite the spec section or upstream line).
- Match neighboring style; consistent package-local nicknames; no `:use` beyond `:cl`.
- Every magic number derives from what it describes; protocol constants cite the RFC/spec line.

---

## 7. Risk Register (top items; full mitigations inline in §3/§5)

| Risk | L | Mitigation / fallback |
|---|---|---|
| Raw perf: closure-compiled CL is 50–500× slower than JIT JS on hot loops | Certain | Phase 25 shapes/ICs/tiering; positioning: Clun's value is purity + tooling, never speed parity |
| Async lowering correctness (try/finally × yield × return) | Med | Copy regenerator's scheme exactly; dense 262 coverage; thread-per-generator fallback is semantically safe |
| pure-tls is young, single-maintainer, unaudited | High | Vendor + pin; keep its suites in our CI; SRI sha512 independent integrity; posture labeling; fail-closed certs; MIT permits maintaining the fork |
| Purity leaks via transitive deps (one already found & patched) | Med | `make purity` in every gate; audit every `.asd` at vendor time |
| RegExp silent gaps bite real packages (unparticipated backrefs) | Med | Loud SyntaxError for the loud gaps; promote own-VM work if corpus scanning shows silent-gap frequency |
| test262 curation churn / gate gaming | Med | Pass-list only grows; reviewer checks skip-tag diffs every engine phase |
| SBCL internals churn (`unix-realpath`, `fd-stream-fd`) | Med | Pinned SBCL; quarantined in sbcl-compat.lisp with startup probes |
| Hoisted-resolution subtle wrongness | Med | Conflict-forcing fixtures; honest error over silent pick; compare observable layout to npm's for the same tree |
| GC pauses at large heaps | Med | Struct objects (measured 4×/2.7× win); minor-GC-only steady state; RSS-plateau gates |
| Scope creep toward "real Bun" | High | §1.3 is contractual; Appendix A tracks every divergence honestly |

---

## Appendix A — Compatibility Matrix (maintain as you build; ships in README)

Legend: ✅ as documented · 🟡 partial (note what's missing) · ❌ non-goal v1.

| Area | v1 | Notes |
|---|---|---|
| Language core (ES2017 tier) | 🟡 | Strict+sloppy incl. `with`; no Proxy/Reflect/Intl/Temporal/Atomics; test262 pass-list is the ground truth |
| BigInt | 🟡 | Late-v1; drops to v1.1 if slipping |
| RegExp | 🟡 | PPCRE bridge; var-length lookbehind + `\p{}` error loudly; unparticipated backrefs known gap |
| ESM / CJS | 🟡 | Full resolution; import-of-CJS = default-only; require-of-ESM errors |
| TypeScript | 🟡 | Strip-only; enum/namespace/param-props/decorators **error** (Bun transpiles them); no `.tsx` |
| node:path / os / querystring | ✅ | posix only; win32 throws |
| node:fs | 🟡 | 23 sync + 14 promise + callback shims; no watch/streams/FileHandle; ms-mtime only |
| node:buffer | 🟡 | Core methods; utf8/ascii/latin1/hex/base64(url)/utf16le |
| node:events / util / assert | 🟡 | Per §3.6 subsets |
| node:url + URL global | 🟡 | WHATWG minus IDNA (ASCII hosts); legacy url.parse approximate |
| process | 🟡 | env is a plain object; nextTick real; no signals/stdin/beforeExit |
| timers | ✅ | Globals + modules + real ref/unref |
| node:stream / net / http / crypto / child_process / worker_threads / vm / zlib | ❌ | Loud non-goals — `stream` is the biggest compat cliff |
| fetch | 🟡 | Buffered bodies; HTTPS experimental (unaudited TLS); no HTTP/2, FormData, streams |
| Clun.serve | 🟡 | HTTP/1.1 fetch-handler; buffered bodies; no routes/static/WebSocket/TLS-server |
| Clun.file / write / spawn | 🟡 | Read/write-full + exists/size; spawn pipe/inherit/ignore, no IPC/AbortSignal |
| clun test | 🟡 | Hooks/modifiers/-t/timeout/bail + ~22 matchers; no snapshots/coverage/mocks/concurrency |
| clun install/add/remove | 🟡 | npm registry, hoisted, clun.lock, frozen; **no lifecycle scripts ever**, no workspaces/git-deps/bunx |
| clun run scripts | ✅ | sh -c, ancestor .bin PATH, pre/post, npm_* env (always /bin/sh — Bun prefers bash) |
| Bundler / watch / WebSocket / sqlite / ffi / shell / workers / JSX / sourcemaps / Windows | ❌ | Non-goals (sourcemaps unnecessary by design) |

## Appendix B — Approved Vendored Libraries (pin + record SHA in DECISIONS.md)

| Library | Purpose | Purity status |
|---|---|---|
| cl-ppcre | regex backend (parse-tree API) | Verified pure, zero deps |
| ironclad | all crypto primitives | Verified pure on SBCL (Lisp VOPs; C is ECL-only) |
| pure-tls (+ dep closure: alexandria, trivial-gray-streams, flexi-streams, cl-base64, trivial-features, split-sequence, idna, bordeaux-threads, usocket, atomics, **cl-cancel — requires the §3.4 purity patch**) | TLS 1.3 + X.509 + trust store | Pure on Linux after patch; strip win/mac CFFI files; verify usocket's SBCL backend at vendor time (fallback: feed it sb-bsd-sockets gray streams directly) |
| chipz | gzip/zlib/deflate inflate | Verified pure, zero deps |
| cl-base64 | SRI base64 | Verified pure (also a pure-tls dep — one copy) |
| parachute | CL-side test framework | Verify dep closure at vendor time (expected pure; else FiveAM) |
| test262 @ `d1d583d`, node-semver fixtures (ISC), amaro/TS strip fixtures (MIT/Apache-2.0), Bun console expected-output, UCD data files | conformance corpora / data | Fixtures & data, not implementation code |

Anything not on this list needs a DECISIONS.md entry with a `.asd`-level purity audit first.
Explicitly rejected: cl-tar (extraction needs osicat/CFFI), cl-unicode (Unicode 6.2 — technique
reference only), cl+ssl/dexador/drakma/hunchentoot as deps (study-only), cl-js (ES3 — design
blueprint only), fast-http (study-only; we hand-roll the parser).

## Appendix C — Verified Facts (do NOT re-verify; cite this appendix)

Established empirically on this host (SBCL 2.6.4, Linux x86-64) during planning research:

1. `(code-char #xD800)` works: lone surrogates are legal SBCL characters; `string=`, `sxhash`,
   `equal` hash keys, and CL-PPCRE all handle them (one surrogate = one char).
2. SBCL `base-char` is 7-bit — no narrow-string memory fallback; accept 4 B/code-unit.
3. `COMPILE` costs 0.16–0.5 ms per function; building a closure ≈ 30 ns.
4. `sb-int:with-float-traps-masked (:overflow :invalid :divide-by-zero)` gives correct
   Inf/NaN/−0; `(eql -0d0 0d0)` = NIL; SBCL constant-folds literal float ops at compile time
   (emitter must not emit them).
5. This SBCL build's `serve-event` uses poll() (`sb-unix:unix-poll` fbound; fd 1204 handled) —
   no FD_SETSIZE cap; timeout resolution ≈ 1 ms. Signals do NOT wake serve-event; a self-pipe
   wake measured 99 ms for a 100 ms-delayed cross-thread write.
6. `sb-ext:timer` runs callbacks via `interrupt-thread` in an unspecified thread with interrupts
   disabled — unusable for JS timers.
7. sb-bsd-sockets: non-blocking connect signals `operation-in-progress`; non-blocking
   accept/recv return NIL on EAGAIN; SO_REUSEADDR, TCP_NODELAY, IPv6 (`inet6-socket`), UDP, and
   port-0 + `socket-name` all work. No getaddrinfo (v4 `get-host-by-name` only). Write to closed
   peer → catchable `SB-INT:BROKEN-PIPE`; process survives (SIGPIPE neutralized by SBCL).
8. sb-posix on Linux: stat/lstat/fstat, symlink/readlink, chmod, mkdir/rmdir,
   opendir/readdir/closedir, rename, utimes, link/unlink, access, truncate, mkstemp/mkdtemp,
   flock present. Missing: realpath (use `truename` — verified resolves symlink chains),
   inotify, nanosecond mtime, getrlimit.
9. `open` on a raw string containing `[` signals `NO-NATIVE-NAMESTRING-ERROR`;
   `parse-native-namestring` round-trips `has[bracket].txt` correctly.
10. I/O throughput: 64 KB binary `read-sequence` ≈ 11 GB/s cached; write 4.3 GB/s; UTF-8
    `read-line` 271 MB/s.
11. `run-program :wait nil` verified: `:stream` pipes, `process-kill`, `process-wait`,
    exit-code + signal observation, `:status-hook` fires once in interrupt context, zombies
    auto-reaped, child fds closed-by-default with `:preserve-fds` opt-in, pipe backpressure real.
12. GC: 2M small hash-tables = 927 MB / 106 ms full GC; 2M 8-slot structs = 224 MB / 39 ms;
    minor GC 2–4 ms at 1 GB live.
13. Thread-per-connection HTTP echo measured 119,760 req/s (1 conn) / 325,203 req/s (8 conns)
    loopback with trivial parsing.
14. CL-PPCRE (zero-dep, active 2025): supports fixed-length + negative lookbehind, named groups,
    backrefs, parse-tree scanners, `:start`; does NOT support variable-length lookbehind
    (errors), fails unparticipated-group backrefs (JS matches empty), `\p{…}` needs external
    tables.
15. cl-js (github.com/akapav/js) loads and runs JS on SBCL 2.6.4 today (ES3: `let` fails to
    parse; no defineProperty; `with` works). Architecture documented in its
    jsos.lisp/translate.lisp.
16. test262 @ `d1d583d` (2026-07-09): 53,690 test files (language 23,986 / built-ins 23,671 /
    intl402 3,341 / staging 1,490 / harness 43).
17. pure-tls (v1.12.0, 2026-07-06, MIT): TLS 1.3 client+server, own ASN.1/X.509/trust-store,
    RFC 8448 + OpenSSL/BoringSSL interop suites; CFFI only in `:if-feature`
    windows/darwin files **plus** the Linux leak via cl-cancel → precise-time →
    `cffi:foreign-funcall("clock_gettime")` (the §3.4 patch target).
18. Ironclad: x25519, P-256/384 ECDH, AES-GCM, ChaCha20 (RFC 8439 nonce variant) + Poly1305,
    SHA-2 family, HMAC, RFC 5869 HKDF, RSA-PSS verify, ECDSA verify present; ChaCha20-Poly1305
    AEAD composition and PKCS#1 v1.5 verify are absent but implemented inside pure-tls.
19. `registry.npmjs.org` and `registry.npmmirror.com` 301-redirect HTTP→HTTPS including tarball
    paths (verified 2026-07-10): no TLS-free live npm exists.
20. npm abbreviated metadata (`application/vnd.npm.install-v1+json`) field set verified against
    npm/registry docs: versions{dependencies, optionalDependencies, peerDependencies, bin,
    dist{tarball, shasum, integrity}, engines, os, cpu, hasInstallScript, deprecated}.

## Appendix D — Reference Map (Explore-agent targets; behavior only, never port structure)

Into `/home/glenda/Projects/bun` (pinned c1076ce95e):
- CLI flags & dispatch: `src/runtime/cli/Arguments.rs` (:112-129, :243-246, :357-358, :554-625,
  :734-737, :1097-1102), `src/runtime/cli/run_command.rs` (:151-182, :1928-2052, :2357-2784,
  :2489-2556, :2956-2978), install flags `src/install/PackageManager/CommandLineArguments.rs`
- Test runner: `src/runtime/test_runner/` (Order.rs:81-198, Execution.rs:668-673,
  expect/expect.rs:404-475, diff/printDiff.rs:241-342), `src/runtime/cli/test_command.rs`
  (:192-198, :888-967, :1374-1407, :2805-2941), `docs/test/lifecycle.mdx:240-282`
- Console formatting: `src/jsc/ConsoleObject.rs` (:86, :2457-2731, :2982, :3413-3419,
  :3698-3731, :4508-4557); fixture `test/js/web/console/console-log.expected.txt`
- Clun global semantics: `packages/bun-types/bun.d.ts` (file :2100-2196, write :1579-1586,
  spawn :6791-6829, sleep :5039-5059), `docs/runtime/file-io.mdx`
- Install behavior: `docs/pm/lifecycle.mdx:13,35,58-66`, `docs/pm/lockfile.mdx:6,51`
- Resolver edge-case inventory: `src/resolver/`; server option semantics: `src/runtime/server/`
- Error-message voice: grep `error:` / `note:` patterns across `src/`

External (design references, not code): cl-js jsos.lisp/translate.lisp; parse-js tokenize.lisp;
facebook/regenerator (lowering scheme); mathiasbynens/regexpu-core (u-flag translation);
tc39/test262 INTERPRETING.md; Ryū paper; RFC 8446 (TLS 1.3), 8439, 5869, 7748; WHATWG URL;
nodejs.org/api/typescript.html + nodejs/amaro; npm/registry docs; node-semver.

## Appendix E — Post-v1 Backlog (do not start before v0.1.0)

1. Proxy/Reflect (the object protocol is already shaped for it) — v1.1 headline.
2. Own regex backtracking VM (kills all PPCRE gaps); `\p{…}` via the UCD tables.
3. node:stream (the biggest compat cliff), then net/http shims over src/net.
4. WebSocket server/client (RFC 6455 on the Phase-17 parser).
5. Snapshot testing + mocks (`jest.fn`) + asymmetric matchers; parallel test files.
6. Watch mode (stat-polling; no inotify in pure SBCL).
7. Reactor-native TLS (off the worker pool); AAAA/DNS resolver (verify `dns-client` purity).
8. `clun x` (bunx) on the install cache; isolated (pnpm-style) installs; workspaces.
9. TZif local time (if deferred), Intl skeleton, punycode/IDNA for URL.
10. Deeper macOS substrate parity (native memory/uptime/CPU metrics); `--compile`-style single-file bundles
    (save-lisp-and-die tricks).
11. `bun:sqlite` equivalent — requires a pure-CL SQLite file-format reader or a rethink; research first.
