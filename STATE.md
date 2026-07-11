# STATE

Living checklist and the only session-to-session memory besides PLAN.md/DECISIONS.md.
Update before every commit. Seeded from PLAN.md §5.

---

## Current phase: **06 — Async engine (generators, promises, modules)**  (Phase 05 committed; event-loop gate MET)

**Phase 05 outcome:** the pure-SBCL reactor is live (`src/loop/` + `src/sys/sbcl-compat.lisp`, ~600
LOC). serve-event poll reactor + self-pipe wakeup (verified: signals don't wake serve-event, a byte
does — and the fd handler MUST be registered on the thread that runs serve-event, else it silently
never fires; `run-loop` registers it on the loop thread); own binary-heap timers (FIFO ties,
repeating, lazy cancel); handle refcounting (ref/unref real, loop exits at refs=0 ∧ queues empty);
enqueue-only signal delivery (atomic counter + self-pipe, §6 iron rule); sb-thread worker pool
(mailbox + loop-post completions); nextTick/microtask/task stub queues with Node-faithful drain
(nextTick priority, microtasks after each macrotask). Callbacks are CL thunks — Phase 06 wires JS
jobs into the same queues. **Gate MET:** timer ordering ✓, cross-thread wake <5 ms ✓, alive-iff-refs
✓, SIGINT→loop event ✓, microtask-drain ordering ✓. 674 unit tests; purity clean (110 files); 0
test262 regressions (parse 17,503 / exec 14,813, 0 crashes).

**Next action:** Begin Phase 06 (Async engine: regenerator-style generator lowering, Promise + job
queue wired into the loop's microtask queue, async/await, for-await, ESM linking/eval/TLA,
unhandled-rejection tracking). Deps 04 ✓ + 05 ✓. The loop's `enqueue-microtask`/`enqueue-next-tick`
are the promise/nextTick job sinks; `run-loop` dispatch points already drain them.

**Phase 04 outcome:** the stdlib core is broad and correct. Added 12 `builtins-*.lisp` modules
(~2,600 LOC): **Ryū** Number→String (interval method, exact-rational backend; cross-checked 0
mismatches vs the retained oracle over 40k+ random doubles + known-answer vectors), **JSON**
(own recursive-descent parser + SerializeJSONProperty printer), **Math** (full, trap-masked),
**Number** formatting (toFixed/toExponential/toPrecision/toString(radix)), **String** (~40 methods,
code-unit exact), **Array** (ES2017 prototype + statics, stable merge sort), **Object** extras +
**Reflect**, **Symbol** registry, **Map/Set/WeakMap/WeakSet** (SameValueZero + insertion order; SBCL
weak tables), **iterator protocol** (%IteratorPrototype% + concrete iterators), **Date** (UTC core,
pure gregorian math, ISO parse/format), **URI** functions, and a real **Function** constructor.
Measured **built-ins slice 83.5%** (8,912/10,673, gate ≥65% MET), **overall curated 81.0%**
(14,806/18,288 non-skip, gate ≥55% MET), **Ryū vectors pass**, **0 crashes** across the full
34,779-file exec phase. 583 CL unit tests pass; purity clean (101 files). exec-passlist regenerated
(+9,334 entries, monotonic). Key fix theme: NaN/Infinity float-trap discipline in builtins (new `%int`
helper; NaN-safe `js-zero-p`/`js-same-value(-zero)`; see DECISIONS 2026-07-10).

**Next action:** Begin Phase 05 (Event loop / async substrate, deps 01 ✓ — independent of the engine
track). NOTE Phase 04 deferred: RegExp-taking String overloads (match/replace/split with regexp) →
Phase 10; full UCD casing/normalize → later; TZif local time → Phase 26; Proxy → later; typed arrays
→ later. Phase 03 deferrals still open (`with`, tagged templates, full class super, mapped sloppy
`arguments`, global-scope TDZ); generators/async are Phase 06.

**Independent phases available if the main track blocks (◇):** 19 (crypto foundation, deps 00),
21-semver (deps 00), 16 (sockets, deps 05 ✓ — but respect the serve-event thread-registration rule).

---

## Blocked
_(nothing blocked)_

---

## Phase gate evidence log

