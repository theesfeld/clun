# STATE

Living checklist and the only session-to-session memory besides PLAN.md/DECISIONS.md.
Update before every commit. Seeded from PLAN.md §5.

---

## Current phase: **04 — Stdlib core**  (Phase 03 committed; execution gate MET at 72.8%)

**Phase 03 outcome:** the engine EXECUTES JavaScript. Object kernel (descriptors, ptable storage,
CLOS-generic internal methods, Array exotic), runtime environments, operators, callables, realm +
~60 built-ins, the closure emitter, and the evaluator are all built and green. Measured **72.8% pass
(5,460/7,500)** on the curated language slice (minus generators/async/modules) in BOTH strict+sloppy
— **gate ≥70% MET** — with only 3 crashes (all fixed → 0). 570 CL unit tests pass. The conformance
runner has an EXECUTION phase (`make conformance-exec`, CLUN_EXEC=1) with a checked-in monotonic
exec-passlist alongside the parse-passlist.

**Next action:** Begin Phase 04 (Stdlib core, ~9k LOC, deps 03 ✓). Write `docs/design/phase-04.md`.
Broaden the built-ins to raise conformance: Object/Array/String/Number full methods, **Math**, **JSON
(own parser/printer + Ryū port for Number→String)**, Error hierarchy completeness, Symbol +
well-knowns, Map/Set/WeakMap/WeakSet (SBCL weak tables), iterator protocol, Date (UTC core). Gate:
built-ins slices ≥ 65%, overall curated ≥ 55%, Ryū vectors pass. NOTE Phase 03 deferred (candidates
to revisit): `with`/tagged-templates (loud errors now), full class super/derived semantics, mapped
sloppy `arguments`, global-scope TDZ, direct eval; generators/async are Phase 06; RegExp is Phase 10.

**Independent phases available if the main track blocks (◇):** 05 (event loop, deps 01),
19 (crypto foundation, deps 00), 21-semver (deps 00).

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

### Phase 04 — Stdlib core  (deps: 03) ~9k LOC ⚡ — **CURRENT**
- [ ] Object, Function, Array (ES2017), String (code-unit exact), Number, Boolean, Math
- [ ] JSON (own parser/printer + Ryū port for Number→String; known-answer vectors)
- [ ] Error hierarchy; Symbol + well-knowns; Map/Set/WeakMap/WeakSet (SBCL weak tables); iterator protocol
- [ ] Date (UTC core; TZif deferred); global wiring; eval/Function (parser in-image)
- **Gate:** built-ins slices for these globals ≥ 65%; overall curated ≥ 55%; Ryū vectors pass.

### Phase 05 — Event loop core  (deps: 01; independent of 02–04) ◇ ~2.3k LOC
- [ ] serve-event wrapper + startup capability probe (poll, fd>1023); self-pipe; mailbox integration
- [ ] binary-heap timers; handle refcounting + ref/unref
- [ ] signal delivery (enqueue-only); worker pool; graceful stop
- **Gate:** timer-ordering tests; cross-thread wake < 5 ms; process alive iff refs>0; SIGINT → loop
  event; microtask-drain points honored (stub queue).

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
