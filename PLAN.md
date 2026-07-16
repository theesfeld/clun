# Clun — Bun, Rewritten in Pure Common Lisp

> **NOT process.** Process is only `~/.config/agents/AGENTS.md` (+ repo `AGENTS.md` facts).
> This file is a **technical notebook**: mission, purity contract, architecture, phase specs, gates.
> **Live SoT for status/scope:** GitHub Issues. On conflict, Issues + user standard win.
> Ship: **Issue → branch `issue-N-…` → PR → squash-merge**.

- **This repo:** `/home/glenda/Projects/clun`
- **Engineering reference:** `/home/glenda/Projects/bun` (read-only — never modify), commit
  `c1076ce95e` (**Bun 1.4.0-dev** forward baseline; not the stable comparison version)
- **Public comparison reference:** **Bun 1.3.14 stable** for README/site labels and stable-binary claims
- **Host toolchain:** SBCL 2.6.4 on PATH (`:sb-thread`, `:mark-region-gc`, poll-backed
  serve-event — verified). Linux x86-64. Pin this SBCL version.

**Session shortcut:** user says `phase` / `phase NN` → see repo `AGENTS.md` (no separate prompt file).

---

## 1. Mission, Scope, and the Purity Contract

Bun is ~1M lines of Rust/C++ on top of JavaScriptCore. Clun is **not** a literal port. It is a
sharply scoped, faithful-in-spirit JavaScript/TypeScript runtime and toolkit written in **pure
Common Lisp** — including a from-scratch ECMAScript engine. Correctness of the scoped surface and
purity of the implementation beat breadth and speed for the original v0.1 foundation. The active
prerelease roadmap now expands the purity-compatible surface and pursues measured performance against
Bun before Phase 26 re-baselines the resulting system for final hardening and release.

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

### 1.2 v0.1 delivers (the `clun` binary)

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
timers modules; an 18-member `Clun` global (`version`, `revision`, `env`, `argv`, `main`, `sleep`,
`sleepSync`, `file`, `write`, `spawn`, `spawnSync`, `serve`, `inspect`, `deepEquals`, plus
`which`/`nanoseconds`/`fileURLToPath`/`pathToFileURL`).

### 1.3 Explicit non-goals for v0.1 (do not build; do not partially build)

Bundler/minifier, CSS, HTML rewriter, dev server, N-API, `bun:ffi`, `bun:sqlite`, WebSocket,
HTTP/2/3, shell language (`Bun.$`), workers, macros, `--compile`, watch/hot reload, snapshots,
coverage, mocks (v0.1), `clun x`/bunx, REPL, JSX/`.tsx`, sourcemaps (by design — whitespace-
preserving TS strip makes them unnecessary), Proxy/Reflect, Intl, Temporal, Atomics/SAB,
`node:stream`/`net`/`http`/`crypto`/`child_process`/`worker_threads`/`vm`/`zlib`, workspaces,
git/file dependencies, lifecycle scripts (never executed — stricter than Bun), and Windows.
Linux and macOS 13+ release builds target x86-64 and arm64; platform-specific APIs may remain partial.
If a v0.1 task appears to require one of these non-goals, it doesn't — rescope and record why in
`DECISIONS.md`. Phases 27–82 promote the compatible items into the purity-compatible Bun-surface program
before the re-baselined Phase 26 final hardening and release.

### 1.4 Original v0.1 requirements and current ownership

The former `v0.1.0` target is not a current release boundary. Phases 00–25b established the
foundation, Phases 27–82 expand and audit the purity-compatible surface, and Phase 26 runs last.
These requirements remain binding under their current phase owners and are revalidated where still
relevant when Phase 26 is designed from the then-current system:

1. All foundation phase gates 00–25b pass, followed by the applicable gates in Phases 27–82 and the
   re-baselined Phase 26 checklist.
2. test262: the checked-in pass-list contains every passing test (monotonically grown, zero
   regressions), with overall curated pass rate ≥ 90% at Phase 25b's close.
3. End-to-end demo (`examples/e2e.sh`): `clun install` against the local registry fixture →
   `clun run build` (a script invoking a `.bin` tool) → `clun test` — all green, hermetic.
4. `Clun.serve` example survives 1k sequential + 500 concurrent requests, RSS plateaus.
5. Phase 28 records a live smoke that installs a pinned package from public npm over verified pure-CL
   HTTPS and executes it.
6. README with install, quickstart, architecture, honest compat matrix (Appendix A), and the
   TLS security-posture statement (§3.4).
7. Phase 26 selects the final version and immutable tag from the completed work and then-current
   release train; it does not inherit the former `v0.1.0` assumption.

### 1.5 Definition of Done for the purity-compatible Bun-surface program

1. Every gate in Phases 27–82 passes, including the universal feature-evidence gate in §5.
2. Every public API, CLI command/flag, loader, protocol, and observable behavior in the Phase-73
   frozen surface has exactly one primary owner and executable evidence. Every purity-compatible
   item meets or exceeds the frozen Bun behavior; the generated landing matrix is a summary, not the
   boundary of parity. A constitutional conflict is never relabeled as parity: it remains explicit
   until the operator accepts or rejects a narrowly written amendment.
3. Both baselines are recorded without conflation: Bun 1.3.14 stable supplies the public comparison
   version and stable-binary evidence, while `/home/glenda/Projects/bun` at `c1076ce95e`
   (Bun 1.4.0-dev) supplies the forward engineering source/test inventory. Phase 73 freezes their
   complete delta once at phase entry. A Bun release or commit published after that freeze belongs to
   the next release train and cannot move this program's completion target.
4. Release artifacts and feature gates pass on Linux and macOS 13+ for x86-64 and arm64. A feature
   that works on fewer targets stays partial and says which target is missing.
5. Performance claims come only from identical workloads measured on the same host, architecture,
   power mode, toolchain, and release builds. Cold start, warm throughput, latency, peak RSS, and
   artifact size remain separate numbers; no projected or cross-host number is a release claim.
6. `README.md`, `site/index.html`, release notes, and the compatibility evidence ledger agree with
   the shipped version and are checked mechanically before the release tag.
7. Phase 82 produces the purity-compatible surface release tag only after the final review finds no
   unsupported claim.

**Scale honesty:** the ~65–70k LOC estimate applies only to the original v0.1 foundation. Phases 27–82 are a
multi-release purity-compatible surface program with no credible fixed LOC estimate; each bounded
phase and milestone is estimated only after its pinned surface inventory and design.

---

## 2. Technical iteration notes (not process)

**Process (mandatory):** user standard — Issue first → branch from Issue → implement → gates → PR →
squash-merge; plan-phase survey when required; subagents as the coding team.

This section only describes **how to chew Clun technical work** once the Issue/branch exist.
Phases 00–25b = v0.1 foundation; 27–82 = purity-compatible Bun-surface track; Phase 26 last
(re-baselined). Active phase/status live on the **GitHub Issue** (and derived `STATE.md`).

### 2.1 Derived local files (not SoT)

- `PLAN.md` — this notebook. Append technical clarifications; do not invent process here.
- `STATE.md` — resume checklist (`[ ]`/`[x]`, next action). Keep aligned with the Issue.
- `DECISIONS.md` — append-only architecture/library/scope decisions; mirror material ones on the Issue.
- `docs/design/phase-NN.md` — before non-trivial implementation (always for engine 01–04, 06, 10, 11 and TLS 19–20).

### 2.2 Technical steps inside an Issue unit

```
1. ORIENT    Issue + this file's phase section + STATE.md; deps complete; SemVer on Issue.
2. DESIGN    docs/design/phase-NN.md if non-trivial (subagent or serial).
3. RESEARCH  Bun tree + vendored sources as needed; check Appendix C first.
4. BUILD     Task-by-task; after each: make build && make test green when practical.
             Parallel subagents only for disjoint ownership; re-run full suite after merge of slices.
5. GATE      Phase acceptance commands exactly + make purity (+ test262 pass-list for engine).
6. REVIEW    Adversarial review (skill or subagent); fix; re-gate.
7. SHIP      Per user standard: commits Refs #N → PR → squash-merge when CI green;
             then release tag/evidence if release-bearing (docs/versioning.md).
8. RECORD    Update Issue evidence; sync STATE/DECISIONS/README/site as required.
```

Never skip a technical gate. Never mark done on red. Never start a dependent phase while a
dependency's gate fails. Never freelance outside the active Issue's scope.

### 2.3 Subagents and review focus (Clun-specific)

- **Research** (read-only): `/home/glenda/Projects/bun` and vendored sources; cite file:line.
- **Planning:** argue design sides for §3 fallbacks; log the choice on Issue + DECISIONS.md.
- **Implementers:** disjoint files only; owner re-runs full suite after integrating.
- **Reviewers:** especially engine object kernel, event loop, TLS, tar extraction — hunt
  `ignore-errors` around fallible work, interrupt-context violations, path-discipline breaks,
  purity leaks, untested claims, pass-list regressions.
- **Codex/Sol 5.6 orchestration:** use maximum reasoning effort and available subagents; execute the
  same work serially when ownership would overlap or the harness has no free agent slots.

### 2.4 When technically blocked

Timebox spikes. Prefer documented §3 fallbacks and log them. Escalate to the user only for genuine
product/scope decisions (or new plan-phase survey per user standard). Record blockers on the Issue
and in STATE.md; move to an unblocked Issue/phase rather than stalling silently.

---

## 3. Settled Architecture Decisions (do not relitigate; fallbacks noted)

Research verified these empirically on this exact host — evidence in Appendix C.

### 3.1 The engine (from-scratch ECMAScript in CL)