- **Phase 00 — PASSED + committed (2026-07-10).**
  - `make build` → `build/clun` (save-lisp-and-die); `./build/clun --version` → `clun 0.0.1-dev`, exit 0. ✔
  - `make test` → parachute: 5 passed / 0 failed, exit 0. ✔
  - `make purity` → clean, 62 files scanned (load-plan ∪ src/tests/vendor), 0 violations; verified
    fails on a token planted in src/ AND in tests/. ✔
  - Fresh-clone build verified (ASDF cache cleared) + documented in README + docs/design/phase-00.md. ✔
  - Review panel (12 agents, 5 dimensions): 7 raw findings, 3 confirmed, all fixed — purity scanner
    now unions the ASDF load plan (closed a tests/ scan gap); STATE/DECISIONS/design wording corrected.

- **Phase 01 — PASSED + committed (2026-07-10).**
  - `make build` clean (zero warnings; fixed a constant-fold NaN trap); `make test` 261 passed / 0
    failed; `make purity` clean (73 files). Value-rep decided by micro-bench (native typecase 4.3x
    faster than tagged struct — DECISIONS.md).
  - Substrate: values/singletons, condition bridge, WTF-8 UTF-8⇄code-unit (WHATWG maximal-subpart),
    NaN/Inf/−0 + ToInt32/Uint32, Number↔String (shortest-round-trip), ToPrimitive/Boolean/Number/String.
  - Review panel (15 agents, 5 dims, verified by running code): 5 confirmed / 5 refuted. Fixed: major
    ASCII-digit-only StringToNumber (Unicode Nd digits were wrongly accepted); huge-exponent clamp
    (`"1e1000000"` 470ms→0ms); +completeness tests (huge strings, ToInt32 modulo, WTF-8 multibyte);
    trimmed an over-long comment.

- **Phase 02 — PASSED (#1/#3) + #2 operationalized + committed (2026-07-10).**
  - `make build` warning-free; `make test` 482 assertions; `make purity` clean; `make conformance`
    0 crashes / 23,713, 17,503-entry pass-list, no regressions.
  - Tokenizer + full ES2017 parser (0 crashes) + scope analyzer + AST printer + test262 runner.
  - Two review panels' findings all fixed (Phase-02 panel: 19 agents-confirmed, 0 refuted — for-in/of
    destructuring false-positive fix unblocked ~1,200 tests). Negative-parse 74.4% rejected, gate #2
    regression-proof via the growing pass-list; regexp-pattern negatives deferred to Phase 10.

- **Phase 03 — EXECUTION GATE MET + committed (2026-07-10).**
  - The engine executes real JavaScript. `make build` clean; `make test` 570 assertions; `make purity`
    clean (90 files); `make conformance-exec` **72.8% pass (5,460/7,500 curated, both modes)**, 0 crashes.
  - Object kernel + environments + operators + callables + realm/~60 builtins + closure emitter + eval.
  - Runner extended to an execution phase with a checked-in monotonic exec-passlist.

- **Phase 04 — STDLIB GATE MET + committed (2026-07-11).**
  - `make build` clean; `make test` **583 assertions** (incl. Ryū known-answer + 40k oracle
    cross-check); `make purity` clean (101 files); `make conformance-exec` over **34,779 files**:
    14,806 pass, **0 crashes**, exec-passlist +9,334 (monotonic).
  - **Gate:** built-ins slice **83.5%** (8,912/10,673 executed) ≥65% ✔; overall curated **81.0%**
    (14,806/18,288 non-skip) ≥55% ✔; **Ryū vectors pass** (0 mismatches vs oracle) ✔.
  - 12 `builtins-*.lisp` modules: Ryū, JSON, Math, Number-fmt, String, Array, Object+Reflect, Symbol,
    Map/Set/Weak*, iterator protocol, Date (UTC), URI; Function constructor. Runner extended to include
    the built-ins slice + periodic GC (21k execs/image).
  - Crash sweep: 278 → 0 (NaN/Infinity float-trap discipline — `%int`, NaN-safe zero/SameValue).
  - Adversarial review panel (6 dims × find→verify-by-running-code): **20 confirmed / 0 refuted**, all
    fixed then re-verified: JSON.parse EOF crashes (bounds-checked `jr-next`), pad/repeat heap-exhaustion
    → RangeError, toExponential/toPrecision ties-away rounding, JSON empty-replacer-array, Set −0
    canonicalization, Date.parse calendar/hour-24 validation, String.lastIndexOf position arg, Math.clz32
    (integer-length), Math.log10 exact powers of ten. Post-fix: +7 passes, 0 regressions, 0 crashes.

