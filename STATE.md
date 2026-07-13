# STATE

Living checklist and the only session-to-session memory besides PLAN.md/DECISIONS.md.
Update before every commit. Seeded from PLAN.md §5.

---

## Current phase: **13 — Files: fs substrate + node:fs + Buffer**  (Phase 12 committed; node-compat wave 1 gate MET)

**Phase 12 outcome:** the engine-light node stdlib floor. Node builtins resolve via an engine hook
`*builtin-module-builder*` (NIL in bare test262 realms → inert there) that the runtime installs; a
`node:`/bare builtin name is intercepted in `require`/`import` before the resolver and returns a per-realm
cached `:cjs` record with a freshly-built exports object. Modules (`src/runtime/node/`, one self-registering
file each): **path** (posix; win32 throws), **os** (over new `clun.sys` /proc + CL primitives), **querystring**
(legacy; null-proto parse), **util** (format/inspect→shared/isDeepStrictEqual/promisify/callbackify/inherits/
deprecate/stripVTControlCharacters/types), **events** (full sync EventEmitter), **assert** (strict family +
loose equal + throws-with-class + AssertionError). Globals: **structuredClone** (deep clone incl Date + cycles;
DataCloneError), **crypto.randomUUID/getRandomValues** (pure `/dev/urandom`; full ironclad → Phase 19),
**Clun.which/nanoseconds/fileURLToPath/pathToFileURL/sleep**; one shared `eng:js-deep-equal` behind
util/assert/Clun deepEquals. **Gate MET:** per-module conformance fixtures (tests/js/node/*) green;
`make build`/`test`(**parachute + 42 TS + 53 JS**)/`purity`(**159 files**) green; conformance parse 17,512 /
exec **22,638** (0 crashes, 0 regressions — engine behaviorally untouched). Adversarial review panel (5 dims ×
find→verify-by-running-the-binary, 31 agents): **25/26 confirmed + fixed** — querystring null-proto +
prototype-collision, util BigInt/Symbol/NaN format + inspect depth:Infinity/null crash + %j circular, events
once-removal-by-identity + emit('error') no-arg + prependListener newListener, assert loose-equal +
throws-class-validation + AssertionError, structuredClone Date/DataCloneError, path extname/format, and a
class of outside-the-float-mask NaN checks (`js-nan-p`, never `=`). The 5 non-reference modules were authored
by a parallel write-only subagent fan-out and integrated in one build.

**Next action:** Begin Phase 13 (Files: fs substrate + node:fs + Buffer, deps 11 ✓, 12 ✓; loop 05 ✓ for async):
`src/sys` fs layer (path discipline, errno→.code/.errno/.syscall/.path, worker-pool async); node:buffer
(Buffer extends Uint8Array; alloc/from/concat/compare/copy/fill/indexOf/subarray/toString+write with utf8/
ascii/latin1/hex/base64/base64url/utf16le; numeric read/write); node:fs sync core (23 fns) + fs/promises (14) +
callback shims; Stats/Dirent/constants; Clun.file/Clun.write. Gate: ~60-case fs conformance incl bracket paths,
symlink chains, ENOENT; Buffer KAT vectors; Clun.file lazy fixtures.

---

## Recent phase outcomes (most recent first)

**Phase 11 outcome:** BigInt + binary data. **BigInt is a plain CL integer** (`js-bigint-p` =
`integerp` — no engine value is ever a raw integer otherwise, so it's an unambiguous value-domain
slot; faithful + cheaper than a wrapper). The front-end was already done (lexer/parser/emitter flow
`123n` through as a CL integer), so the work threaded BigInt through values/typeof/dispatch,
coercions (ToNumeric/ToBigInt; ToNumber→TypeError = the honesty linchpin), all operators (==/=== ,
`1n==1`→true mathematical eq; relational exact bigint↔double; a `numeric-binary` doing full
ToNumeric(l) then ToNumeric(r); bitwise incl. `>>>`→TypeError; `+bigint`→TypeError), inspector
(`123n`), and `BigInt()`/toString(radix)/asIntN/asUintN (`builtins-bigint.lisp`). **Binary data**
(`builtins-binary.lisp`): `js-array-buffer` (ub8 vector, detach = bytes→NIL), ONE `js-typed-array`
struct with a `kind` slot (11 kinds incl. Uint8Clamped + Big{Int,Uint}64) as an integer-indexed
exotic (overrides the `jm-*` generics; CanonicalNumericIndexString element get/set; OOB read→
undefined/write→no-op; ascending OwnPropertyKeys), `js-data-view`; byte assembly is pure SBCL
(`ldb`/`dpb` + `sb-kernel` float-bit primitives), LE for TypedArrays, DataView chooses endianness;
alloc capped at half the runtime heap → catchable RangeError. TextEncoder/Decoder reuse the WTF-8
codec with a USV-string step (lone surrogates→U+FFFD) + BOM strip. **Gate MET:** BigInt **96.1%**
(73/76), TypedArray **67.8%** (835/1231), DataView **70.5%** (346/491) each ≥65%; overall curated
**80.4%** (22,638/28,163) ≥80%; 0 crashes. `make build`/`test`(**1110 parachute + 42 TS + 49 JS**)/
`purity`(**151 files**) green; conformance parse 17,512 / exec **22,638** (0 crashes, 0 regressions).
Adversarial review panel (5 dims × find→verify-by-running-the-binary, 19 agents): **14/14 confirmed
+ fixed** — mostly crash-safety (raw Lisp backtraces reaching the user: signaling-NaN Float32 read,
ArrayBuffer/TypedArray huge-alloc heap-exhaustion, DataView/fill/set detaching-`valueOf`, BigInt
`**`/`<<` DoS) + silent wrong-answers (JSON.stringify BigInt, descending TypedArray keys, unstable/
NaN-misplacing sort, overlapping `.set`, lone-surrogate/BOM codecs); also fixed 7 order-of-eval
regressions from the `numeric-binary` refactor + a `js-unary-plus` double-`valueOf`. Gaps in
tests/conformance/bigint-binary-gaps.txt: resizable/growable buffers, SAB/Atomics, @@species subclass
returns, ES2023 change-by-copy TA methods, TextDecoder streaming/fatal/non-UTF-8 labels, encodeInto,
the 2^27-bit BigInt DoS cap, Number(bigint)=deliberate TypeError.

**Next action:** Begin Phase 12 (Node-compat wave 1, deps 08 ✓; 10 for assert.match ✓): the flagship
fan-out phase — one subagent per module (node:path/os/querystring/util/events/assert), each ships
module + conformance tests; + Clun.inspect/deepEquals/which/nanoseconds/fileURLToPath/pathToFileURL,
structuredClone, crypto.randomUUID/getRandomValues (vendor ironclad with KATs). Gate: per-module
conformance; kitchen-sink fixture runs identically under node where shared.

**Phase 10 outcome:** RegExp is a from-scratch JS-regex parser → own AST → CL-PPCRE **parse trees**
→ `create-scanner` (`src/engine/regex/` ast/parser/translate/regexp-object, ~1.1k LOC). Translating
to trees (not pattern strings) lets us undo JS-vs-PCRE semantics EXPLICITLY: `.` excludes LF/CR/LS/PS
(all four, `:everything` under /s); `\s`/`\S` = the ~25-codepoint JS WhiteSpace set; `\w`/`\W` = ASCII
only (negated forms INSIDE a class emitted as explicit complement ranges); `^`/`$` under /m built over
the full LineTerminator set (PPCRE multi-line-mode breaks on LF only); `\b`/`\B` = ASCII-word lookarounds;
Annex-B legacy octal (`\40`/`\101`/`\8`/`\9`, in & out of classes); empty `[]`/`[^]`. Exec uses
`pp:scan … :start li :real-start-pos 0` so g/y iteration anchors ^/\b absolutely. RegExp object:
lastIndex, exec/test, flag validation (dgimsuy, no dups, /v → SyntaxError), `.source` EscapeRegExpPattern,
IdentifierName group names + duplicate rejection, the RegExp() ctor (copy/override/IsRegExp short-circuit).
String match/matchAll/replace/replaceAll/search/split delegate to the @@ method ONLY when the arg is an
Object (primitive → string fallback), with `$$`/`$&`/$n/`$<name>` templates + fn replacer (named-groups
arg); Symbol.{match,matchAll,replace,search,split,species} statics exposed. **Gate MET:**
built-ins/RegExp/** **76.1%** (696/915) ≥60%; String regex methods **96.9%** (283/292) ≥75%; zero crashes.
`make build`/`test`(**1054 parachute + 42 TS + 49 JS**)/`purity`(**148 files**) green; conformance parse
17,512 / exec **20,631** (0 crashes, 0 regressions). Adversarial review panel (5 dims × find→verify-by-
running-the-binary, 28 agents): **21/23 confirmed + fixed** — all silent-mismatch classes (legacy octal,
empty class, /m terminators, ASCII \b, non-ASCII \S/\W in class, flag validation, scan-start anchors, fn
replacer groups arg, .source escaping, group-name validation, \c, missing Symbol statics + hyphenated
descriptions, RegExp(re) identity), which also unmasked + fixed a latent primitive-@@-getter bug (+102
RegExp tests, 64.9%→76.1%). Deliberate gaps (tests/conformance/regexp-gaps.txt): \p{} (loud; UCD gen
scaffolded), /v, inline modifiers, /d indices, the fully-generic @@ protocol (fast-path exec, not
user-overridable RegExpExec + @@species — 3 former false-passes removed from the pass-list, DECISIONS
2026-07-12), RegExp.escape, variable-length lookbehind (loud), Annex-B-under-/u, astral /u (BMP-only),
2 CL-PPCRE-vs-ECMAScript NFA edges.

**Next action:** Begin Phase 11 (Binary data + BigInt, deps 04 ✓): ArrayBuffer (ub8) + DataView + all
TypedArray kinds (ldb/dpb, make-double-float fast path, detach); TextEncoder/TextDecoder (UTF-8); BigInt
(literals, ops, ToBigInt, mixing TypeErrors, toString radix, BigInt64Array). Gate: TypedArray/DataView/
BigInt curated slices ≥65%; overall curated ≥80%. RegExp deferrals to revisit later: the generic @@
RegExpExec protocol + @@species, RegExp.escape, /d indices, \p{} (needs the UCD generator), /v flag.

**Phase 09 outcome:** `.ts/.mts/.cts` run by type-stripping. A **recursive-descent strip scanner**
(`clun.transpiler`, `src/transpiler/`) over the shared engine token stream erases type syntax to
EXACT-LENGTH whitespace (newlines kept → line+col preserved, no sourcemaps) and hard-errors on
non-erasable constructs (`unsupported-ts-syntax` → JS SyntaxError w/ line:col). It drives the lexer's
regex-vs-divide + template `${}` context exactly (via `reread-regexp`/`reread-template`), uses a
balanced `skip-type` (counts `()[]{}<>`, `>>` split, `=>`-after-`)` function types), and errors loudly
rather than mis-strip. Erases: annotations (var/param/return/field/for/catch), generics (decl/call/
arrow), `as`/`satisfies`, non-null `!`, interface/type/declare/type-only-namespace, import type/export
type + inline `{type X}`, implements, modifiers, overload signatures. Errors: enum/decorator/param-
property/`import=`/`export=`/runtime-namespace/`.tsx`/angle-cast. **The `<` ambiguity**: type-args only
when the matched `>` is followed by `(`/tag with type-list content (so `a < b` never stripped; arrow
generics handled); `a<b>(c)` comparison-call is the documented accepted corner. Loader: engine
`*ts-strip-hook*` (transpiler installs it), `read-source-for` strips before parse; resolver
`.mts`→ESM/`.cts`→CJS. **Gate MET:** 78-pair corpus green (33 byte-exact strip + same-length, 9 catalog
errors w/ line:col, 36 strip→run incl line-preservation); `make build`/`test`(**1004 parachute + 42 TS
+ 49 JS**)/`purity`(**143 files**) green; conformance parse 17,512 / exec 19,540, 0 crashes, 0
regressions. Review panel (6 dims × find→verify-by-running-the-stripper, 24 agents): **18/18 confirmed +
fixed** — contextual keywords as value idents (declare()/interface()/namespace()/abstract/static()),
arrow return types ending in `)`, arrow generics w/ default, tag templates + `as`-in-`${}`, `x!!`/`x! as`,
superclass type args, angle-cast→error, declare-namespace-ambient.
**Documented limits (not strip bugs):** class FIELD syntax unsupported by the ES2017 parser (annotation
strips fine); `class extends` method resolution a pre-existing engine gap; `??`/`?.` post-ES2017.

**Next action:** Begin Phase 10 (RegExp, deps 04 ✓): JS regex parser → own AST → CL-PPCRE parse trees
(group numbering, named-group map, i/m/s flags, `u` down-translation over code-unit strings); RegExp
object (lastIndex/exec/test/indices); String match/matchAll/replace/replaceAll/split/search with
`$1`/`$<name>`; loud SyntaxError for documented gaps; UCD generator for later `\p{…}`. Gate:
`built-ins/RegExp/**` ≥60% (gaps enumerated), String regex methods ≥75%, zero regressions.



**Phase 08 outcome:** `clun` is a real CLI. A `clun.runtime:install-runtime` hook augments a fresh
(runtime-free) realm with `console`, a full `process`, and a `Clun` stub; the CLI (`clun.cli` +
`main.lisp`) parses flags, autoloads `.env`, runs the entry, and renders uncaught errors. **The ONE
shared inspector** lives in `clun.engine` (`inspect-value`), Bun-flavored (verified vs Bun's
`console-log.expected.txt`): double-quoted strings, multiline objects + trailing comma, inline arrays,
`[Object ...]` past depth 2, `[Circular]`, `[Function: name]`, `Name {}` instances, `[Number: 5]`
wrappers, `Promise { … }`, `Map(n){ k: v }`. **console** log/info/debug→stdout, warn/error/trace→stderr,
`util.format` specifiers (`%s %d %i %f %j %o %O %c %%`). **process** argv/env(snapshot)/exit/exitCode/
platform/arch/pid/cwd/chdir/versions(node 22.11.0)/stdout.write/isTTY/hrtime(µs)/memoryUsage/on('exit').
**CLI** positional-stop flags (`-e`/`-p` as script, `-p` awaits a settled promise; `--cwd`/`--silent`/
`--revision`/`--backtrace`); extension routing → `run-module-file`; uncaught JS → `Name: message` +
stack on stderr, exit 1; stack overflow → `RangeError`; no Lisp backtrace without `--backtrace`; exit
0/1/2. **JS-fixture harness** `scripts/run-js-fixtures.lisp` + `tests/js/` wired into `make test`.
**Gate MET:** run/eval fixture matrix (13 JS fixtures: console/format/streams/process/exit/onexit/eval/
errors/env) green; console subset matches Bun; `make build`/`test`(**976 parachute + 13 JS**)/`purity`
(**138 files**) green; **conformance parse 17,512 / exec 19,540, 0 crashes, 0 regressions.** Review panel
(6 dims × find→verify-by-running, 23 agents): **17/17 confirmed + fixed** — several raw Lisp backtraces
(float-trap crashes in `%d`/`process.exit`/`hrtime` on NaN/Inf) that violated the no-backtrace contract,
plus getter/setter labels, class-instance names, `-p` string raw, `on('exit')` on throw, chdir errors,
`.env` `#`/`$VAR`. **Deferred 🟡:** `[class X]` display, SetIterator/MapIterator, exact 80-col array
wrapping, `hrtime.bigint` real BigInt (Phase 11), `.ts` execution (Phase 09).

**Next action:** Begin Phase 09 (TypeScript stripping, deps 08 ✓): erasable-syntax strip pass sharing
the engine lexer (§3.3); error catalog (enum/namespace/param-props/decorators/`import =`); `.tsx`
rejection; ≥60-pair corpus incl. adversarial (`<` ambiguity, generics-in-arrows, multiline annotations);
loader wiring for `.ts/.mts/.cts` (route through the Phase-08 CLI's TS branch). Gate: corpus green +
strip→run stack-trace line:col identical to source + each catalog error fires.

**Phase 07 outcome:** real multi-file projects run from `node_modules`. Three engine-free layers:
`src/sys/` (`clun.sys`: path discipline via `parse-native-namestring`, sb-posix+`truename` fs
primitives, a hand-rolled JSON reader) → `src/resolver/` (`clun.resolver`: the full Node CJS+ESM
algorithm — relative/absolute/bare, extension probing, dir index, `main`/`type`/`exports`/`imports`
with conditions + subpath patterns + `null` blocks, self-refs, scoped `@scope/pkg`, node_modules
walk, symlink realpath; **no engine dep**) → `src/engine/modules/` (records + a frame-based ESM
compile + CJS `require` + loader). **Module env = a frame** (Option A): compiled like a function
body, imports are getter-thunk slots MARKED on the cscope (shadow-safe deref via `compile-
identifier`); `import.meta` a reserved slot. **Load→evaluate = one post-order pass**: ESM→ESM imports
are live thunks into the exporter's frame slot (true live bindings, acyclic); ESM→CJS reads
`module.exports`. **CJS** runs sloppy in the Node `(function(exports,require,module,__filename,
__dirname){…})` wrapper (`this`===`module.exports`); realm-registry cache; cycle→partial; throw→evict.
**Interop:** import-of-CJS default=`module.exports`/named=enumerable keys 🟡; `require()` of ESM
throws; JSON module default=parsed value. **Gate MET:** resolution corpus green (101 assertions,
40+ scenarios); the fixture app (ESM entry → CJS dep + scoped ESM pkg via exports maps + JSON +
import.meta) runs; `make build`/`test`(887)/`purity`(128) green; **conformance parse 17,512
(+9), exec 19,540 held, 0 crashes, 0 regressions.** Review panel (6 dims × find→verify-by-running,
24 agents): 17/18 findings confirmed + fixed (exports pattern precedence, bare-in-exports reject,
`..`-escape block, JSON overflow→Infinity/strict-grammar/dup-key-last, CJS this+throw-evict, JSON
`{default as X}`, ESM early errors, named/anon default-export). **Deferred 🟡 (not gate-blocking):**
ESM cyclic live-binding-through-reassignment; TLA; namespace-object is a snapshot; test262
`module`-flagged exec tests stay skipped (follow-up: route via `run-module-file`).

**Next action:** Begin Phase 08 (CLI shell, console, process, deps 07 ✓): dispatcher + exact flags
(`-e`/`-p` as `[eval]` module — `run-module-source` exists, positional-stop, `--cwd`/`--silent`/
`--revision`/`--backtrace`); `.env` autoload; the shared inspector + full console; process core
(argv/env/exit/cwd/platform/versions/stdout.write/hrtime/…); uncaught-error rendering.

**Phase 06 outcome:** the async engine is live via **thread-per-coroutine** (the §3.1 fallback, taken
deliberately over state-machine lowering — see DECISIONS 2026-07-11 + docs/design/phase-06.md).
`src/engine/async/` (coroutine/generator/promise/async-function, ~900 LOC): generators (next/return/
throw, yield*, try/finally×yield×return via the real CL stack — for free), Promises (capability +
Symbol.species subclass model, thenable adoption, then/catch/finally, all/allSettled/race/any,
IfAbruptRejectPromise, unhandled-rejection→exit), async/await, for-await-of (sync + async iterables),
async generators. `run-source`/`eval-source` host a per-realm event loop (`:workers 0`), run top-level,
drive to idle, report unhandled rejections; runaway/abandoned coroutines are force-finished/terminated
at teardown (0 thread leak verified). **Gate MET (each dir ≥75%):** Promise 76.1%, async-fn 78.1%,
for-await 78.7%, generators ~78.5%; ordering corpus (nextTick<microtask<timer) passes; **0 crashes, 0
regressions** across the 34,779-file exec phase (pass 19,449, +3,118). 719 CL unit tests; purity clean
(115 files). Key conformance fixes: runner auto-includes doneprintHandle.js for `async` tests;
combinators reject-on-abrupt + AlreadyCalled guard. **DEFERRED to Phase 07:** ESM linking + TLA (Phase
07 owns module resolution); the gate does not require them. Phase 03 deferral `class extends` super
caps the Promise-subclass tests (revisit later).

**Next action:** Begin Phase 07 (Module resolution & CJS): `src/resolver/` pure-CL Node resolution +
~40-tree fixture corpus, loader hooks, CJS `require`, ESM↔CJS interop, JSON modules, import.meta. This
subsumes the deferred Phase 06 ESM linking. Deps 06 ✓.

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

- **Phase 06 — ASYNC GATE MET + committed (2026-07-11).**
  - `make build` clean; `make test` **739 assertions** (generators/promises/async/for-await + ordering
    + subclass-builtins + panel regressions); `make purity` clean (115 files); `make conformance-exec`
    over 34,779 files: **pass 19,540** (+4,209 over Phase 05), **0 crashes**, exec-passlist regenerated
    (19,540, monotonic), **0 regressions**.
  - **Gate (each dir ≥75%):** Promise **76.1%** (542/712), async-function **78.1%**, for-await
    **78.7%**, generators **~78.5%**; ordering corpus (nextTick<microtask<timer) ✔.
  - Thread-per-coroutine engine (`src/engine/async/`): generators, Promises (capability/species),
    async/await, for-await, async generators. `run-source`/`eval-source` host + drive a per-realm loop;
    teardown terminates runaway/abandoned coroutines (0 thread leak). Vendored built-ins/Promise +
    Generator/Async prototypes (1,024 files) from the pinned d1d583d clone.
  - Fixes that unblocked the gate: runner auto-includes doneprintHandle.js for `async` tests; Promise
    combinators reject-on-abrupt (IfAbruptRejectPromise) + per-element AlreadyCalled guard.
  - DEFERRED: ESM linking + TLA → Phase 07 (owns module resolution); `class extends` super (Phase 03
    deferral) caps Promise-subclass tests.
  - Adversarial review panel (4 dims × verify-by-running-JS): **11 confirmed / 0 refuted**; 7 fixed +
    locked as regressions (Object.prototype.toString reads @@toStringTag; Promise.finally awaits
    onFinally's result + propagates its rejection; AggregateError global; for-await Awaits sync values
    (async-from-sync); `class extends Promise` derived default ctor binds `this` to super()'s result —
    real subclass Promises; setTimeout returns an opaque coercible id + clamps huge/∞ delays). 4
    DEFERRED (async-iteration edge cases, not a gate dir): async-generator request queue for concurrent
    next(); AsyncGenerator.return awaiting its arg; async `yield*`; + the `class extends` EXPLICIT-super
    ceiling (Phase 03 deferral). The `class extends Promise` fix generalized to **new-target-honoring in
    all builtin constructors** (Array/Boolean/Number/String/Error/Object/Function/bound-fn — subclassing
    a builtin now preserves both identities), and finally was made spec-faithful (single-arg internal
    `.then`, length-1 wrappers). Post-fix: 739 unit tests, **0 regressions, 0 crashes**.

- **Phase 07 — MODULE GATE MET + committed (2026-07-11).**
  - `make build` clean; `make test` **887 assertions** (sys/paths/fs/json + resolver corpus + module
    system + review regressions); `make purity` clean (**128 files**); `make conformance` parse
    **17,512** (+9: import.meta + anon-default-fn, pass-list regenerated, monotonic);
    `make conformance-exec` **pass 19,540 held, 0 crashes, 0 regressions**.
  - **Gate:** resolution corpus green (101 assertions / 40+ scenarios, engine-free); the fixture app
    (ESM entry → CJS dep + scoped ESM pkg via `exports` conditions + JSON module + `import.meta.main`)
    runs and produces `hi world|9|42|true`.
  - Three engine-free layers: `src/sys/` (`clun.sys`, ~430 LOC: path discipline, sb-posix/truename fs,
    hand-rolled JSON) → `src/resolver/` (`clun.resolver`, ~430 LOC: full Node CJS+ESM algorithm) →
    `src/engine/modules/` (~620 LOC: records, frame-based ESM compile, CJS require, loader). Emitter/
    parser/analyzer/eval extended for module scopes, import deref+const, `import.meta`, four
    import/export `compile-node` clauses, ESM early errors.
  - Adversarial review panel (6 dims × find→**verify-by-running-code**, 24 agents): **17 confirmed /
    1 self-refuted**, all 17 fixed + locked as regressions — resolver exports pattern precedence
    (Node PATTERN_KEY_COMPARE), bare-in-exports rejection, `..`-escape block; JSON overflow→Infinity,
    strict grammar, dup-key-last; CJS `this`=`module.exports` + throw→evict; JSON `{default as X}` +
    named-import error; ESM early errors (dup export/default, undeclared export, dup import) throw
    clean SyntaxErrors; named + anonymous `export default` function/class.
  - DEFERRED 🟡 (not gate-blocking): ESM cyclic live-binding-through-reassignment (acyclic is live);
    top-level await; namespace-object snapshot; test262 `module`-flagged exec tests stay skipped
    (follow-up: route through `run-module-file`).

- **Phase 08 — CLI GATE MET + committed (2026-07-12).**
  - `make build` clean; `make test` = **976 parachute + 13 tests/js** (0 failed); `make purity` clean
    (**138 files**); `make conformance` parse **17,512** (0 crashes, held); `make conformance-exec`
    **19,540** (0 crashes, 0 regressions).
  - **Gate:** run/eval fixture matrix (console/format/streams/process/exit/onexit/eval/pstring/errors/
    onexit-throw/env, 13 cases) green; console subset matches Bun's `console-log.expected.txt`; `-p`
    awaits a settled promise; uncaught JS → stack on stderr + exit 1; exit codes 0/1/2.
  - Runtime layer `src/runtime/` (install/console/process/clun-global) + shared inspector
    `src/engine/inspect.lisp` (in clun.engine) + CLI `src/cli/` (args/dotenv) + `src/main.lisp` rewrite
    + `src/sys/platform.lisp` (tty/env/hrtime/mem via sb-unix/sb-ext/sb-kernel). `make-realm` stays
    runtime-free; `clun.runtime:install-runtime` augments it (conformance uses the bare realm).
  - Adversarial review panel (6 dims × find→**verify-by-running-the-binary**, 23 agents): **17/17
    confirmed + fixed** — HIGH: float-trap crashes leaking raw Lisp backtraces (`%d`/`process.exit`/
    `hrtime` on NaN/Inf → trap-safe `safe-integer`), stack overflow → `RangeError` (storage-condition),
    getter/setter labels, `on('exit')` on uncaught throw, `.env` bare-`#`; MED/LOW: class-instance
    names, `-p` string raw, chdir errors→catchable, execPath absolutised, `$VAR` expansion.
  - Verified SBCL facts: no `sb-posix:isatty` (use `sb-unix:unix-isatty`); hrtime via
    `sb-ext:get-time-of-day` (µs); Node version pinned **22.11.0**.
  - DEFERRED 🟡: `[class X]` display, SetIterator/MapIterator, exact 80-col array wrapping,
    `hrtime.bigint` real BigInt (Phase 11), `.ts` execution (Phase 09).

- **Phase 09 — TS-STRIP GATE MET + committed (2026-07-12).**
  - `make build` clean; `make test` = **1004 parachute + 42 tests/ts (strip+errors) + 49 tests/js**
    (0 failed); `make purity` clean (**143 files**); `make conformance` parse **17,512**;
    `make conformance-exec` **19,540** (0 crashes, 0 regressions).
  - **Gate:** 78-pair corpus (tests/ts/strip byte-exact + same-length; tests/ts/errors message +
    line:col; tests/ts/runtime strip→run→known-output incl a line-preservation case) all green; each
    catalog error fires with its documented message; strip→run line:col identical to source (whitespace
    render preserves newlines + length).
  - `clun.transpiler` (`src/transpiler/` conditions/ts-type/ts-scan/strip): a recursive-descent strip
    scanner over the shared engine token stream — drives regex/template context via reread-*, balanced
    `skip-type` (`>>` split, arrow-return mode), records erase-spans, space-fills (newlines kept).
    Engine `*ts-strip-hook*` + `read-source-for`; resolver `.mts`→ESM/`.cts`→CJS; CLI rejects `.tsx`.
  - Adversarial review panel (6 dims × find→**verify-by-running-the-stripper**, 24 agents): **18/18
    confirmed + fixed** — contextual keywords as value idents, arrow return types ending in `)`, arrow
    generics w/ default, tag templates + `as`-in-`${}`, `x!!`/`x! as`, superclass type args,
    angle-cast→error, declare-namespace-ambient.
  - DEFERRED 🟡 (documented corners): `a<b>(c)` comparison-call & bare function-type arrow return
    `(): () => X =>` (rare; recommend parens); enum errors (Bun transpiles); class FIELD syntax + `class
    extends` method resolution + `??`/`?.` are pre-existing ENGINE limits (not strip bugs).

- **Phase 10 — REGEXP GATE MET + committed (2026-07-12).**
  - `make build` clean; `make test` = **1054 parachute + 42 tests/ts + 49 tests/js** (0 failed);
    `make purity` clean (**148 files**); `make conformance` parse **17,512**; `make conformance-exec`
    over 37,611 files: **pass 20,631**, **0 crashes**, exec-passlist regenerated (monotonic; 3 documented
    false-passes removed), **0 regressions**.
  - **Gate:** built-ins/RegExp/** **76.1%** (696/915 run) ≥60% ✔; String regex methods
    (match/matchAll/replace/replaceAll/search/split) **96.9%** (283/292) ≥75% ✔; deliberate gaps
    enumerated in tests/conformance/regexp-gaps.txt.
  - `src/engine/regex/` (ast/parser/translate/regexp-object, ~1.1k LOC): own JS-regex recursive-descent
    parser → AST → CL-PPCRE **parse trees** → create-scanner. JS-vs-PPCRE semantics undone in the tree
    (`.`/\s/\w/\b/^/$/octal/empty-class); exec via `:start li :real-start-pos 0`; String delegation +
    Symbol statics; loud SyntaxError for gaps. + `scripts/gen-unicode-tables.lisp` (UCD generator scaffold)
    + `tests/lisp/engine/regexp-tests.lisp` (50 assertions). Vendored built-ins/RegExp/** (1,879 files).
  - Adversarial review panel (5 dims × find→**verify-by-running-the-binary**, 28 agents): **21 confirmed /
    23 candidates**, ALL fixed + re-verified — every finding a SILENT wrong-answer (the design's worst
    class, which the vendored slice passed while mismatching): legacy octal escapes, empty `[]`/`[^]`, /m
    at all JS LineTerminators, ASCII \b/\B, non-ASCII \S/\W/\D in a class, RegExp() flag validation (incl.
    /v), scan-start-relative ^/\b under g/y, fn-replacer named-groups arg, .source EscapeRegExpPattern,
    group-name IdentifierName + duplicate rejection, \c fallback, the Symbol.{match,…,species} statics +
    camelCase descriptions, RegExp(re) IsRegExp short-circuit; exposing the statics unmasked + fixed a
    latent primitive-search-value @@-getter bug. Net: RegExp 64.9%→**76.1%** (+102), String methods
    91.1%→**96.9%**; 0 regressions/crashes.
  - DEFERRED 🟡 (regexp-gaps.txt): fully-generic @@ RegExpExec protocol (user-overridable exec) + @@species
    (B1 — 3 former false-passes removed from the exec pass-list, DECISIONS 2026-07-12), RegExp.escape,
    variable-length lookbehind (loud), Annex-B-under-/u early errors, astral /u (BMP-only), \p{}
    property escapes (loud; UCD gen scaffolded), /v flag, inline modifiers, /d match-indices, 2
    CL-PPCRE-vs-ECMAScript NFA-backtracking edge cases.

- **Phase 11 — BINARY+BIGINT GATE MET + committed (2026-07-12).**
  - `make build` clean; `make test` = **1110 parachute + 42 tests/ts + 49 tests/js** (0 failed);
    `make purity` clean (**151 files**); `make conformance` parse **17,512**; `make conformance-exec`
    over 40,654 files: **pass 22,638**, **0 crashes**, exec-passlist regenerated (monotonic), **0
    regressions**.
  - **Gate:** BigInt **96.1%** (73/76), TypedArray **67.8%** (835/1231), DataView **70.5%** (346/491)
    each ≥65% ✔; overall curated **80.4%** (22,638/28,163) ≥80% ✔; gaps in
    tests/conformance/bigint-binary-gaps.txt.
  - BigInt = plain CL integer (`js-bigint-p`=`integerp`), threaded through values/operators/coercions;
    `builtins-bigint.lisp` (ctor/statics/prototype) + `builtins-binary.lisp` (ArrayBuffer, 11 TypedArray
    exotics over the `jm-*` generics, DataView, TextEncoder/Decoder). Byte assembly pure SBCL (ldb/dpb +
    sb-kernel float bits). + `tests/lisp/engine/binary-tests.lisp` (56 assertions). Vendored built-ins/
    {BigInt,TypedArray,TypedArrayConstructors,ArrayBuffer,DataView} (3,043 files).
  - Adversarial review panel (5 dims × find→**verify-by-running-the-binary**, 19 agents): **14/14
    confirmed + fixed** — crash-safety (signaling-NaN Float32 read, ArrayBuffer/TypedArray huge-alloc
    heap-exhaustion, DataView/fill/set detaching-valueOf, BigInt `**`/`<<` DoS — all now catchable
    RangeError/TypeError, no raw Lisp backtrace) + silent wrong-answers (JSON.stringify BigInt→TypeError,
    descending→ascending TypedArray keys, unstable+NaN-misplacing sort, overlapping `.set` snapshot,
    lone-surrogate→U+FFFD + BOM strip). Also fixed 7 order-of-eval regressions from the `numeric-binary`
    refactor (full ToNumeric per-operand for `-`/`*`/`/`/`%`/`**`) + a `js-unary-plus` double-`valueOf`.
  - DEFERRED 🟡 (bigint-binary-gaps.txt): resizable/growable buffers, SAB/Atomics, @@species subclass
    returns, ES2023 change-by-copy TA methods, TextDecoder streaming/fatal/non-UTF-8 labels, encodeInto,
    the 2^27-bit BigInt DoS cap, Number(bigint)=deliberate TypeError.

- **Phase 12 — NODE-COMPAT WAVE 1 GATE MET + committed (2026-07-12).**
  - `make build` clean; `make test` = **parachute + 42 tests/ts + 53 tests/js** (0 failed); `make purity`
    clean (**159 files**); `make conformance` parse **17,512**; `make conformance-exec` **22,638** (0 crashes,
    0 regressions — the builtin-module hook is NIL/inert in bare test262 realms; engine behaviorally untouched).
  - **Gate:** per-module conformance fixtures tests/js/node/{modules,events,assertions,globals} green (exact
    stdout); node builtins reachable via require + import (CJS + ESM).
  - Substrate: engine `*builtin-module-builder*` hook + `try-builtin-module` (require.lisp/module-loader.lisp)
    + runtime `src/runtime/node/registry.lisp` (install-node-builtins). Modules `src/runtime/node/`
    (path/os/querystring/util/events/assert, self-registering); `src/runtime/globals.lisp` (structuredClone,
    crypto); `clun-global.lisp` extras; new `clun.sys` /proc + os-random-bytes primitives; one shared
    `eng:js-deep-equal` (inspect.lisp). 5 modules authored by a parallel write-only subagent fan-out.
  - Adversarial review panel (5 dims × find→**verify-by-running-the-binary**, 31 agents): **25/26 confirmed +
    fixed** — querystring null-proto + prototype-collision; util BigInt/Symbol/NaN format specifiers + inspect
    depth:Infinity/null host-crash + %j circular + isDate + deprecate-wrapper; events once-removal-by-identity
    + emit('error') no-arg + prependListener newListener + listenerCount(name,fn); assert loose-equal +
    throws-class-validation + AssertionError export; structuredClone Date + DataCloneError; path extname
    leading-dots + format dir===root; os.userInfo $USER; and a class of outside-the-float-mask NaN checks
    (`eng:js-nan-p`, never `=`/`/=`, which trap) across util/querystring/Clun.sleep.
  - DEFERRED 🟡 (matrix): path.win32 throws; util.format %d truncates (Bun-faithful console, not Node's full
    Number); pathToFileURL → string (URL object is Phase 18); util.promisify.custom, once-fire/removeAll
    `removeListener` emissions, full `instanceof assert.AssertionError`; full ironclad + KATs → Phase 19.

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

### Phase 06 — Async engine: generators, promises, modules  (deps: 04, 05) ~2.5k LOC — **DONE (gate MET)**
- [x] **thread-per-coroutine** (§3.1 fallback, not lowering — DECISIONS 2026-07-11); Generator objects (next/return/throw, yield*)
- [x] Promise + job queue (engine-owned; nextTick ahead of microtasks); capability+species; async functions
- [x] for-await (sync+async iterables); async generators; ~ESM linking/TLA → **deferred to Phase 07**
- [x] unhandled-rejection tracking → error (exit 1 at CLI); async-test262 runner support ($DONE/doneprintHandle)
- **Gate:** Promise 76.1% / generators ~78.5% / async 78.1% / for-await 78.7% (each ≥75% ✔); 0 regressions ✔; ordering corpus ✔.

### Phase 07 — Module resolution & CJS  (deps: 06) ~2.5k LOC ⚡(fixtures) — **DONE (gate MET)**
- [x] src/resolver/ pure CL (relative/absolute/bare, ext probing, dir index, main/exports/imports w/ conditions+patterns, self-refs, scoped, symlink realpath); + src/sys/ paths/fs/json (engine-free)
- [x] resolution corpus green (101 assertions / 40+ scenarios, engine-free parachute); + review-panel edge cases
- [x] loader-hook wiring; CJS require (wrapper idiom, this=module.exports, cache, cycles→partial, throw→evict, .cjs/.mjs/"type" gating)
- [x] ESM linking (Option-A frame, live thunks, early errors) + ESM↔CJS interop; JSON modules; import.meta.url/dirname/filename/main
- **Gate MET:** resolution corpus green; fixture app (ESM entry → CJS dep + scoped ESM pkg w/ exports maps + JSON + import.meta) runs; build/test(887)/purity(128) ✓; parse 17,512 / exec 19,540, 0 crashes, 0 regressions.

### Phase 08 — CLI shell, console, process  (deps: 07) ~3k LOC — **DONE (gate MET)**
- [x] dispatcher + exact flags (-e/-p as script — awaits promise; positional-stop; --cwd/--silent/--revision/--backtrace)
- [x] .env autoload ($VAR expansion, quotes, comments); the shared inspector (clun.engine) + full console spec (§3.6)
- [x] process core (argv/env/exit/exitCode/platform/arch/pid/cwd/chdir/versions/stdout.write/isTTY/hrtime/memoryUsage/on('exit'))
- [x] uncaught-error rendering (Name: message + stack, exit 1; stack overflow → RangeError; no Lisp backtrace w/o --backtrace); exit 0/1/2
- [x] **tests/js harness runner** (scripts/run-js-fixtures.lisp, `.out`/`.exit`/`.err`/`.argv` convention; wired into make test via test-js)
- **Gate MET:** run/eval matrix (13 JS fixtures) green; console subset matches Bun; build/test(976 parachute + 13 JS)/purity(138) ✓; parse 17,512 / exec 19,540, 0 crashes, 0 regressions.

### Phase 09 — TypeScript stripping  (deps: 08) ~2.5k LOC ⚡(corpus) — **DONE (gate MET)**
- [x] strip pass per §3.3 sharing the engine lexer (recursive-descent scanner over the token stream; balanced skip-type; exact-length whitespace / position-preserving)
- [x] error catalog (enum/namespace-runtime/param-props/decorators/import=/export=/angle-cast); .tsx rejection — all clean unsupported-ts-syntax → JS SyntaxError w/ line:col
- [x] 65-pair corpus (authored, no vendored amaro) incl. adversarial (< ambiguity, arrow generics, multiline, regex-after-type, template-with-type, postfix !); loader wiring (*ts-strip-hook*, read-source-for) for .ts/.mts/.cts + resolver .mts/.cts formats
- **Gate MET:** corpus green (strip byte-exact+same-length, errors w/ line:col, strip→run outputs); build/test(1004 parachute + 33 TS + 45 JS)/purity(143) ✓; parse 17,512 / exec 19,540, 0 crashes, 0 regressions.

### Phase 10 — RegExp  (deps: 04) ~3k LOC — **DONE (gate MET: RegExp 76.1%, String methods 96.9%)**
- [x] JS regex parser → own AST; AST → CL-PPCRE parse trees (group numbering, named-group map, i/m/s; u via down-translation; JS-vs-PPCRE fixes for . \s \w \b ^ $ octal empty-class baked into the tree)
- [x] RegExp object (lastIndex g/y w/ :real-start-pos absolute anchors, exec/test, flag validation, EscapeRegExpPattern source; /d indices deferred)
- [x] String match/matchAll/replace/replaceAll/split/search with $1/$<name> templates + fn replacer (incl. named groups arg); @@ delegation only when arg is an Object; Symbol.{match,…,species} statics exposed
- [x] loud SyntaxError for documented gaps (\p{}, /v, var-length lookbehind, bad flags/names); UCD table generator scaffolded (scripts/gen-unicode-tables.lisp) for later \p{}
- **Gate MET:** built-ins/RegExp/** 76.1% (696/915) ≥60%; String regex methods 96.9% (283/292) ≥75%; zero crashes/regressions; gaps enumerated in tests/conformance/regexp-gaps.txt.

### Phase 11 — Binary data + BigInt  (deps: 04) ~3k LOC — **DONE (gate MET: BigInt 96.1%, TypedArray 67.8%, DataView 70.5%, overall 80.4%)**
- [x] ArrayBuffer (ub8, half-heap alloc cap), DataView + all 11 TypedArray kinds (ldb/dpb + sb-kernel float bits; integer-indexed exotic over the buffer), detach (bytes→NIL, all views observe)
- [x] TextEncoder/TextDecoder (UTF-8; USV lone-surrogate→U+FFFD + BOM strip; non-utf8 label → RangeError)
- [x] BigInt = plain CL integer, threaded through values/typeof/coercions/all operators; literals (front-end already done); BigInt() ctor + toString(radix) + asIntN/asUintN; mixing/`+bigint`/`Number(bigint)`/JSON → TypeError
- **Gate MET:** BigInt 96.1% (73/76) / TypedArray 67.8% (835/1231) / DataView 70.5% (346/491) each ≥65%; overall curated 80.4% (22,638/28,163) ≥80%; 0 crashes; 0 regressions; gaps in tests/conformance/bigint-binary-gaps.txt.

### Phase 12 — Node-compat wave 1 (sync)  (deps: 08; 10 for assert.match) ~4k LOC ⚡⚡ (flagship fan-out) — **DONE (gate MET)**
- [x] builtin-module substrate: engine `*builtin-module-builder*` hook + `try-builtin-module` (CJS require + both ESM dep loops) + runtime registry/install; node: + bare names, per-realm cache
- [x] node:path (posix; win32 present-but-throwing), node:os (over clun.sys /proc+CL), node:querystring (null-proto parse)
- [x] node:util (format/inspect→shared/promisify/callbackify/inherits/deprecate/isDeepStrictEqual/types/stripVTControl)
- [x] node:events (full sync EventEmitter: snapshot emit, self-removing once by identity, newListener, error-throw)
- [x] node:assert (strict family + loose equal, throws w/ class-validation + match, AssertionError name/code + ctor)
- [x] Clun.inspect/deepEquals(shared)/which/nanoseconds/fileURLToPath/pathToFileURL/sleep; structuredClone (deep + Date + cycles)
- [x] crypto.randomUUID/getRandomValues via pure /dev/urandom (clun.sys:os-random-bytes + engine crypto-fill-random); full ironclad → Phase 19 (logged)
- **Gate MET:** per-module fixtures (tests/js/node/*) green; build/test(parachute + 42 TS + 53 JS)/purity(159) ✓; parse 17,512 / exec 22,638, 0 crashes, 0 regressions. Fan-out: 5 modules by parallel write-only subagents. Review panel 25/26 confirmed + fixed.

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