| Topic | Decision | Fallback |
|---|---|---|
| Execution | **Compile analyzed AST → CL closures** (pre-resolved variable slots; one closure per node; no per-node dispatch). Never `COMPILE`-per-function at load (measured 0.16–0.5 ms/fn → 10–25 s startup on big bundles). cl-js (`github.com/akapav/js`) is the design blueprint — study, don't vendor (it's ES3) | Hot-function tiering via `COMPILE` on a background thread (P25); plain tree-walker for `with`-containing functions if the emitter fights |
| Strings | **CL strings, one character = one UTF-16 code unit** (astral → surrogate pairs; lone surrogates are legal SBCL chars — verified). `.length` = `length`. UTF-8⇄code-units (WTF-8 for lone surrogates) at host boundaries only | `(unsigned-byte 16)` vectors if memory (4 B/unit) ever dominates — costs bespoke hashing/printing/regex bridge |
| Numbers | `double-float` + `sb-int:with-float-traps-masked (:overflow :invalid :divide-by-zero)` at engine entry points (verified: Inf/NaN/−0 correct). Int32 ops via `(ldb (byte 32 0) …)` + sign fix. NaN via `sb-ext:float-nan-p`. **BigInt IN, late phase** (CL bignums make it cheap). Number→String: **port Ryū** (naive bignum shortest-round-trip as fallback). Emitter must never emit constant-foldable trapping float literals (SBCL folds at compile time — verified) | Per-operation trap wrapping (cl-js's `wrap-js`) if entry-point masking leaks through callbacks |
| Object model | Spec internal-methods protocol ([[Get]]/[[Set]]/[[GetOwnProperty]]/[[DefineOwnProperty]]…) as struct-dispatched functions, **deliberately Proxy-shaped** for later surface work. v0.1 storage: per-object property table (small simple-vector → `equal` hash-table promotion), full descriptors, prototype as struct slot. **Structs, never hash-table-per-object** (measured 4× memory + 2.7× GC win). Arrays: dense adjustable vector + sparse hash overflow. Shapes/inline-caches deferred to Phase 25 behind the protocol (cl-js's scls/hcls proves the design) | Lift cl-js's shape tree early if property-table perf blocks a gate |
| Scoping/modes | Parser does full scope analysis (hoisting, let/const slot indices, TDZ sentinel, eval/with/arguments flags); frames are simple-vectors; `with`/direct-eval scopes use hash-backed slow frames. **Strict AND sloppy from day 1, including `with` and direct eval** — test262 runs both modes; npm CJS is sloppy | None — design constraint, not a bet |
| Async/generators | **Regenerator-style state-machine lowering** as an AST→AST pass before closure emission (hoisted locals, `switch(state)` loop, try-entry tables — copy `facebook/regenerator`'s scheme exactly). Engine owns the microtask/job queue; async generators & for-await desugar per spec | Thread-per-generator (sb-thread + semaphore handoff) — semantically safe, slow; acceptable for rare generators if lowering is buggy |
| RegExp | v0.1: own JS-regex parser → **CL-PPCRE parse trees** (pure CL, zero deps — verified; supports fixed-length lookbehind, named groups, backrefs, `:start` for lastIndex/sticky). Documented gaps that **error loudly** (SyntaxError), never silently mismatch: variable-length lookbehind, `\p{…}` until own UCD tables. Known silent gap to fix earliest: unparticipated-group backrefs (PPCRE fails where JS matches empty — verified) | Phase 37 owns the modern RegExp/UCD gap wave; the parser and RegExp object survive a backend swap |
| Unicode data | **Own build-time UCD table generator** (vendor current Unicode data files, emit Lisp tables). cl-unicode is Unicode 6.2 (2012) — reference for technique only | — |
| Conformance | Vendor **test262 pinned @ `d1d583d`** (53,690 test files measured): `harness/` + `test/language/**` + built-ins for implemented globals. Skip by `features:` tags (Proxy, Reflect, Temporal, Atomics, SharedArrayBuffer, Intl…) and `$262.createRealm`. Own runner: ~200-LOC YAML-frontmatter parser per test262 INTERPRETING.md; default = run each test in both sloppy+strict; async via `doneprintHandle.js`. **Gate mechanism: checked-in sorted pass-list — CI fails if any test leaves it; it only grows** | Skip-list polarity if curation churns |
| v0.1 language tier | ES2017-ish: full ES2015 minus Proxy/Reflect/tail-calls, plus async/await, `**`, Object.entries/values, trailing commas; Symbols incl. iterator/toPrimitive/toStringTag/hasInstance; BigInt (late); no Intl/Temporal/Atomics. Per-realm intrinsics indirection designed in from Phase 03 (cheap now, painful later) | Phase 37 owns the pinned-Bun modern language gap |
| Date/TZ | UTC-correct core in Phase 04; pure-CL TZif (`/etc/localtime`) remains unassigned until Phase 26 re-baselines the then-current system, while Phase 37 retains only its existing Date/Intl issue scope | — |

### 3.2 The substrate (event loop, I/O — pure SBCL)

| Topic | Decision | Fallback |
|---|---|---|
| Event loop | **Hybrid**: one JS thread owns the heap, timers, microtasks, and a `serve-event`-based reactor for sockets & child pipes (poll backend verified — no 1024-fd cap on this build; startup capability probe required); small worker pool (sb-thread) for blocking ops (DNS, async fs, TLS in v0.1); completions via `sb-concurrency:mailbox` + **self-pipe wakeup** (signals do NOT wake serve-event — verified). fd/signal handlers **enqueue only** — JS runs solely at loop dispatch points, each followed by a full microtask drain, with `process.nextTick`'s dedicated queue drained first | All-blocking-I/O-on-workers model (simpler, 2 context switches per op) if reactor integration stalls |
| Timers | **Own binary-heap timer queue**; loop timeout = `min(next-timer − now, cap)`. `sb-ext:timer` is unusable for JS callbacks (runs via `interrupt-thread`, unspecified thread, interrupts disabled — verified docstring) | — |
| Lifetime | Handle refcounting (listeners, sockets, ref'd timers, in-flight work, child watchers); loop exits at refs=0 ∧ queues empty. `ref()`/`unref()` are real | — |
| Paths | **Every user-supplied path goes through `sb-ext:parse-native-namestring`/`native-namestring`** — raw strings with `[` crash SBCL pathname parsing (verified). CI grep-gate for raw namestring constructors outside `src/sys/` | — |
| Files | `sb-posix` (coverage verified near-complete) + CL streams (11 GB/s cached reads measured — not a bottleneck). realpath via `truename` with dangling-symlink handler. mtime is second-granularity (no nanosec in sb-posix) — documented. No inotify → `fs.watch` is out of v0.1 | readlink-loop realpath |
| Processes | `sb-ext:run-program :wait nil` (verified: `:stream` pipes, `process-kill`, `:status-hook` fires in interrupt context, zombies auto-reaped, fds closed-by-default + `:preserve-fds`). status-hook enqueues to mailbox + self-pipe only. Pipe fds go non-blocking into the reactor | Worker-thread blocking pipe drains |
| Signals | `sb-sys:enable-interrupt` handlers: push to queue + 1 byte to self-pipe, nothing else (handlers run in arbitrary threads — verified). SIGPIPE already neutralized by SBCL (write-to-closed-peer → catchable `SB-INT:BROKEN-PIPE` — verified) | Flag polled each loop iteration |
| HTTP server | Event-driven on the JS-thread reactor, non-blocking sockets, **own incremental HTTP/1.1 parser** (~1k LOC; study fast-http and Hunchentoot's taskmaster/shedding — both pure-CL, neither fits the reactor). Keep-alive, chunked both ways, 16KB header / configurable body limits (fail 431/413), graceful shutdown, port 0 via `socket-name`. Substrate ceiling measured 325k req/s — target ≥30k with real parsing | Thread-per-connection with cap (measured fast) + handler marshaling to the JS thread |
| HTTP client | Same reactor; pool keyed `(host, port, family, tls-config)`; connect/header/body timeouts via the timer heap; gzip via chipz; redirects follow (max 20, drop auth cross-origin) | Blocking client on worker pool for v0.1 fetch |
| DNS | v4 via `sb-bsd-sockets:get-host-by-name` on the worker pool (blocking; no getaddrinfo in SBCL — verified). IPv6 literals parsed in-process; Phases 28/43 own AAAA lookup | Pure-CL resolver in Phases 28/43 |
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
including tarball paths). So TLS is on the v0.1 critical path for live installs; all install
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
  replicate Bun's sync loop-pumping), expect.assertions/hasAssertions. No snapshots/mocks in v0.1.
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
are informed estimates, not promises. Phases marked ⚡ are fan-out-friendly (disjoint files for
available subagents, with the same work executable serially). Phases marked ◇ are
**independent early**: pull them forward whenever the main track is blocked.

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
thread; Phase 28 owns reactor-native TLS); trust store (system PEM bundle, `SSL_CERT_FILE`/
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
green and hermetic — this is the v0.1 workflow demo.

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

> **PERFORMANCE DISPOSITION (2026-07-14, preapproved off-ramp executed):** after two workloads and
> the suite geomean cleared 5×, the operator authorized a COMPILE-tier ceiling experiment with an
> explicit fallback: if eager compilation still left DeltaBlue below 5×, accept G2 on the
> majority/geomean basis and do not build the background tier. The m2 ceiling compiled all 72
> DeltaBlue user bodies but reached 694.6 ms / 4.24×, above the 588.4 ms target. Phase 25 therefore
> closes at richards 6.68×, deltablue 3.85×, splay 5.36×, and a 5.16× geomean; DeltaBlue remains an
> explicit holdout. Background-tier m3/m4 are canceled. Evidence: `docs/benchmarks.md` and
> `docs/design/phase-25-compile-tier.md`.

### Phase 25b — Conformance push to ≥ 90%  *(deps: 25)*
Objective: lift overall curated test262 from ~80.4% to ≥ 90% (DoD §1.4 point 2), correctness only.
Tasks: bucket the 5,486 phase-entry `fail(gap)` tests by feature/subsystem (a small analysis pass over the
runner output) to estimate cost and order the work; then targeted correctness fixes bucket by bucket
(no performance work); grow the checked-in pass-list monotonically. Faster iteration because the
Phase-25 engine is quicker. **Gate:** overall curated test262 ≥ 90%; zero pass-list regressions
(monotonic); `make purity` clean. (May itself be milestoned; the bucket analysis is milestone 1.)

### Purity-compatible Bun-surface program — rules for Phases 27–82

The program starts after Phase 25b. Phase 26 is deliberately deferred until after Phase 82 and is
re-baselined against the system and release train that exist then; it does not block Phase 27.
Until Phase 73, engineering work uses the
read-only clone at `/home/glenda/Projects/bun`, commit **`c1076ce95e` (Bun 1.4.0-dev)**, while public
comparison copy continues to identify **Bun 1.3.14 stable**. Every design doc cites the exact Bun
types, docs, source, and tests that define its surface (start with `packages/bun-types/`, `docs/`,
`test/js/bun/`, `test/js/node/`, `test/js/web/`, `test/cli/`, and `test/bundler/`) and says which
baseline supplies each assertion. Phase 73 freezes the exhaustive stable-versus-engineering delta;
after that gate passes, neither baseline moves during this release train and old fixtures remain
regression tests.

**Universal feature-evidence gate (created in Phase 27; mandatory in every later phase):**

1. Write `docs/design/phase-NN.md` before implementation. It must contain the bounded public API
   inventory, ownership/lifetimes, file layout, purity analysis, Linux/macOS portability analysis,
   milestones, risks/fallbacks, and cited Bun reference paths at the pinned commit.
2. Add/update the canonical compatibility ledger with status, supported platforms, evidence paths,
   immutable benchmark IDs, Bun release/commit, one primary owning phase, and any integration owners
   for every item. The inventory covers all exported APIs, CLI commands/flags, loaders, protocols,
   module/global members, and documented observable behavior, not only landing-page rows. Validation
   fails on an unowned item, duplicate primary owner, unknown status, or prose-only `Yes` claim.
3. Add hermetic fixtures that run through the shipped `clun` binary. Where behavior is shared, run
   the same fixture against the pinned Bun release and compare typed values, bytes, errors, exit
   status, and ordering; do not merely compare pretty-printed text.
4. Run `make build`, `make test`, `make purity`, `make compat FEATURE=<feature-id>`, and
   `make docs-check`. Engine/parser/runtime-semantic phases also run `make conformance-exec` and
   prove the checked-in pass-list is monotonic. Platform-specific features run the same feature
   target in CI on Linux and macOS 13+, x86-64 and arm64; a missing platform keeps the cell partial.
5. Performance-relevant phases register a reproducible workload in a frozen manifest before tuning
   and make no cross-runtime claim until Phase 71. Any Bun comparison uses release builds on the same
   host and reports cold start, warm throughput, latency distribution, peak RSS, and output/artifact
   size separately. A passing aggregate never licenses `faster than Bun`, `better than Bun`, or
   `stronger than Bun`; generated copy names the exact workload/suite, Bun baseline, host, metric,
   result, and any losses.
6. Update `STATE.md`, append the decision/evidence entry to `DECISIONS.md`, regenerate README/site
   claims, run an adversarial review, fix findings, and rerun the full gate. If subagents are
   unavailable, perform the research, implementation, and independent review passes serially.
7. Record provenance for every copied fixture/data file: origin repository, exact commit, file path,
   license, modifications, and required notices. Bun's root code is MIT, but vendored Node, WebKit, WPT,
   esbuild and other corpora retain their own licenses. Confirm GPL-3.0-or-later compatibility instead of
   assuming Bun's root license covers them. JavaScript/TypeScript may enter Clun only as fixtures or
   conformance data, never as implementation code.

### Phase 27 — Compatibility evidence ledger and release-doc automation  *(deps: 25b)* ~2k LOC ⚡
Objective: make every compatibility and release claim mechanically traceable to shipped behavior.
Tasks: create the structured canonical ledger (schema + stable feature IDs + status/platform/evidence/
benchmark/reference/primary-owner/integration-owner fields); distinguish Bun 1.3.14 stable evidence
from the `c1076ce95e` Bun 1.4.0-dev engineering evidence; inventory the current README/site matrix;
generate marked compatibility and version sections in `README.md`, `site/index.html`, and release notes;
add `make compat`, `make compat-validate`, and `make docs-check`; reject an upgrade to `Yes` without
passing evidence and reject unqualified cross-runtime superlatives; create the immutable benchmark-
manifest schema and workload-coverage rules used by Phases 71, 72, and 81;
add a Linux/macOS x64/arm64 compatibility workflow while keeping Pages deployment site-only; seed the
stable 1.3.14 executable map and pinned Bun 1.4.0-dev `c1076ce95e` engineering map from its
types/docs/test trees. Serial fallback: inventory → schema → validator → generators → CI, in that order.
**Gate:** `make compat-validate`; `make docs-check` is byte-idempotent and fails after deliberate
version/status/evidence drift; `make build`; `make test`; `make purity`; the four-platform workflow
passes; generated README and site matrices agree byte-for-byte on every shared field.

### Phase 28 — TLS, DNS, streaming transport, and public npm  *(deps: 20, 23, 27)* ~6k LOC ⚡
Objective: make HTTPS/fetch/package transport interoperable, streaming, bounded, and production-usable.
Tasks: design from Bun `src/http/`, `src/runtime/webcore/`, `src/install/`, `test/js/web/fetch/`, and
`test/cli/install/`; close TLS 1.2/1.3 and certificate/ALPN interoperability gaps without weakening
verification; add pure-CL A/AAAA resolution, Happy Eyeballs, pooling, streaming request/response bodies,
backpressure, cancellation, proxy/timeout semantics, decompression limits, and registry.npmjs.org
metadata+tarball support; retain hermetic TLS/DNS/registry peers and one explicitly logged live smoke.
**Gate:** `make test-tls`; `make compat FEATURE=transport`; `make compat FEATURE=fetch`;
`make compat FEATURE=public-npm`; `make build`; `make test`; `make purity`; `make docs-check`; opt-in
`make smoke-npm` installs and executes a pinned package with SRI verified; transport gates pass on all
four supported targets with zero fd/thread leaks and bounded-memory streaming of a 1 GiB synthetic body.

### Phase 29 — Public semver API  *(deps: 21, 27)* ~1k LOC
Objective: expose a Bun-compatible public semver API over the proven installer implementation.
Tasks: inventory `docs/runtime/semver.mdx`, Bun semver types/source/tests, and node-semver; implement
`Clun.semver`/`Bun.semver`-compatible satisfies/order operations, coercion/errors, prerelease/build and
range edges; keep one parser/range engine shared with install; add a public API differential corpus.
**Gate:** `make compat FEATURE=utility.semver` passes the pinned Bun public differential fixtures and
100% of the applicable strict public `satisfies`/`order` rows from the vendored node-semver corpus through
`build/clun`; `make test` passes the complete 15-file engine corpus; `make build`; `make purity`;
`make docs-check`; no installer semver regression.

### Phase 30 — Glob API  *(deps: 13, 27)* ~2.5k LOC
Objective: deliver `Clun.Glob` with Bun-compatible matching and filesystem scanning.
Tasks: inventory Bun `src/runtime/api/Glob`, glob types/docs/tests, and Node glob behavior; implement
parser/automaton, braces/extglobs/classes/dotfiles/platform separators, match/scan/scanSync and async
iteration; enforce path discipline, symlink-loop handling, deterministic traversal, cancellation, and
bounded state growth; share matching with test discovery and package tooling where semantics coincide.
**Gate:** `make compat FEATURE=filesystem.glob` passes the complete pinned pattern + filesystem fixture inventory
against Bun on Linux and macOS; a million-entry synthetic tree remains bounded and cancellable;
`make build`; `make test`; `make purity`; `make docs-check`.

### Phase 31 — YAML API and module loading  *(deps: 07, 27)* ~2.5k LOC
Objective: support Bun-compatible YAML parsing, stringification, and YAML module imports without foreign code.
Tasks: inventory `docs/runtime/yaml.mdx`, types, parser/stringifier/tests; implement YAML 1.2 core scalars,
collections, block/flow forms, anchors/aliases/merge keys, directives, multi-doc input, deterministic
stringification and useful source locations; add `.yaml`/`.yml` loader integration; preserve supported
alias identity and cycles, cap alias expansion, nesting and document size, define duplicate-key policy,
and error on unsupported tags rather than constructing host objects.
**Gate:** `make compat FEATURE=data.yaml` passes the pinned parse/stringify corpus plus YAML
conformance/security cases; serializer round-trips and alias identity/cycle cases pass; alias-bomb and
depth/size adversaries fail boundedly; import/cache/error fixtures match Bun;
`make build`; `make test`; `make purity`; `make docs-check`.

### Phase 32 — Cookies and CookieMap  *(deps: 17, 27)* ~5k LOC
Objective: match Bun's Cookie/CookieMap API and automatic server request/response integration.
Tasks: freeze the stable executable plus engineering-pin Cookie/CookieMap contract in
`docs/design/phase-32.md`; implement exact constructors, descriptors, overload/coercion order, parsing,
serialization, attributes, mutation/coalescing, live iteration, expiry, JSON and error behavior; repair
ordered duplicate Cookie/Set-Cookie transport, HTTP framing ambiguity and the missing canonical
Request.prototype wiring; put the complete CookieMap state machine in the engine-independent core;
implement signed-i64 decimal-prefix Max-Age parsing and JavaScript Number rounding, the exact
header-global forgiving-percent scanner, and nonempty-only Domain emission; use branded runtime object
subtypes/private slots for Headers, Response body, Cookie, CookieMap, iterators and server requests;
accept only genuinely branded Response results; replace CR/LF stripping with validation before Headers
storage and complete response serialization; expose cookies only through a dedicated server-request
prototype inheriting the canonical Request.prototype; lazily snapshot the current request.headers Cookie
view at first access, then keep header and map mutations independent; integrate that cached map with ordered
pipelined responses and one-time, Response-nonmutating automatic output across synchronous, Promise,
promised-error, default-error, HEAD, late-settlement and teardown paths; use cursor/index parsers and
single builders so unbounded standalone input remains linear without proportional copied-token lists;
prevent injection, pollution, prototype spoofing, observable state keys, unchecked Date/numeric overflow,
unbounded auxiliary allocation and cross-request state reuse without inventing browser storage policy.
**Gate:** `make compat FEATURE=web.cookies` passes the complete shipped-binary public API and raw-HTTP
differential corpus, the recorded stable/engineering dispositions, descriptor/coercion/error fixtures,
newTarget/zero-vs-undefined/USVString/Date-brand-range cases,
private-slot/Reflect.ownKeys/Headers-store/Response-body/real-Response-only/borrowed-receiver/
prototype-spoofing cases, canonical Request identity plus standalone-negative, server-subtype accessor,
and pre-access/post-cache request.headers timing cases, constructed/parser/fetch/serve Headers views,
conflicting Content-Length/Transfer-Encoding/Connection and one/split-feed limit cases,
manual Set-Cookie/ordinary-header injection with no partial output, exact signed-i64 Max-Age/Number
rounding, Domain nonempty omission, the complete malformed-percent/header-global switch matrix,
RFC/date/malformed/security and N/2N/4N time-allocation/RSS bounds, distinct manual + automatic
Set-Cookie wire ordering, ordered pipelines, shared-Response nonmutation, mutation cutoff,
promised-error/default-500/HEAD/teardown lifecycle
and concurrent-request isolation on all four supported targets; `make build`; `make test`;
`make purity`; `make docs-check`; `make public-claims-check`; `make roadmap-check`.

### Phase 33 — Terminal string width and ANSI utilities  *(deps: 10, 27)* ~2.5k LOC + generated data
Objective: meet `Bun.stringWidth` behavior with Unicode 17 and bounded ANSI handling.
Tasks: inventory `docs/runtime/utils.mdx`, the exact Bun types/source/tests, and string-width fixtures;
vendor byte-pinned UCD width/grapheme/emoji data and conformance corpora; implement the exact public
descriptor/coercion/options contract, UTF-16 scanning, ANSI parsing, UAX #29 clustering, emoji/ZWJ/keycap
sequences, variation selectors, ambiguous-width policy and `countAnsiEscapeCodes`; generate compact pure-CL
tables and keep the scanner linear with constant auxiliary state. Do not claim a `Bun` global or separate
ANSI utility APIs.
**Gate:** `make compat FEATURE=text.string-width` passes the pinned Bun public/corpus/stress fixtures through
`build/clun`; all vendored Unicode 17 grapheme and fully-qualified emoji rows pass; malformed ANSI,
lone-surrogate transitions, and million-code-unit inputs stay linear and bounded; `make build`; `make test`;
`make purity`; `make docs-check` on all four supported targets.

### Phase 34 — CSS Color API  *(deps: 27)* ~2.5k LOC
Objective: implement the complete `Bun.color` parse/normalize/conversion surface.
Tasks: inventory `docs/runtime/color.mdx`, Bun CSS color source/types/tests and CSS Color standards;
implement named/hex/rgb/hsl/hwb/lab/lch/oklab/oklch/color() inputs, alpha, clamping, color-space
conversion and every Bun output format (CSS, number, ANSI tiers, object and tuple); share the parser with
Phase 64 and reject invalid input as Bun does.
**Gate:** `make compat FEATURE=web.css-color` passes the pinned Bun corpus plus published CSS color vectors
within documented numeric tolerances; round-trip and gamut-edge properties pass; `make build`;
`make test`; `make purity`; `make docs-check`.

### Phase 35 — CSRF API  *(deps: 19, 27)* ~1.2k LOC
Objective: provide Bun-compatible authenticated, expiring CSRF tokens.
Tasks: inventory `docs/runtime/csrf.mdx`, types/source/tests; implement generate/verify overloads, HMAC,
timestamps, session binding, encoding and cryptographically secure defaults over Phase-19 primitives;
use constant-time authentication checks, strict size limits, injectable clocks only in tests, and
preserve the pinned unprefixed wire format as implicit version 0 and reserve future formats for explicit
opt-in rotation.
**Gate:** `make compat FEATURE=web.csrf` matches Bun for deterministic seeded vectors and API errors;
tamper/expiry/session/cross-key/fuzz cases reject; timing review confirms no early MAC comparison;
`make test-crypto`; `make build`; `make test`; `make purity`; `make docs-check`.

### Phase 36 — Password and hash APIs  *(deps: 19, 27)* ~4k LOC ⚡
Objective: match `Bun.password` and `Bun.hash` in pure Common Lisp with explicit cost controls.
Tasks: inventory `docs/runtime/hashing.mdx`, types/source/tests; implement compatible password formats,
hash/verify sync+async, bcrypt/Argon2 algorithms required by the pinned surface, automatic salts and
long-password behavior; implement the listed non-cryptographic hash family with exact seeded outputs;
run slow password work off the JS thread, zero transient secrets where practical, and cap hostile costs.
**Gate:** `make compat FEATURE=security.password-hashing` passes published KATs, Bun differential fixtures and
cross-tool password verification; malformed/cost-exhaustion cases are bounded; async work does not block
the reactor; `make test-crypto`; `make build`; `make test`; `make purity`; `make docs-check`.

### Phase 37 — Modern ECMAScript gap wave  *(deps: 25b, 27)* ~12k LOC ⚡⚡
Objective: close the language/runtime gap through the ECMAScript feature level supported by the pinned Bun.
Tasks: derive a finite proposal/syntax/builtin inventory from Bun parser/runtime and test262 metadata;
implement missing post-ES2017 syntax and semantics, Proxy/Reflect completion, modern RegExp/Unicode,
modules/classes/iteration/collections/error features and other inventory items; give Intl/Temporal/
Atomics/SAB explicit owned milestones rather than implicit skips; update parser, emitter, intrinsics and
feature-tag curation. Milestone commits remain gated and the phase is not complete while an inventory row
lacks implementation or an approved constitutional disposition.
**Gate:** before implementation, freeze a manifest mapping every inventory item to exact test262 and Bun
fixtures and record Bun's pass set on the same commit/build; `make compat FEATURE=modern-ecmascript`
shows Clun at or above that pass set for every item, with no inventory row dispositioned merely for cost;
`make conformance-exec` keeps the global pass-list monotonic and enables every frozen feature tag; all
syntax negative/positive fixtures match Bun and the full vendored language+built-ins corpus has zero
crashes; `make build`; `make test`; `make purity`; `make docs-check`.

### Phase 38 — Web platform foundations  *(deps: 27, 28)* ~9k LOC ⚡⚡
Objective: supply the standards substrate required by Bun-compatible libraries, Node modules, and servers.
Tasks: inventory Bun `src/runtime/webcore/`, `test/js/web/`, types and applicable WPT subsets; implement
Event/EventTarget/DOMException, Blob/File/FormData, Readable/Writable/Transform streams including BYOB and
queuing/backpressure, MessageChannel/Port, performance APIs, WebCrypto/SubtleCrypto, compression streams,
structured clone transfers and missing Request/Response/Headers semantics; connect streams to Phase-28
transport without buffering; pin each WPT subset and deviation.
**Gate:** before implementation, freeze every WPT file applicable to each inventoried interface and record
the pinned Bun pass set; `make compat FEATURE=web-platform` shows Clun at or above Bun's pass set for every
interface with no unexplained exclusion; `make conformance-exec` is monotonic; 1 GiB stream pipelines have
bounded RSS and cancellation closes resources; the complete pinned Bun differential inventory passes;
`make build`; `make test`; `make purity`; `make docs-check` on all supported targets.

### Phase 39 — Full TypeScript transforms  *(deps: 09, 37)* ~7k LOC ⚡
Objective: execute the TypeScript runtime syntax that Bun transforms instead of rejecting it.
Tasks: inventory Bun `src/js_parser/`, `src/transpiler/`, TypeScript types/docs and
`test/bundler/bundler_typescript/`; replace strip-only handling for enums, runtime namespaces,
parameter properties, import/export assignment, decorators and other pinned syntax with AST transforms;
preserve module mode, evaluation order, names, comments and source locations; implement source maps for
non-whitespace-preserving transforms; keep type checking explicitly out unless present in the Bun surface.
**Gate:** `make compat FEATURE=typescript-transform` passes the complete pinned Bun/TypeScript runtime
fixture manifest in CJS and ESM modes; generated source maps return every thrown probe to its original
line/column; `make conformance-exec` is monotonic; `make build`; `make test`; `make purity`;
`make docs-check`.

### Phase 40 — JSX and TSX  *(deps: 39)* ~3.5k LOC
Objective: match Bun's direct JSX/TSX parsing and transformation behavior.
Tasks: inventory Bun JSX parser/transpiler options and fixtures; implement JSX lexical mode, elements,
fragments, namespaces/spreads and TSX ambiguities; implement classic/automatic/automatic-dev runtimes,
factory/fragment/import-source pragmas, development metadata and source maps; wire `.jsx`/`.tsx` through
runtime resolution and leave a shared transform for Phase 62.
**Gate:** `make compat FEATURE=jsx-tsx` passes all pinned JSX/TSX parser, transform, runtime, pragma,
module and error fixtures against Bun; source-map probes are exact; `make conformance-exec` is monotonic;
`make build`; `make test`; `make purity`; `make docs-check`.

### Phase 41 — Runtime and build loader plugins  *(deps: 07, 39, 40)* ~4k LOC ⚡
Objective: provide Bun-compatible runtime loader plugins and a reusable bundler plugin boundary.
Tasks: inventory `docs/runtime/plugins.mdx`, plugin types, loader source/tests; implement plugin setup,
ordered `onResolve`/`onLoad` filters, namespaces, loader selection, virtual modules, pluginData and async
callbacks; define cache, cycle, error and concurrent-load behavior; keep plugin JS as user code and all
implementation machinery in CL; expose the same host to Phases 62–64 without duplicating semantics.
**Gate:** `make compat FEATURE=loader-plugins` passes the complete pinned runtime plugin corpus including
ordering, async, virtual/cycle, invalid-result and cache-invalidation cases; parallel module loads are
deterministic and leak-free; `make conformance-exec`; `make build`; `make test`; `make purity`;
`make docs-check`. This gate may upgrade the runtime module-loader row only; build-plugin parity remains
owned by Phases 63 and 77 and cannot inherit a `Yes` from this gate.

### Phase 42 — node:stream compatibility  *(deps: 38)* ~8k LOC ⚡⚡
Objective: close the largest Node ecosystem compatibility cliff with stream semantics shared across I/O.
Tasks: inventory Bun `src/js/node/stream*`, Node compatibility docs and `test/js/node/stream/`; implement
Readable/Writable/Duplex/Transform/PassThrough, object mode, buffering/highWaterMark, pipe/unpipe,
finished/pipeline/compose, async iteration, destroy/error/close ordering and Web-stream bridges; connect
fs, child pipes, HTTP and compression without copying or reactor-thread violations.
**Gate:** `make compat FEATURE=node-stream` passes the pinned Bun surface inventory and selected upstream
Node stream suites at the recorded Bun pass set; exact event/error/backpressure ordering matches; 1 GiB
pipelines remain bounded, cancel promptly and leak no handles; `make conformance-exec`; `make build`;
`make test`; `make purity`; `make docs-check` on all supported targets.

### Phase 43 — node:net, DNS, TLS, and datagram compatibility  *(deps: 28, 42)* ~8k LOC ⚡
Objective: expose Node-compatible network modules over the pure-CL reactor and transport layers.
Tasks: inventory Bun/Node `net`, `dns`, `tls`, `dgram` types/docs/source/tests; implement Socket/Server,
lookup/resolver APIs, TLSSocket/Server/context/session/SNI/ALPN, UDP4/UDP6 membership and relevant options;
map errno and lifecycle/event ordering exactly; preserve backpressure, half-close, ref/unref, AbortSignal,
IPv4/IPv6 and platform differences; keep certificate verification fail-closed.
**Gate:** `make compat FEATURE=node-network` passes the pinned Bun pass set from upstream Node module
suites against hermetic TCP/UDP/DNS/TLS peers; 2,000 sequential + 500 concurrent connections, IPv6, TLS
resume, cancellation and 1,000 open/close cycles leak no descriptors/threads; `make build`; `make test`;
`make test-tls`; `make purity`; `make docs-check` on all four targets.

### Phase 44 — node:http, node:https, and HTTP/2 compatibility  *(deps: 43)* ~10k LOC ⚡⚡
Objective: meet Bun's Node HTTP client/server compatibility, including the pinned HTTP/2 surface.
Tasks: inventory Bun/Node HTTP implementations and `test/js/node/http*`; implement ClientRequest,
IncomingMessage, ServerResponse, Agent/pooling, upgrade/connect, trailers, streaming bodies and precise
event/error semantics over Phases 28/42/43; implement the pinned `node:http2` client/server, framing,
HPACK, flow control, cancellation and limits in pure CL; share parsers without weakening Phase-17 bounds.
**Gate:** `make compat FEATURE=node-http` passes the recorded Bun pass set from Node HTTP/HTTPS/HTTP2
suites and hermetic interop peers; slowloris, smuggling, oversized-frame/header and abort adversaries fail
safely; streaming load has bounded RSS and no handles leak; `make build`; `make test`; `make test-tls`;
`make purity`; `make docs-check` on supported targets.

### Phase 45 — node:crypto and node:zlib compatibility  *(deps: 19, 38, 42)* ~8k LOC ⚡
Objective: supply the crypto and compression module breadth required by Bun-compatible packages.
Tasks: inventory Bun `src/runtime/crypto/`, Node crypto/zlib docs and tests; wrap the approved pure-CL
primitives in Node Hash/Hmac/Cipher/Decipher/Sign/Verify/KeyObject/KDF/random/certificate APIs, streams and
WebCrypto bridges; add missing approved algorithms only after a purity/security audit; implement zlib,
gzip, deflate and the pinned Brotli surface where a pure implementation is approved, with dictionaries,
flush parameters, streams and strict expansion limits; never claim FIPS or side-channel hardening unproven.
**Gate:** `make compat FEATURE=node-crypto-zlib` passes published KATs and the pinned Bun pass set from
Node crypto/zlib suites; cross-tool vectors round-trip; decompression bombs and hostile key parameters
are bounded; `make test-crypto`; `make test-tls`; `make build`; `make test`; `make purity`;
`make docs-check`.

### Phase 46 — Processes, VM, workers, and async hooks  *(deps: 24, 37, 42, 43)* ~12k LOC ⚡⚡
Objective: implement the remaining execution/concurrency modules that real Node packages assume.
Tasks: inventory Bun's `child_process`, `vm`, `worker_threads`, `async_hooks`, `cluster` and process tests;
complete spawn/exec/fork/IPC and stdio streams; add realms/contexts/Script/Module with timeouts and
break-on-signal; implement Worker/MessagePort/transfer/SharedArrayBuffer semantics without sharing mutable
JS heaps unsafely; propagate AsyncLocalStorage across promises/timers/I/O; implement cluster scheduling
where portable and document exact platform limits. Milestone each module behind a complete fixture set.
**Gate:** `make compat FEATURE=node-execution` passes the pinned Bun pass set for all five module groups;
IPC/transfer/context isolation, async-context propagation, forced termination and 1,000 lifecycle cycles
are exact and leak-free; `make conformance-exec`; `make build`; `make test`; `make purity`;
`make docs-check` on all supported targets.

### Phase 47 — Node compatibility certification  *(deps: 42–46)* ~12k LOC ⚡⚡
Objective: make the Node-compatibility matrix at least as capable as the pinned Bun baseline in practice.
Tasks: derive a finite module/global inventory from `docs/runtime/nodejs-compat.mdx`, Bun types and
`test/js/node/`; complete remaining fs/buffer/process/url/util/events/assert/module/perf_hooks/tty/readline/
string_decoder/diagnostics/trace/domain/WASI surfaces to Bun's recorded level; run a pinned, licensed
real-package/framework corpus covering CLIs, servers, build tools and test libraries; record every Bun
partial as an explicit threshold rather than calling it full Node compatibility.
**Gate:** `make compat FEATURE=node-certification` shows no purity-compatible module/global below the
pinned Bun status or recorded upstream-Node pass set; every package corpus entry installs, runs its smoke
and exits identically; `make conformance-exec`; `make build`; `make test`; `make purity`;
`make docs-check`; the Node compatibility row may improve only from this evidence.

### Phase 48 — Native-addon constitutional checkpoint and conditional implementation  *(deps: 27, 47)* research + milestones
Objective: decide honestly whether N-API/V8/FFI compatibility can coexist with Clun's constitutional purity
and, if amended, keep this phase open through the actual implementation.
Tasks: inventory Bun `test/napi/`, `test/v8/`, `bun:ffi` types/source and the binary loading/calling path;
write threat, portability and implementation analyses for Linux/macOS x64/arm64; test pure-CL process-
isolation or protocol alternatives only as a timeboxed spike and reject them as parity if they require an
external runtime or cannot load the same addon; present one narrow optional-boundary amendment and one
purity-preserving rejection, with consequences. Do not implement CFFI, alien calls, executable trampolines,
or a subprocess disguise before the operator records a constitutional decision. If the amendment is
accepted, add gated milestones inside Phase 48 for the foreign-call boundary, dynamic library loading,
N-API lifecycle/thread-safety, the pinned V8 compatibility subset, `bun:ffi`, and all four targets; do not
advance `STATE.md` to Phase 49 while any conditional milestone is incomplete.
**Gate:** `docs/design/phase-48.md` contains cited executable spike evidence and an operator decision is
recorded in `DECISIONS.md`. If purity is retained, `make compat FEATURE=native-addons` proves a clear,
tested unsupported error and the matrix remains `No — constitutional`; if amended, the implemented Phase-48
milestones and `make compat FEATURE=native-addons` must pass the complete frozen N-API/V8/FFI corpus on all
four targets before the phase completes or any `Yes` claim appears. In either completed branch: `make build`;
`make test`; the decision-adjusted `make purity`; and `make docs-check` remain green.

### Phase 49 — HTTP server parity  *(deps: 38, 44)* ~8k LOC ⚡
Objective: meet the pinned `Bun.serve` HTTP/TLS surface before routing and WebSocket extensions.
Tasks: inventory Bun `src/runtime/server/`, `packages/bun-types/serve.d.ts`, docs and HTTP server tests;
complete streaming Request/Response bodies, TLS options/reload, timeouts, limits, error/development modes,
abort/disconnect, graceful reload/stop, Unix sockets, multi-listen/reuse-port and supported protocol
options; align Server properties/methods and per-request metadata; retain smuggling/header/path safety.
**Gate:** `make compat FEATURE=http-server` passes the complete pinned non-router/non-WebSocket
`Bun.serve` inventory; hermetic curl/Bun clients exercise HTTP, HTTPS, streaming, abort and reload;
50k sequential + 2k concurrent requests plateau in RSS and leak no handles; same-host workload is recorded
without a speed claim; `make build`; `make test`; `make test-tls`; `make purity`; `make docs-check`.

### Phase 50 — Router, static files, and FileSystemRouter  *(deps: 30, 49)* ~5k LOC ⚡
Objective: match Bun's first-party route table, static response and filesystem routing facilities.
Tasks: inventory serve route types/tests and FileSystemRouter source/docs; implement exact/static/parameter/
wildcard/method routes, precedence, decoded params and reload; implement safe static-file responses with
range/conditional/cache headers and traversal/symlink defenses; implement filesystem route discovery,
style matching, params, origin/assetPrefix and development refresh; share glob/path primitives.
**Gate:** `make compat FEATURE=http-router` passes the complete pinned route/FileSystemRouter/static
differential corpus; ambiguous precedence, percent-encoding, traversal, symlink escape, range and reload
adversaries pass; a 100k-route synthetic table meets the design's lookup/memory bound; `make build`;
`make test`; `make purity`; `make docs-check` on all supported targets.

### Phase 51 — WebSocket and Pub/Sub  *(deps: 43, 49, 50)* ~7k LOC ⚡
Objective: match Bun's WebSocket client/server and topic-based Pub/Sub behavior.
Tasks: inventory Bun server WebSocket types/source/tests and `src/http/websocket_client/`; implement RFC
6455 handshake/framing, masking, fragmentation, control frames, close/error states, compression negotiation,
client redirects/proxy/TLS, backpressure and AbortSignal; integrate `Bun.serve`-shaped upgrade/data,
per-socket data, cork, publish/subscribe/topic counts and server-wide publish without running JS in I/O
callbacks; bound frames, compression expansion, queues and subscriber cleanup.
**Gate:** `make compat FEATURE=websocket-pubsub` passes the complete pinned Bun differential corpus and
protocol Autobahn-style fixtures; 10k connect/message/close cycles and 10k subscribers leak no handles or
topics; fragmentation, slow-consumer, compression-bomb and malformed-frame adversaries pass;
`make build`; `make test`; `make test-tls`; `make purity`; `make docs-check` on all supported targets.

### Phase 52 — Single-file executables  *(deps: 39, 40, 47, 62–64)* estimate after bundle/signing design ⚡
Objective: compile a Clun application and declared assets into a distributable executable.
Tasks: inventory the complete Bun compile CLI/options/types/tests; define the one versioned module/asset
graph and bundle table by extending the production bundle graph already proven in Phases 62–64, never
a parallel compile graph, including entry/module resolution, embedded assets/files, argv/env/import.meta
behavior, bytecode/source policy, dynamic-import limits and reproducible builds; package
audited target-runtime templates so every supported host can emit Linux/macOS x64/arm64 artifacts without a
host compiler; implement pure-CL Mach-O signing for the frozen Bun-supported modes over approved crypto and
portable icon/metadata handling; treat external `codesign` only as a test oracle, never an implementation
step; preserve GPL/source-notice obligations in produced artifacts.
**Gate:** `make compat FEATURE=single-executable` passes the complete frozen Bun compile corpus for CLI,
server, worker, asset and dynamic-import cases; every Linux/macOS x64/arm64 source-host job emits all four
targets (16 host→target pairs), and each artifact executes in its native target job with no installed Clun;
macOS outputs signed by Clun pass independent `codesign --verify` fixtures, two clean builds are byte-identical
apart from an explicitly documented build-id/signature field, and tampered bundle metadata fails closed. If
pure signing proves impossible, only an operator-approved constitutional amendment may change the gate; a
manual signer or native-only build leaves the row `Partial` and the phase open. `make build`; `make test`;
`make purity`; `make docs-check`.

### Phase 53 — S3 client  *(deps: 19, 28, 38)* ~5k LOC ⚡
Objective: match the pinned `Bun.s3`/S3Client/S3File surface over pure-CL transport and crypto.
Tasks: inventory `docs/runtime/s3.mdx`, types/source/tests; implement credential/provider precedence,
AWS SigV4, endpoint/region/path-style options, get/head/exists/write/delete, ranges, multipart upload,
presign, retries/cancellation/checksums and Blob/File integration; stream bodies with backpressure and cap
metadata/errors; use a hermetic S3 protocol fixture with deterministic clock/credentials plus one opt-in
live smoke against an operator-provided endpoint.
**Gate:** `make compat FEATURE=s3` matches Bun request bytes, signatures, responses and errors for the full
pinned inventory; multipart retry/abort, 5 GiB synthetic streaming, clock skew and hostile XML cases pass
boundedly; `make build`; `make test`; `make test-crypto`; `make purity`; `make docs-check` on all targets.

### Phase 54 — Redis and Valkey client  *(deps: 19, 28)* ~5k LOC ⚡
Objective: provide Bun-compatible Redis/Valkey commands, pipelining and Pub/Sub.
Tasks: inventory Bun Redis types/docs/source/tests; implement RESP2/RESP3 framing, typed replies/errors,
connection/auth/select, command API, pipelining/transactions, reconnect/backoff, TLS, cluster redirection and
sentinel behavior present in the pinned surface; implement dedicated Pub/Sub connections and async message
delivery with bounded queues; generate command metadata from a pinned data file rather than hand-copying it.
**Gate:** `make compat FEATURE=redis` passes the full pinned API corpus against hermetic RESP peers and
pinned Redis/Valkey integration services; fragmentation, MOVED/ASK, reconnect, cancellation, slow subscriber
and malformed-length adversaries pass; 1M pipelined replies remain bounded; `make build`; `make test`;
`make test-tls`; `make purity`; `make docs-check`.

### Phase 55 — PostgreSQL driver  *(deps: 19, 28, 38)* ~8k LOC ⚡
Objective: implement the PostgreSQL half of Bun's unified SQL API without a native client library.
Tasks: inventory Bun `src/sql/`, `docs/runtime/sql.mdx`, SQL types/tests; implement startup/auth including
SCRAM, TLS, simple/extended query, prepared statements, parameter/result codecs, transactions/savepoints,
pooling, cancellation, notices/errors, arrays/JSON/date/numeric/binary types, COPY and tagged-template query
safety present in the pinned surface; isolate protocol framing and cap every server-controlled length.
**Gate:** `make compat FEATURE=postgresql` passes the pinned Bun API/protocol corpus against pinned
PostgreSQL versions on all supported targets; transaction/pool/cancel/reconnect/type/COPY and SQL-injection
fixtures pass; malformed server frames fail boundedly; 10k acquire/query/release cycles leak no handles;
`make build`; `make test`; `make test-tls`; `make purity`; `make docs-check`.

### Phase 56 — MySQL driver  *(deps: 19, 28, 38, 55)* ~8k LOC ⚡
Objective: implement the MySQL half of Bun's unified SQL API with semantics aligned to Phase 55.
Tasks: inventory Bun SQL MySQL source/tests; implement handshake/capabilities, approved authentication,
TLS, text/binary protocols, prepared statements, parameter/result codecs, transactions, pooling,
cancellation/timeout, multi-result behavior and tagged-template safety; share only the public SQL/pool layer,
not protocol assumptions; cap packet lengths and reject insecure auth downgrade.
**Gate:** `make compat FEATURE=mysql` passes the pinned Bun corpus against pinned MySQL and MariaDB peers
on supported targets; auth/TLS/type/transaction/pool/cancel/multi-result/injection fixtures pass; malformed
packets and downgrade attempts fail closed; 10k pool cycles leak no handles; `make build`; `make test`;
`make test-tls`; `make purity`; `make docs-check`.

### Phase 57 — SQLite design checkpoint and implementation  *(deps: 19, 27, 55)* research + milestones
Objective: implement Bun's SQLite surface in pure Common Lisp unless the operator explicitly abandons the
purity-compatible Bun-surface release target; implementation cost alone is not a constitutional conflict.
Tasks: inventory `bun:sqlite`, `node:sqlite`, Bun SQL SQLite source/tests and file/locking requirements;
compare a pure-CL SQLite file-format+B-tree+pager+SQL-engine implementation, a narrowly amended optional
native boundary, and an explicit scope-reduction decision; analyze WAL, locking, crash recovery, SQL breadth,
extensions, platform behavior and maintenance cost. The default parity path milestones pager/journal →
parser/planner/VM → types/statements/transactions → Bun/node APIs, with corruption fuzzing at each step. No
native binding lands before an operator-approved constitutional amendment; declining both implementation
paths records a non-parity scope change and does not complete Phase 57.
**Gate:** the implementation decision is recorded with spike evidence. The selected implementation must pass
`make compat FEATURE=sqlite`, the pinned Bun/node SQLite corpus, transactional crash-recovery/corruption/
locking tests and all four platform jobs before the phase completes or a positive claim appears. An
unsupported result keeps the matrix explicit, leaves this phase and §1.5 open, and requires the release to be
renamed or rescoped rather than calling the gap constitutional. `make build`; `make test`; `make purity`;
`make docs-check`.

### Phase 58 — Operating-system secrets constitutional checkpoint  *(deps: 19, 27)* ~2k LOC research
Objective: decide whether Bun-compatible OS credential storage can be delivered on all supported targets
without native foreign calls or shell-command substitution.
Tasks: inventory `docs/runtime/secrets.mdx`, types/source/tests and Bun's macOS Keychain/Linux libsecret
paths; research a pure D-Bus Secret Service client and a pure protocol to macOS Keychain services; threat-
model ACLs, prompts, locked stores, service/account encoding, cancellation and CI fixtures; distinguish an
encrypted Clun file from OS-keychain parity and never relabel it. Present pure implementation, narrow
optional-boundary amendment and explicit unsupported choices to the operator.
**Gate:** an operator decision with cited spikes is recorded. A positive path must pass
`make compat FEATURE=os-secrets`, hermetic locked/unlocked/error/concurrency fixtures and native jobs on
Linux/macOS x64/arm64 before `Yes`; otherwise the ledger remains `No — constitutional` with a tested clear
error. Always run `make build`; `make test`; `make purity`; `make docs-check`.

### Phase 59 — Package registry and dependency-spec breadth  *(deps: 19, 28)* estimate after Git/SSH design ⚡⚡
Objective: match Bun's accepted package specifications, registry configuration and deterministic install graph.
Tasks: inventory Bun `src/install/`, install CLI docs/tests and lockfile formats; implement npm aliases,
dist-tags, tarball/URL, git/GitHub, local file/directory, workspace/catalog specs, overrides/resolutions,
optional/peer/peerOptional/bundled deps, engines/os/cpu, auth/scoped registries/proxies/certs and lockfile
migration; implement Git smart-HTTP negotiation, pack/index/delta validation and safe checkout in pure CL;
implement the frozen `git+ssh` surface with a pure-CL SSH transport, strict host-key verification and pinned
key/agent authentication over approved crypto, never by invoking `git` or `ssh`; add isolated/hoisted linker
modes where pinned; treat lifecycle execution as Phase 61 policy; keep fetch/extract transactional,
integrity-checked and traversal-safe.
**Gate:** `make compat FEATURE=package-specs` passes the complete pinned Bun install graph/spec/config/
lockfile corpus; offline reinstall is byte-identical; conflict/peer/platform/git/file/tarball/auth and
malicious archive cases pass; hermetic smart-HTTP and SSH peers exercise branch/tag/commit, host-key, auth,
pack corruption and subdirectory cases while `PATH` contains neither `git` nor `ssh`; public smoke installs a
pinned representative graph; `make build`;
`make test`; `make purity`; `make docs-check` on all supported targets.

### Phase 60 — Workspaces and monorepos  *(deps: 59)* ~5k LOC ⚡
Objective: provide Bun-compatible workspace discovery, protocols, filtering and monorepo execution.
Tasks: inventory Bun workspace/catalog/filter docs/source/tests; implement workspace globs/exclusions,
`workspace:` resolution, catalogs, root/leaf rules, dependency linking, focused/filter installs and
deterministic lock entries; implement filtered recursive script execution with dependency/topological and
parallel limits, cancellation and exact exit propagation; prevent symlink escape and duplicate ownership.
**Gate:** `make compat FEATURE=workspaces` passes the pinned Bun monorepo/install/run corpus including
cycles, nested roots, catalogs, filters and failures; offline reinstall/layout/lock are byte-identical;
1,000-package synthetic workspaces stay within recorded time/RSS bounds; `make build`; `make test`;
`make purity`; `make docs-check`.

### Phase 61 — Package-manager tools and security  *(deps: 19, 59, 60)* ~7k LOC ⚡
Objective: complete Bun-class package workflows without weakening Clun's install security posture.
Tasks: inventory Bun `x`/`bunx`, publish, link/unlink, outdated/update/why, patch, cache, audit and lifecycle
security docs/tests; implement cache-backed isolated `clun x`, registry publish/auth/OTP, global/local link,
updates/explanations, reproducible patching and cache administration; implement explicit trusted-dependency
lifecycle policy, sandbox/timeout/output limits where possible, and default-deny behavior for untrusted
packages; never execute scripts during mere metadata inspection.
**Gate:** `make compat FEATURE=package-tools` passes every pinned command/exit/output/filesystem fixture;
hermetic publish→install, x cache/offline, link, update/why/patch/audit and trusted/untrusted lifecycle e2e
flows pass; malicious scripts cannot escape documented policy or corrupt a prior install; `make build`;
`make test`; `make purity`; `make docs-check` on all targets.

### Phase 62 — Bundler core  *(deps: 37, 39–41)* ~12k LOC ⚡⚡
Objective: produce correct deterministic JavaScript/TypeScript bundles through one programmatic and CLI API.
Tasks: inventory Bun `src/bundler/`, parser/transpiler/resolver/AST, `Bun.build` types/docs and core
`test/bundler/` fixtures; implement entry graph, resolver conditions, CJS/ESM linking and live-binding
semantics, cycles, JS/TS/JSX/JSON/text/file loaders, runtime helpers, target/format/output naming, define/
external and diagnostics; reuse Phase-41 plugins and language transforms; make graph and output order
deterministic, path-safe and bounded. Defer advanced optimization and CSS/HTML to Phases 63–64.
**Gate:** `make compat FEATURE=bundler-core` passes the pinned core bundler manifest in API and CLI modes;
every output executes to the same typed results under its target runtime; clean builds are byte-identical;
cycle/live-binding/path/error adversaries pass; `make conformance-exec`; `make build`; `make test`;
`make purity`; `make docs-check` on all supported targets.

### Phase 63 — Advanced bundler  *(deps: 41, 62)* ~10k LOC ⚡⚡
Objective: match Bun's production optimization, splitting, mapping and introspection surface.
Tasks: inventory the remaining `Bun.build` types/docs/tests; implement tree shaking with sideEffects,
dead-code/constant folding, minification, code splitting/chunk naming, dynamic imports, source maps, banners/
footers, metafile, naming templates, compile-time env, macros, packages/external modes and plugin interaction;
preserve evaluation and error/source positions; establish conservative fallbacks whenever proof is absent.
**Gate:** `make compat FEATURE=bundler-advanced` passes the complete pinned non-CSS/HTML bundler corpus;
bundles execute identically before/after every optimization, source-map probes map exactly, and incremental/
parallel builds are deterministic; malicious names cannot escape outdir; record same-host workloads without
a speed claim; `make build`; `make test`; `make purity`; `make docs-check`.

### Phase 64 — CSS, HTML, and asset pipeline  *(deps: 31, 34, 62, 63)* ~12k LOC ⚡⚡
Objective: match Bun's browser-facing CSS/HTML entry points and production asset graph.
Tasks: inventory Bun `src/css/`, HTML/bundler sources, docs and CSS/HTML/asset fixtures; implement CSS
tokenize/parse/print, imports, modules, nesting, targets/prefixing, minification, source maps and URL graph;
implement HTML entry parsing, module/classic script and stylesheet discovery, preload/output rewriting and
dev/production modes; implement binary/text assets, hashes, public paths, data URLs, copy/file loaders and
manifest integrity; use Phase-34 color parsing and Phase-41 plugins without duplicate parsers.
**Gate:** `make compat FEATURE=web-bundler` passes the complete pinned CSS/HTML/asset corpus; generated
sites load in a hermetic browser smoke with correct module/style/asset behavior and source maps; traversal,
malformed markup/CSS and asset-collision cases pass; two builds are byte-identical; `make build`;
`make test`; `make purity`; `make docs-check`.

### Phase 65 — Cross-platform shell API  *(deps: 24, 30)* ~9k LOC ⚡
Objective: implement Bun's `$` shell language consistently on supported Linux and macOS targets.
Tasks: inventory Bun `src/shell/`, shell types/docs/tests; implement tagged-template interpolation with safe
escaping, parser/AST, variables, quoting, expansions/globs, substitutions, pipelines, redirects, logical/
control forms, background jobs and required builtins; expose stdout/stderr/text/json/lines, cwd/env, quiet/
nothrow and ShellError semantics; execute external commands only as the user-requested shell feature, never
as an internal implementation dependency; define platform-specific command behavior explicitly.
**Gate:** `make compat FEATURE=shell` passes the complete pinned Bun shell corpus on Linux/macOS x64/arm64;
injection fixtures prove interpolated values remain data, pipeline backpressure drains concurrently, signal/
exit ordering matches and 1,000 jobs leak no children/fds; `make build`; `make test`; `make purity`;
`make docs-check`.

### Phase 66 — Jest-compatible test-runner parity  *(deps: 15, 37, 39, 40)* ~10k LOC ⚡⚡
Objective: raise `clun test` from the v0.1 subset to the pinned Bun/Jest-compatible surface.
Tasks: inventory Bun `src/runtime/test_runner/`, `bun:test` types/docs and test-runner fixtures; implement
remaining expect matchers/asymmetric matchers, snapshots/inline snapshots, mocks/spies/module mocks/fake
timers, coverage, parameterized tests, retries, concurrency/parallel files, watch integration hooks,
preload/setup, reporters/JUnit, sharding/randomization and CLI filters; isolate files/workers and preserve
deterministic default output; make coverage account for TS/JSX source maps. Before implementation, freeze a
licensed upstream Jest compatibility manifest and record the pinned Bun pass set on exactly that manifest.
**Gate:** `make compat FEATURE=test-runner` passes the complete pinned Bun meta-test/CLI/output corpus and
shows Clun at or above Bun's pass set on every category in the frozen Jest manifest; no test may be dropped or
reclassified after implementation begins; snapshots are stable, mock/timer state cannot leak, coverage maps
to sources, serial/parallel results agree and 10k tests plateau in RSS; `make build`; `make test`;
`make purity`; `make docs-check` on all targets.

### Phase 67 — Watch mode and state-preserving hot reload  *(deps: 41, 49, 62, 66)* ~7k LOC ⚡
Objective: provide Bun-compatible restart watch mode and state-preserving hot reload where supported.
Tasks: inventory `docs/runtime/watch-mode.mdx`, watcher/hot-reload source/tests; implement portable stat-
polling change detection with coalescing, dependency-graph invalidation and ignore rules; implement `--watch`
process restart and `--hot` module replacement/state retention, dispose/accept/error recovery and server
connection preservation; integrate runtime, test runner, plugins and bundler without inotify/FSEvents FFI;
define fallbacks for modules that cannot be safely retained.
**Gate:** `make compat FEATURE=watch-hot` passes the pinned edit/add/delete/rename/config/error/server/test
corpus on Linux/macOS x64/arm64; changes are neither lost nor duplicated, old code/resources are collected,
connections survive promised hot cases, and 10k edit cycles plateau in RSS/fds; `make build`; `make test`;
`make purity`; `make docs-check`.

### Phase 68 — Frontend development server and HMR  *(deps: 49–51, 62–64, 67)* ~12k LOC ⚡⚡
Objective: match Bun's first-party frontend serving, transform graph and browser HMR experience.
Tasks: inventory Bun `src/bake/`, development server types/docs/tests; implement HTML entry serving,
on-demand graph builds, browser module resolution, CSS/asset handling, overlay diagnostics, source maps,
WebSocket HMR protocol, module/CSS hot updates and full-reload fallback; integrate routing/static serving,
plugins and env modes; enforce origin/host controls, path isolation, cache invalidation and production-off
defaults; use real browser fixtures rather than DOM string assertions.
**Gate:** `make compat FEATURE=frontend-dev-server` passes the pinned Bun dev-server/HMR corpus; Playwright
desktop/mobile fixtures load actual output, apply JS/CSS updates, preserve accepted state, display mapped
errors and recover; cross-origin/traversal/cache adversaries pass; 10k changes plateau in RSS; `make build`;
`make test`; `make purity`; `make docs-check` on all supported targets.

### Phase 69 — Formatter  *(deps: 31, 34, 37, 39, 40, 64)* ~10k LOC ⚡⚡
Objective: exceed Bun's current matrix by shipping a deterministic first-party formatter.
Tasks: define and freeze Clun's JS/TS/JSX/JSON/YAML/CSS formatting contract; inventory licensed language
conformance and formatter corpora with explicit provenance; implement comment-preserving AST/doc layout,
stable line breaking, range/stdin/check/write modes, ignore files and editor-safe diagnostics; parse each
language with the shared production parser and guarantee idempotence. Do not claim Prettier identity unless
the complete chosen compatibility corpus proves it.
**Gate:** `make compat FEATURE=formatter` passes the pinned formatter corpus with zero parse/semantic
changes; format(format(x)) is byte-identical over the corpus and fuzz set; check/write/range/ignore/line-
ending fixtures pass on all targets; `make build`; `make test`; `make purity`; `make docs-check`; the matrix
marks this as a Clun advantage, not a Bun-compatible API.

### Phase 70 — Linter  *(deps: 37, 39, 40, 69)* ~10k LOC ⚡⚡
Objective: exceed Bun's current matrix with a fast, deterministic, extensible first-party linter.
Tasks: define a versioned recommended ruleset; implement shared AST/scope/control-flow/type-free semantic
analysis, diagnostics/fixes, config/ignore/overrides, per-file and project operation, stable parallel output
and machine-readable results; seed a bounded high-value rule inventory from specifications and licensed
corpora, with exact provenance; design pure-CL rule registration and no arbitrary foreign plugin execution.
**Gate:** `make compat FEATURE=linter` passes every rule's positive/negative/fix/idempotence corpus and
project/config/ignore/parallel CLI fixtures; applying all safe fixes then relinting is clean; fuzzed syntax
never crashes; `make build`; `make test`; `make purity`; `make docs-check` on all targets.

### Phase 71 — Comparative performance lab and engine tier  *(deps: 37, 47)* ~12k LOC ⚡
Objective: create defensible same-host Bun comparisons and add the measured engine tier needed to compete.
Tasks: pin release Clun and Bun binaries/commits; build a harness that records host, architecture, OS,
toolchain, power mode, affinity, warmup, repetitions and raw samples; cover cold startup, Richards/
DeltaBlue/Splay plus representative language/module/async/stream workloads; profile Clun, then implement only
measured engine work such as background `COMPILE` tiering, deeper/polymorphic ICs, specialized calls,
allocation reduction or compact bytecode, with deoptimization and conformance guards; publish all results,
including losses, in `docs/benchmarks.md`; freeze mandatory workload IDs, inputs, coverage categories and
directional metrics in the Phase-27 benchmark manifest before collecting an optimization baseline.
**Gate:** `make compat-bench FEATURE=engine --compare bun` reruns from clean release builds on one host and
produces statistically stable raw+summary artifacts; every mandatory engine workload individually meets or
exceeds the frozen Bun median in its declared throughput/latency metric with confidence intervals reported;
no aggregate may hide a losing workload, while cold start/RSS are separately reported and carry no parity
claim unless they independently meet their declared thresholds;
`make conformance-exec` is monotonic; `make build`; `make test`; `make purity`; `make docs-check`. If the
hard target is not met, the phase remains open or an operator changes scope explicitly; generated wording
names only the exact passing workloads and never says Clun is categorically faster than Bun.

### Phase 72 — Subsystem performance wave  *(deps: 28–47, 49–57, 59–71)* ~12k LOC ⚡⚡
Objective: make runtime tooling and services competitive with Bun on real, same-host workloads.
Tasks: freeze the mandatory subsystem workload inventory and coverage map before tuning; profile and optimize,
one green milestone at a time, HTTP/WebSocket throughput+tail latency,
package cold/warm/offline install, bundling/dev rebuild, test discovery/execution, shell pipelines, streams,
glob/string width, databases and cloud clients; preserve fixed workloads and separate I/O peer ceilings from
runtime cost; optimize algorithms/copying/allocation/scheduling only after a profile; keep correctness,
security bounds and portability gates ahead of a faster number.
**Gate:** `make compat-bench FEATURE=subsystems --compare bun` shows every mandatory registered workload at
or above the pinned Bun median throughput (or at/below its latency/time), with p95/p99, RSS, artifact size
and raw samples reported on the same host; all corresponding `make compat FEATURE=<id>` targets, four-
platform jobs, `make build`, `make test`, `make conformance-exec`, `make purity`, and `make docs-check` pass.
Any missing coverage category or miss leaves the owning milestone and Phase 72 open. Public claims name the
workload, Bun baseline, host and metric; this gate never licenses a blanket runtime/toolkit speed claim.

### Phase 73 — Exhaustive Bun public-surface freeze  *(deps: 27–72)* ~3k LOC tooling ⚡
Objective: freeze one finite, exhaustive Bun-surface target before implementing the remaining Bun 1.4.0-dev delta;
this phase does not release, tag, or move the baseline again.
Tasks: create a read-only Bun 1.3.14 stable tag checkout and record its commit, release-binary hashes and
observable CLI/API results without mutating `/home/glenda/Projects/bun`; separately verify that the existing
`c1076ce95e` checkout identifies as Bun 1.4.0-dev; generate a normalized public-surface manifest from all
`packages/bun-types` exports, documented runtime/package-manager/bundler/test APIs, CLI commands and flags,
loaders, protocols, globals/modules and platform-qualified behavior; execute both Bun baselines to resolve
docs/type/source disagreements; classify stable-only, shared and engineering-dev additions; assign exactly one
primary phase owner and any integration owners to every entry; hash and check in the manifest, corpus lists and
baseline metadata. Items published by Bun after this hash are explicitly queued for the next release train.
**Gate:** `make compat-freeze` produces byte-identical manifests in two clean scans; `make compat-validate`
reports zero unowned or duplicate-primary entries and proves every source/type/doc/CLI export is represented;
stable entries cite Bun 1.3.14 evidence while dev additions cite `c1076ce95e` / Bun 1.4.0-dev evidence; every
remaining gap is assigned to Phases 74–80; `make docs-check`; `make build`; `make test`; `make purity`. No
README/site parity status changes and no tag are permitted in this phase.

### Phase 74 — Archive and compression APIs  *(deps: 45, 59, 73)* estimate after inventory ⚡
Objective: match the frozen `Bun.Archive`/tar and high-level compression utility surface in pure Common Lisp.
Tasks: inventory the Phase-73 archive, gzip/gunzip, deflate/inflate, zstd and stream/file overloads; implement
archive inspect/create/extract and streaming entry iteration over the shared safe tar primitives; implement
all missing compressors/decompressors, options, sync/async forms, dictionaries and exact errors without
foreign codecs; preserve metadata and deterministic output where Bun does; enforce path, link, count, ratio,
window, allocation and output limits before allocation or extraction; run CPU-heavy work off the JS thread.
**Gate:** `make compat FEATURE=archive-compression` passes the complete frozen Bun API/error corpus and
cross-tool vectors for every format; generated archives round-trip metadata, malicious paths/links and
truncation fail closed, compression bombs remain bounded, async operations do not block the reactor, and
1,000 open/close/error cycles leak no handles; `make build`; `make test`; `make test-crypto`; `make purity`;
`make docs-check` on all supported targets.

### Phase 75 — Data formats, Markdown, and HTMLRewriter  *(deps: 31, 38, 64, 73)* estimate after inventory ⚡⚡
Objective: close the frozen TOML, JSON5, JSONL, Markdown and streaming HTMLRewriter surface omitted from the
original post-v0.1 backlog.
Tasks: milestone each format independently from the Phase-73 manifest; implement exact parse/stringify,
module-loader and streaming forms for TOML/JSON5/JSONL; implement Bun's Markdown parse/render/API contract;
implement streaming HTML tokenization and selector matching with element/text/comment/document handlers,
mutation, async callbacks, encoding and backpressure semantics; share YAML/JSON, Web-stream and Phase-64 HTML
primitives only where behavior is identical; cap nesting, token/input size, JSONL records and handler queues;
record provenance for every standards corpus and never import a JS parser as implementation code.
**Gate:** `make compat FEATURE=data-formats-html-rewriter` passes every frozen API/module/error fixture and the
pinned standards corpora at Bun's pass set; chunk-boundary differential tests produce identical typed values
and bytes for every split point; malformed/deep/large inputs and expansion adversaries fail boundedly; browser
smokes consume rewritten output; `make conformance-exec`; `make build`; `make test`; `make purity`;
`make docs-check` on all targets.

### Phase 76 — Cron, scheduling, and interactive REPL  *(deps: 14, 37, 46, 73)* estimate after inventory ⚡
Objective: match Bun's frozen cron/scheduling behavior and promote the standalone REPL backlog into a shipped,
scriptable interactive interface.
Tasks: implement the frozen cron expression grammar, timezone/clock behavior, overlap/cancellation/ref-unref,
missed-run and shutdown semantics over the timer/event-loop substrate; implement an interactive `clun repl`
with multiline parsing, top-level await, persistent lexical state, history/config, inspect/error output,
signals and piped/non-TTY operation; make terminal editing an internal pure-CL facility with dumb-terminal
fallback rather than invoking another runtime or line editor; use injectable clocks and terminal peers only in
tests; bound catch-up work, history size and hostile pasted input.
**Gate:** `make compat FEATURE=cron-scheduling` passes every frozen Bun scheduling fixture across DST,
timezone, overlap and cancellation cases; `make compat FEATURE=repl` passes hermetic PTY and piped-input
transcripts for expressions, modules, await, multiline, errors, Ctrl-C/Ctrl-D and history; fake-clock tests
contain no sleeps, 100k scheduled entries remain within the design bound, and 1,000 REPL sessions leak no
processes/fds; `make conformance-exec`; `make build`; `make test`; `make purity`; `make docs-check`.

### Phase 77 — Programmatic transpiler and build APIs  *(deps: 41, 52, 62–64, 73)* estimate after inventory ⚡
Objective: expose the complete frozen `Bun.Transpiler` and programmatic build surface over the same production
parser, transform, plugin, bundle and compile graph used by the CLIs.
Tasks: implement constructor/options, scan/scanImports, transform/transformSync, loader/target/define/macro,
source-map and diagnostic behavior; finish `Bun.build`/buildSync result/log/output/metafile APIs, cancellation,
incremental behavior and runtime/build plugins; remove any semantic fork between runtime transforms, bundling
and Phase-52 executable compilation; rerun the cross-target compile surface after integration; preserve exact
async ordering, typed errors and deterministic bytes.
**Gate:** `make compat FEATURE=programmatic-transpiler-build` passes every frozen type/doc/test overload in
sync and async modes and the complete plugin corpus; API and CLI builds produce byte-identical graphs/outputs
for equivalent options; Phase-52 host×target and signing gates rerun unchanged; source-map probes are exact,
cancellation leaks no work, and parallel builds are deterministic; `make conformance-exec`; `make build`;
`make test`; `make purity`; `make docs-check` on all targets. Build-plugin and single-executable rows may become
`Yes` only from this combined evidence.

### Phase 78 — Image processing  *(deps: 34, 38, 64, 73, 74)* estimate after inventory ⚡⚡
Objective: implement the complete frozen Bun image API and codec set without native libraries or subprocesses.
Tasks: freeze the exact formats, color models, metadata, decode/encode, resize/crop/transform and sync/async
surface; implement the required codecs and pixel pipeline in pure CL, reusing approved compression/color
primitives; define alpha, orientation, ICC/profile and deterministic encoder behavior; stream where the API
permits and run CPU work off the JS thread; bounds-check dimensions, strides, chunk lengths, metadata,
allocation products and decompression ratios before allocation; fuzz every parser and differential-test Bun
within documented numeric/image tolerances.
**Gate:** `make compat FEATURE=image` passes every frozen Bun fixture plus licensed conformance and malformed-
image corpora for every claimed format; decoded pixels/metadata and encoded round trips meet the frozen exact
or tolerance rule; gigapixel headers and compression bombs fail before large allocation, async work keeps the
reactor responsive, and repeated decode/error cycles plateau in RSS; `make build`; `make test`; `make purity`;
`make docs-check` on all supported targets.

### Phase 79 — WebView constitutional checkpoint and conditional implementation  *(deps: 46, 68, 73)* research + milestones
Objective: determine whether the frozen WebView surface can coexist with the purity contract and, if amended,
keep the phase open through a real implementation rather than substituting an external browser command.
Tasks: inventory Bun WebView types/docs/source/tests and each platform's lifecycle, IPC, navigation, window,
permission and packaging requirements; timebox pure protocol/process-isolation spikes and reject any approach
that cannot expose the same observable surface; threat-model untrusted content and origin/IPC boundaries;
present a narrow optional foreign-boundary amendment and an explicit purity-preserving rejection. If amended,
milestone the boundary, Linux/macOS backends, event-loop/worker integration, packaging and complete four-target
corpus inside Phase 79; never invoke `open`, `xdg-open`, a browser CLI or a hidden JS runtime as parity.
**Gate:** an operator decision with cited executable evidence is recorded. If purity is retained,
`make compat FEATURE=webview` proves a clear tested unsupported error and the ledger remains
`No — constitutional`; if amended, every conditional milestone and the complete frozen WebView corpus,
security fixtures and all four platform jobs pass before the phase completes or a positive claim appears.
In either completed branch: `make build`; `make test`; the decision-adjusted `make purity`; `make docs-check`.

### Phase 80 — Zero-unowned full public-surface closure  *(deps: 73–79)* milestones from frozen manifest ⚡⚡
Objective: implement every frozen purity-compatible public entry not already closed by Phases 27–79 so no
landing-row summary can hide an omitted Bun API, CLI flag, loader, protocol or utility.
Tasks: query the Phase-73 manifest for every `missing`, `partial`, `planned` or evidence-less item; create one
bounded green milestone per coherent owner group, including direct Bun TCP/UDP APIs, remaining utility/ANSI/
serialization APIs, package security-scanner hooks, CLI flags, globals and platform-qualified behavior found
by the freeze; implement each item in pure CL and rerun its primary plus integration-owner gates; for an
inherent purity conflict, require a narrowly written operator decision and tested explicit error rather than a
cost-based exception; remove a manifest entry only by proving it was not public at either frozen baseline.
**Gate:** `make compat-validate --frozen` reports zero unowned, duplicate-primary, `missing`, `planned`,
unexplained `partial`, or evidence-less entries; `make compat FEATURE=all` shows every purity-compatible entry
at or above its frozen Bun behavior and every inherent constitutional exception has its checkpoint decision
and tested error; an independent generated API/CLI/docs diff is empty; all affected feature gates and four-
platform jobs rerun; `make conformance-exec`; `make build`; `make test`; `make purity`; `make docs-check`.

### Phase 81 — Full-surface performance recheck  *(deps: 71, 72, 74–80)* estimate after inventory ⚡⚡
Objective: remeasure the complete frozen surface after the final API waves and close every workload-specific
regression without turning an aggregate into a blanket performance claim.
Tasks: before tuning, extend and freeze the Phase-27 benchmark manifest with representative archive/format/
HTMLRewriter/cron/REPL/transpiler/build/image/WebView-or-exception and Phase-80 workloads; rerun all Phase-71/
72 workloads from clean builds on the same recorded host; profile and optimize each losing workload without
weakening correctness, purity, bounds or portability; retain raw samples and publish losses as well as wins;
mark features with no meaningful Bun performance comparator explicitly rather than inventing one.
**Gate:** `make compat-bench FEATURE=full-surface --compare bun` reports every mandatory workload individually
at or above its frozen Bun throughput median or at/below its declared latency/time metric with confidence
intervals, p95/p99, RSS and artifact size separate; no missing coverage category or aggregate substitution is
allowed; all Phase-71/72 benchmark gates rerun, and all touched compatibility, conformance, four-platform,
build, test, purity and docs gates pass. Generated copy names only exact workloads and never makes a blanket
`faster/better/stronger than Bun` claim.

### Phase 82 — Purity-compatible Bun-surface final audit and release  *(deps: 27–81)*
Objective: prove the shipped release meets §1.5 against the immutable Phase-73 surface without an unsupported
or version-confused claim, then and only then tag it.
Tasks: verify the Phase-73 manifest hash and refuse a baseline refresh; audit every public entry, landing row,
platform qualifier, evidence link and workload-specific claim; ensure constitutional decisions for native
addons, OS secrets and WebView are explicit while SQLite has real implementation evidence; rerun security,
fuzz, stress, license/notices, reproducibility, installer and Linux/macOS x64/arm64 release tests; regenerate
README/site/release notes with Bun 1.3.14 labeled as the public stable comparison and `c1076ce95e` labeled as
the Bun 1.4.0-dev engineering target; perform independent correctness, security, purity, portability,
performance and claims reviews serially or with Codex/Sol 5.6 subagents.
**Gate:** `make compat-freeze --check`; `make compat-validate --frozen`; `make compat FEATURE=all`;
`make compat-bench FEATURE=full-surface --compare bun`; `make docs-check`; `make build`; `make test`;
`make conformance-exec`; `make test-crypto`; `make test-tls`; `make purity`; every required four-platform
release job and installer smoke passes; every frozen purity-compatible entry meets/exceeds Bun and every
inherent constitutional exception is plainly labeled; §1.5 is checked with evidence links in `STATE.md`;
tag the purity-compatible surface release only on that exact green commit.

### Phase 26 — Final hardening, docs, and release  *(deferred to the end; deps: 82 + all prior phases)*
Objective: harden and publish the complete system that exists after Phase 82.
Tasks: begin by re-inventorying the shipped surface, open findings, compatibility ledger, release train,
platform support, and every still-relevant Definition-of-Done item. Rewrite this phase's bounded design and
release target from that evidence; do not reuse the former `v0.1.0` target or assume today's checklist is
still complete. Audit every user-reachable failure for resource, rejected value, violated constraint, and
actionable remedy; prevent Lisp backtraces without `--backtrace`; run resource-plateau, interruption,
partial-install, largest-fixture, long-run server, and then-current platform stress gates; resolve or clearly
disposition local-time and other remaining compatibility gaps; regenerate README, landing page, release
notes, architecture, security posture, and contributing documentation; run Linux/macOS x64/arm64 release
jobs; perform independent correctness, security, purity, portability, performance, error-path, and claims
reviews, then fix every release-blocking finding.
**Gate:** the re-baselined final-phase design and canonical issue define an exact, finite checklist for the
then-current system; every item has executable evidence in `STATE.md`; all required compatibility,
conformance, stress, security, documentation, platform, release, and installer gates pass; the release
version and immutable tag follow `docs/versioning.md` and the actual completed SemVer impact.

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
| Raw perf: closure-compiled CL starts far behind a JIT on hot loops | Certain | Phase 25 improves the foundation; Phases 71–72 add same-host comparative labs and measured tiering; Phase 81 rechecks the frozen full surface. Only workload-specific claims may follow their hard gates |
| Async lowering correctness (try/finally × yield × return) | Med | Copy regenerator's scheme exactly; dense 262 coverage; thread-per-generator fallback is semantically safe |
| pure-tls is young, single-maintainer, unaudited | High | Vendor + pin; keep its suites in our CI; SRI sha512 independent integrity; posture labeling; fail-closed certs; MIT permits maintaining the fork |
| Purity leaks via transitive deps (one already found & patched) | Med | `make purity` in every gate; audit every `.asd` at vendor time |
| RegExp silent gaps bite real packages (unparticipated backrefs) | Med | Loud SyntaxError for the loud gaps; promote own-VM work if corpus scanning shows silent-gap frequency |
| test262 curation churn / gate gaming | Med | Pass-list only grows; reviewer checks skip-tag diffs every engine phase |
| SBCL internals churn (`unix-realpath`, `fd-stream-fd`) | Med | Pinned SBCL; quarantined in sbcl-compat.lisp with startup probes |
| Hoisted-resolution subtle wrongness | Med | Conflict-forcing fixtures; honest error over silent pick; compare observable layout to npm's for the same tree |
| GC pauses at large heaps | Med | Struct objects (measured 4×/2.7× win); minor-GC-only steady state; RSS-plateau gates |
| Parity scope becomes an unfinishable monolith | High | Phases 27–72 close the landing matrix; Phase 73 freezes one exhaustive finite surface; Phases 74–80 close it without accepting later Bun churn; constitutional exceptions remain explicit |

---

## Appendix A — Compatibility Matrix (maintain as you build; ships in README)

Legend: ✅ as documented · 🟡 partial (note what's missing) · ❌ non-goal v0.1.

| Area | v0.1 | Notes |
|---|---|---|
| Language core (ES2017 tier) | 🟡 | Strict+sloppy incl. `with`; no Proxy/Reflect/Intl/Temporal/Atomics; test262 pass-list is the ground truth |
| BigInt | 🟡 | Late-v0.1 scope; shipped status is evidence-driven |
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

Into `/home/glenda/Projects/bun` (engineering baseline `c1076ce95e`, Bun 1.4.0-dev; not the
Bun 1.3.14 stable public-comparison baseline):
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

## Appendix E — Promoted former backlog and remaining follow-ups

The former deferred backlog is now owned by the numbered purity-compatible surface program and must not be executed as an
unnumbered side track:

| Former backlog item | Owning phase(s) |
|---|---|
| Proxy/Reflect, modern RegExp/UCD and later ECMAScript/Intl work | 37 (plus 38 for Web-facing APIs) |
| `node:stream`, net, DNS, TLS, HTTP/HTTPS/HTTP2 | 42–44 |
| WebSocket server/client | 51 |
| Snapshots, mocks, matchers, coverage and parallel test files | 66 |
| Watch and hot reload | 67–68 |
| Reactor-native streaming TLS and A/AAAA resolution | 28, 43 |
| `clun x`, isolated installs and workspaces | 59–61 |
| punycode/IDNA and Node URL compatibility | 38, 47 |
| Single-file executables, cross-target packaging and signing | 52, 77 |
| SQLite design/decision/implementation | 57 |
| HTML rewriter | 75 |
| Standalone interactive REPL | 76 |
| Archive/compression runtime APIs | 74 |
| TOML, JSON5, JSONL and Markdown | 75 |
| Cron and scheduling | 76 |
| Programmatic Transpiler/build APIs | 77 |
| Image processing | 78 |
| WebView constitutional decision/conditional implementation | 79 |
| Frozen residual Bun utilities/APIs/CLI surface | 80 |

Items not present in the immutable Phase-73 surface remain explicitly unpromoted: HTTP/3/QUIC, deeper
macOS-native memory/uptime/CPU metrics beyond the portable `node:os` contract, and Windows support. If any
is present in the frozen surface, Phase 80 owns it instead; if Bun adds it after the freeze, it belongs to the
next release train. TZif local time remains unassigned until Phase 26 re-baselines the then-current system;
it is not silently added to Phase 37 or inherited from the obsolete final-phase checklist.
These follow-ups require a new numbered phase (Issue + user-standard plan-phase survey when applicable)
or an explicit scope amendment on the Issue before implementation; they are not permission to freelance
outside the active Issue or the purity contract.