- **Phase 05 — EVENT-LOOP GATE MET + committed (2026-07-11).**
  - `make build` clean; `make test` **674 assertions** (17 loop tests); `make purity` clean (110
    files); `make conformance` 17,503 / 0 crashes; `make conformance-exec` 14,813 / 0 crashes — no
    regressions (engine untouched).
  - `src/loop/` (loop-core/timers/reactor/signals/workers/event-loop) + `src/sys/sbcl-compat.lisp`
    (self-pipe + poll probe). serve-event poll reactor, self-pipe wakeup, binary-heap timers, handle
    refcounting, enqueue-only signals, sb-thread worker pool, nextTick/microtask/task drain.
  - **Gate:** timer ordering ✓; cross-thread wake <5 ms ✓; alive-iff-refs ✓; SIGINT→event ✓;
    microtask-drain ordering ✓.
  - Verified gotcha (design doc + DECISIONS): SBCL dispatches an fd handler only on the thread that
    registered it → `run-loop` registers the self-pipe handler on the loop thread (Phase 16 must too).
  - Adversarial review panel (4 dims × verify-by-running-Lisp): **6 confirmed / 0 refuted**, all fixed
    + locked as regressions: (1) `loop-alive-p` ignored the mailbox → external/worker/callback
    loop-posts dropped at shutdown; (2) liveness ignored pending signal deltas → signal at shutdown
    dropped; (3) `destroy-event-loop` left OS signal handlers installed → stale handler wrote to the
    closed/recycled self-pipe fd (§6 use-after-close); (4) per-loop install flag guarded a
    process-global `enable-interrupt` → second live loop clobbered the first (now a loud error +
    ownership released on destroy). 680 unit tests after fixes; 0 regressions.

## Phases

Legend: `[x]` done · `[ ]` todo · ⚡ fan-out-friendly · ◇ independent-early.

### Phase 00 — Scaffold, toolchain, purity gate  (deps: none) — **DONE**
- [x] .gitignore / LICENSE (MIT) / README stub
- [x] clun.asd + package skeletons per §3.7 (src/packages.lisp)
- [x] Makefile (build / test / purity / clean)
- [x] scripts/purity-scan.lisp (directory scan of src/ + vendor/; §1.1)
- [x] vendor + pin cl-ppcre, parachute (+ dep closure); SHAs in DECISIONS.md
- [x] parachute smoke suite (tests/lisp/smoke.lisp)
- [x] tests/js stdout/exit-code harness **design** (docs/design/phase-00.md); runner deferred to Phase 08
- [x] GitHub Actions CI (ubuntu, pinned SBCL 2.6.4, make build test purity)
- [x] STATE.md seeded with every §5 task list
- [x] DECISIONS.md seeded with §3 pins + vendored SHAs
- [x] Phase 00 review panel (5 dimensions, adversarially verified) + phase-00 commit

### Phase 01 — Engine values & coercions  (deps: 00) ~2k LOC — **DONE**
- [x] docs/design/phase-01.md (data structures, ownership, risks)
- [x] value representation decision (native typecase; micro-bench 4.3x vs tagged struct; DECISIONS.md)
- [x] UTF-16-code-unit strings + UTF-8/WTF-8 boundary converters (WHATWG maximal-subpart decode)
- [x] doubles + trap-mask entry macro (with-js-floats)
- [x] NaN/Inf/−0 helpers
- [x] JS-exception-as-CL-condition bridge (js-condition / js-native-error)
- [x] ToPrimitive/ToNumber/ToString/ToInt32/ToUint32/ToBoolean kernel (+ js-string↔number)
- **Gate PASSED:** 261 parachute assertions over abstract-op edges + UTF-8⇄code-unit round-trips
  incl. lone surrogates/astral pairs; zero regressions; make build/test/purity green.

### Phase 02 — Lexer + parser + scope analysis  (deps: 01) ~7k LOC ⚡(fixtures) — **DONE**
- [x] tokenizer (ASI flags, regex-vs-divide re-scan, template mode stack, escapes, exact offsets, trivia, reentrant)
- [x] full ES2017 parser (classes, destructuring, arrows, generator/async, modules, spread, computed props) — 0 crashes
- [x] scope analyzer — lexical-redeclaration + var/lexical conflict early errors (hoisting/slot-indices/TDZ grow in P03)
- [x] AST printer (ast->sexp)
- [x] vendor test262 @ `d1d583d` + frontmatter parser + runner (`make conformance`) + checked-in pass-list (17,503, only-grows)
- **Gate: #1 no-crashes MET (0/23,713); #3 token-span MET; #2 operationalized via pass-list**
  (74.4% negatives rejected; regression-proof; ~169 regexp-pattern → Phase 10, rest a growing long tail).

### Phase 03 — Core evaluator + object kernel  (deps: 02) ~8k LOC — **DONE (gate MET 72.8%)**
- [x] closure emitter; frames + TDZ sentinel; (with/direct-eval slow frames → loud errors, deferred)
- [x] property tables + full descriptors + defineProperty; prototype chains; per-realm intrinsics indirection
- [x] functions (call/construct, this both modes, arguments — unmapped; sloppy aliasing deferred)
- [x] Array exotic; operators (== table, +, relational, instanceof, in, typeof, delete)
- [x] try/catch/finally, labels (incl. labelled break/continue), switch, for-in order; Error objects with .stack
- **Gate MET:** curated `language/` slice (minus gen/async/modules) 72.8% both modes; execution
  pass-list workflow live (`make conformance-exec`, crash- + regression-gated, only-grows).

### Phase 04 — Stdlib core  (deps: 03) ~9k LOC ⚡ — **DONE (gate MET: built-ins 83.5%, curated 81.0%)**
- [x] Object, Function, Array (ES2017), String (code-unit exact), Number, Boolean, Math
- [x] JSON (own parser/printer + Ryū port for Number→String; known-answer vectors)
- [x] Error hierarchy (+ES2022 cause); Symbol + well-knowns + registry; Map/Set/WeakMap/WeakSet (SBCL weak tables); iterator protocol; +Reflect
- [x] Date (UTC core; TZif deferred); global wiring + URI fns; eval/Function (parser in-image)
- **Gate:** built-ins slices for these globals ≥ 65% ✔ (83.5%); overall curated ≥ 55% ✔ (81.0%); Ryū vectors pass ✔.

### Phase 05 — Event loop core  (deps: 01; independent of 02–04) ◇ ~2.3k LOC — **DONE (gate MET)**
- [x] serve-event wrapper + startup capability probe (poll, fd>1023); self-pipe; mailbox integration
- [x] binary-heap timers; handle refcounting + ref/unref
- [x] signal delivery (enqueue-only); worker pool; graceful stop
- **Gate:** timer-ordering ✓; cross-thread wake < 5 ms ✓; process alive iff refs>0 ✓; SIGINT → loop
  event ✓; microtask-drain points honored (stub queue) ✓.

### Phase 06 — Async engine: generators, promises, modules  (deps: 04, 05) ~2.5k LOC
- [ ] regenerator-style lowering (state machine + try-entry tables); Generator objects
- [ ] Promise + job queue (engine-owned; nextTick queue ahead of microtasks); async functions
- [ ] for-await; async generators; ESM linking + evaluation + TLA
- [ ] unhandled-rejection tracking → error + exit 1; async-test262 runner support
- **Gate:** Promise/generator/async/for-await 262 dirs ≥ 75%; zero regressions; ordering corpus passes.

### Phase 07 — Module resolution & CJS  (deps: 06) ~2.5k LOC ⚡(fixtures)
- [ ] src/resolver/ pure CL (relative/absolute/bare, ext probing, dir index, main/exports/imports, self-refs, scoped, symlink realpath)
- [ ] ~40-tree fixture corpus (engine-free parachute tests)
- [ ] loader-hook wiring; CJS require (wrapper idiom, cache, cycles→partial, .cjs/.mjs/"type" gating)
- [ ] ESM↔CJS interop; JSON modules; import.meta.url/dirname/filename/main
- **Gate:** resolution corpus green; fixture app (ESM entry importing CJS dep w/ exports maps + scoped) runs.

### Phase 08 — CLI shell, console, process  (deps: 07) ~3k LOC
- [ ] dispatcher + exact flags (-e/-p as [eval] module, positional-stop, --cwd, --silent, --revision, --backtrace)
- [ ] .env autoload; the shared inspector + full console spec (§3.6)
- [ ] process core (argv/env/exit/exitCode/platform/arch/pid/cwd/chdir/versions/stdout.write/isTTY/hrtime/memoryUsage/on('exit'))
- [ ] uncaught-error rendering (message + JS stack, exit 1; no Lisp backtrace w/o --backtrace); exit codes 0/1/2
- [ ] **activate tests/js harness runner** (scripts/run-js-fixtures.lisp; wire into make test)
- **Gate:** run/eval fixture matrix (exit codes, stacks, -p awaiting a promise); console conformance vs Bun fixture subset.

### Phase 09 — TypeScript stripping  (deps: 08) ~2.5k LOC ⚡(corpus)
- [ ] strip pass per §3.3 sharing the engine lexer
- [ ] error catalog (enum/namespace/param-props/decorators/import=); .tsx rejection
- [ ] ≥60-pair corpus (vendor amaro/TS-conformance fixtures) incl. adversarial; loader wiring for .ts/.mts/.cts
- **Gate:** corpus green; strip→run throwing line:col identical to source; each catalog error fires w/ documented message.

### Phase 10 — RegExp  (deps: 04) ~3k LOC
- [ ] JS regex parser → own AST; AST → CL-PPCRE parse trees (group numbering, named-group map, i/m/s; u via down-translation)
- [ ] RegExp object (lastIndex, exec/test, indices)
- [ ] String match/matchAll/replace/replaceAll/split/search with $1/$<name> templates
- [ ] loud SyntaxError for documented gaps; UCD table generator for later \p{}
- **Gate:** built-ins/RegExp/** ≥ 60% (gaps enumerated); String regex methods ≥ 75%; zero regressions.

### Phase 11 — Binary data + BigInt  (deps: 04) ~3k LOC
- [ ] ArrayBuffer (ub8), DataView + all TypedArray kinds (ldb/dpb; make-double-float fast path), detach
- [ ] TextEncoder/TextDecoder (UTF-8)
- [ ] BigInt (literals, ops, ToBigInt, mixing TypeErrors, toString radix, BigInt64Array)
- **Gate:** TypedArray/DataView/BigInt curated slices ≥ 65%; overall curated ≥ 80%.

### Phase 12 — Node-compat wave 1 (sync)  (deps: 08; 10 for assert.match) ~4k LOC ⚡⚡ (flagship fan-out)
- [ ] node:path (posix; win32 throwing), node:os, node:querystring (null-proto parse)
- [ ] node:util (format/inspect→shared/promisify+custom/callbackify/inherits/deprecate/isDeepStrictEqual/types/stripVTControl)
- [ ] node:events (full sync EventEmitter: snapshot iter, once-wrapper removal, newListener, error-throw, errorMonitor)
- [ ] node:assert (strict family, throws/match, AssertionError w/ shared inspector)
- [ ] Clun.inspect/deepEquals/which/nanoseconds/fileURLToPath/pathToFileURL; structuredClone (JSON-grade)
- [ ] crypto.randomUUID/getRandomValues (ironclad os-prng — vendor ironclad here w/ KATs)
- **Gate:** per-module conformance (values asserted exactly); kitchen-sink fixture runs identically under node where shared.

### Phase 13 — Files: fs substrate + node:fs + Buffer surface  (deps: 11, 12; loop 05 for async) ~4.5k LOC
- [ ] src/sys fs layer (path discipline, errno→.code/.errno/.syscall/.path, worker-pool async)
- [ ] node:buffer (Buffer extends Uint8Array; alloc/from/concat/compare/copy/fill/indexOf/subarray/toString+write; numeric read/write)
- [ ] node:fs sync core (23 fns), fs/promises (14), callback shims; Stats/Dirent/constants
- [ ] Clun.file/Clun.write (lazy file, createPath default); mkdtemp/tmp helpers
- **Gate:** ~60-case fs conformance incl. bracket paths, symlink chains, ENOENT; Buffer KAT vectors; Clun.file lazy fixtures.

### Phase 14 — Async product wave  (deps: 06, 12, 13) ~1.5k LOC
- [ ] timers globals + Timer ref/unref real loop accounting + node:timers + timers/promises
- [ ] process.nextTick dedicated queue wiring; events.once + captureRejections; assert.rejects/doesNotReject
- [ ] Clun.sleep/sleepSync; queueMicrotask; AbortController/AbortSignal
- **Gate:** extended ordering corpus (nextTick vs microtask vs timer vs immediate) exact-output; unref'd-timer exit test; abort fixtures.

### Phase 15 — Test runner  (deps: 14; 10 for -t) ~4k LOC
- [ ] discovery (*.test.*/*_test.*/*.spec.*/*_spec.*; positional substring filters)
- [ ] collection + hook scheduler (exact ordering + failure semantics); modifiers incl. only-bubbling + CI-guard
- [ ] matchers (~22) on shared deepEquals/inspector; .resolves/.rejects (Jest-async); timeout machinery
- [ ] reporter + diffs + summary + exit codes; --bail, --todo
- [ ] self-hosting migration: move tests/js expect-style suites onto clun test; meta-tests via built binary
- **Gate:** meta-test matrix (pass/fail/skip/todo/only/bail/zero-tests→1); hook-order fixture byte-exact; self-hosted suites green.

### Phase 16 — Sockets  (deps: 05) ◇ ~1.8k LOC
- [ ] non-blocking connect (EINPROGRESS)/accept/read/write w/ EAGAIN→NIL; write queues + backpressure
- [ ] IPv6; port-0 real-port; error mapping (ECONNREFUSED…); BROKEN-PIPE handling
- **Gate:** echo server 2,000 sequential + 500 concurrent; /proc/self/fd stable (zero leaks); ≥100 MB/s loopback.

### Phase 17 — HTTP server + Clun.serve  (deps: 14, 16) ~3.5k LOC
- [ ] own incremental HTTP/1.1 parser (adversarial lengths); Request/Response/Headers (shared with fetch)
- [ ] Clun.serve({port,hostname,fetch,error}) → Server{stop,url,port}; keep-alive, chunked both ways, 431/413, HEAD, date
- [ ] Clun.file responses via chunked worker-pool reads; 503 shedding
- **Gate:** curl interop; malformed-request suite; ≥30k req/s w/ real parsing + JS handler; graceful shutdown; 1k-req RSS plateau; serve.ts smoke logged.

### Phase 18 — HTTP client, fetch, URL  (deps: 14, 16; 11 for bodies) ~3.5k LOC
- [ ] WHATWG URL/URLSearchParams minus IDNA (loud error non-ASCII; IPv4/IPv6 host; relative resolution; percent-encode sets) + node:url
- [ ] reactor HTTP client (pool, timeout matrix, redirects, chunked decode, gzip via chipz — vendor+pin here)
- [ ] fetch API (Request/Response/Headers, text/json/arrayBuffer/bytes buffered, AbortSignal, network errors → TypeError)
- **Gate:** fetch vs Phase-17 server (JSON round-trip, redirects, 4xx/5xx, gzip, abort→AbortError, timeouts); URL corpus (WPT subset).

### Phase 19 — Crypto foundation: ironclad KATs + pure-tls vendoring  (deps: 00; ironclad landed in 12) ◇ ~1k LOC glue
- [ ] KAT suites (SHA-2/HMAC FIPS, HKDF RFC 5869, AES-GCM NIST, x25519 RFC 7748, ChaCha20-Poly1305 RFC 8439)
- [ ] vendor pure-tls + Linux dep closure (Appendix B) pinned; cl-cancel purity patch (precise-time → sb-unix:clock-gettime)
- [ ] strip windows/macos verify files; run pure-tls crypto/record/handshake/cert suites in CI; extend make purity; file upstream patch issue
- **Gate:** all KATs pass; pure-tls suites pass; make purity green over full closure.

### Phase 20 — HTTPS  (deps: 18, 19) ~1.5k LOC
- [ ] TLS streams via worker pool (blocking gray-stream handshake/IO off JS thread)
- [ ] trust store (system PEM, SSL_CERT_FILE/DIR overrides); hostname verification; pool keys gain TLS config
- [ ] test CA + in-process pure-tls server fixtures; negative matrix; posture labeling (§3.4) in README + errors
- **Gate:** hermetic HTTPS round-trip vs in-process server w/ test CA; negative tests fail closed w/ distinct errors; one live smoke logged.

### Phase 21 — Semver + registry client + local registry fixture  (deps: 00 semver; 18 client) ◇(semver) ~2.5k LOC ⚡(fixtures)
- [ ] semver port (versions, prerelease precedence, ranges ^ ~ - || * x, includePrerelease) + node-semver fixture corpus at 100%
- [ ] registry client (abbreviated-metadata Accept, scoped %2F, retries, --registry, .npmrc-lite)
- [ ] local registry fixture (in-process server + hand-built .tgz for ~8 pkgs w/ conflict/scoped/bin/pax-longname); dist.integrity real; gzip + ETag/304
- **Gate:** semver corpus 100%; metadata round-trips incl. scoped/gzip/304; fixture server reusable as a make target.

### Phase 22 — Tarball + integrity  (deps: 13; 21 fixtures) ◇ ~700 LOC
- [ ] streaming chipz-inflate → hand-rolled ustar/pax reader (pax path/linkpath/size, gnu L longname, package/ strip, mode bits)
- [ ] SRI sha512 verify-then-commit (temp dir + rename); content-addressed cache
- **Gate:** real-package corpus extracts; mandated traversal suite (abs names, .. variants, symlink/hardlink escape, NUL/., device/FIFO reject, setuid strip, size overflow, dup last-wins) all handled per spec.

### Phase 23 — Install: resolver, linker, lockfile, CLI  (deps: 20, 21, 22) ~4k LOC
- [ ] breadth-first resolution (highest-satisfying, cycle-safe), hoisted layout + nested conflict dirs, os/cpu optional-dep filtering
- [ ] bin symlinks + chmod into node_modules/.bin; clun.lock (versioned JSON, deterministic); --frozen-lockfile drift error
- [ ] add/remove edit package.json (-d/-D, -E/--exact) + reinstall; --dry-run/--production/--no-save; lifecycle scripts skipped+logged
- **Gate:** fixture-graph e2e (install → clun run → exact output); reinstall from lock offline → byte-identical lock; frozen drift errors; live `clun add ms` logged.

### Phase 24 — Spawn + package scripts  (deps: 14; 23 e2e) ~2k LOC
- [ ] Clun.spawn (run-program wrapper: cmd/cwd/env, pipe|inherit|ignore, non-blocking into reactor, .exited promise, exitCode/signalCode, kill, onExit) + spawnSync
- [ ] clun run <script> (sh -c, ancestor .bin PATH walk, pre/post, npm_* env, --if-present, arg passthrough); dispatcher merge
- **Gate:** spawn matrix; 10 MB dual-pipe child drained w/o deadlock; 1,000 spawns → zero zombies; scripts fixture; examples/e2e.sh green + hermetic.

### Phase 25 — Performance pass  (deps: all engine phases) ~3k LOC
- [ ] shapes (scls/hcls-style tree + dict fallback) behind storage protocol; inline caches at property sites; direct call paths
- [ ] string-builder for += loops; optional COMPILE tiering (background thread) — measure first
- [ ] benchmark suite (Richards/DeltaBlue/splay) + docs/benchmarks.md (honest methodology)
- **Gate:** pass-list unchanged or grown; ≥5× on benchmark suite vs Phase-24 baseline; overall curated test262 ≥ 90%.

### Phase 26 — Hardening, docs, release  (deps: everything)
- [ ] error-message audit (named resource, violated constraint + rejected value, note: remedy; no Lisp backtraces w/o --backtrace)
- [ ] stress pass (50k-eval loop, long-run serve, biggest fixture tree ×20 — RSS plateaus)
- [ ] Ctrl-C mid-serve/mid-install clean exit; partial installs don't corrupt; TZif local-time task (or defer w/ matrix note)
- [ ] README (what/why, install-from-source, quickstart, architecture, compat matrix, TLS posture, contributing); CI release job
- [ ] final adversarial review sweep; triage → fix safety/error-path findings, log style findings
- **Gate:** §1.4 Definition of Done, every item checked w/ evidence links here; tag v0.1.0.
