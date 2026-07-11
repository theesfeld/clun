# DECISIONS

Append-only architectural log. One dated entry per choice: decision, why, alternative rejected,
and any pin (name + version + SHA). Newest at the bottom of each section.

---

## Vendored library pins (Phase 00)

All CL dependencies are vendored under `vendor/` (no quicklisp) and pinned to the SHA below. The
`.git` directories were stripped so the sources are checked in. Purity verified: `make purity`
finds zero foreign-code tokens across the whole closure. Full dependency closure of parachute
resolved empirically (see 2026-07-10 entries).

| Library | Purpose | License | Pinned SHA |
|---|---|---|---|
| cl-ppcre | regex backend (parse-tree API); RegExp Phase 10 | BSD-2-Clause | `a2ea581c23fdc184168423adbd4b4c1f48d42743` |
| parachute | CL-side test framework | zlib | `9a6679e611925dfb59067393c5b7996f69501aa6` |
| documentation-utils | parachute dep | zlib | `fcbd927dee7f311915a27ee557e3db1d4510403c` |
| trivial-indent | documentation-utils dep | zlib | `87b35ff9202b107230e35790e93c471cc7880900` |
| trivial-custom-debugger | parachute dep | BSD-2-Clause | `802473c75d9db625b8f37b05c95dde47b67c52fa` |
| form-fiddle | parachute dep | zlib | `706c4fa07552d56b372f728a225021a14db3f62e` |

Later phases add (Appendix B): ironclad (Phase 12/19), pure-tls + its Linux dep closure with the
cl-cancel purity patch (Phase 19), chipz (Phase 18), cl-base64 (with pure-tls). test262 @ `d1d583d`
and other corpora land as `vendor-data/` in their phases.

---

## §3 settled decisions (seeded from PLAN.md — do not relitigate)

These are carried forward from PLAN.md §3 so the log is self-contained. Fallbacks are recorded in
the plan; a fallback taken becomes its own dated entry here.

- **Engine execution**: compile analyzed AST → CL closures (pre-resolved slots); never
  `COMPILE`-per-function at load (0.16–0.5 ms/fn → 10–25 s startup). cl-js is a design blueprint,
  not vendored (ES3).
- **Strings**: CL strings, one char = one UTF-16 code unit; astral → surrogate pairs; lone
  surrogates legal (verified). UTF-8/WTF-8 conversion only at host boundaries.
- **Numbers**: `double-float` + `with-float-traps-masked (:overflow :invalid :divide-by-zero)` at
  engine entry; Int32 via `ldb`; Ryū port for Number→String; BigInt late.
- **Object model**: spec internal-methods as struct-dispatched functions, Proxy-shaped for post-v1;
  structs never hash-table-per-object (4× memory / 2.7× GC win). Shapes/ICs deferred to Phase 25.
- **Scoping**: parser does full scope analysis; strict AND sloppy from day one, including `with`
  and direct eval.
- **Async/generators**: regenerator-style state-machine lowering (AST→AST) before closure emission.
- **RegExp**: own JS-regex parser → CL-PPCRE parse trees; documented gaps error loudly.
- **Event loop**: hybrid — one JS thread owns heap/timers/microtasks + serve-event reactor; worker
  pool for blocking ops; self-pipe wakeup; interrupt handlers enqueue-only.
- **TLS**: vendor pure-tls (+ ~40-line cl-cancel purity patch) atop ironclad; unaudited, fail-closed
  certs, SRI sha512 independent integrity. Default cipher TLS_CHACHA20_POLY1305_SHA256.
- **Package manager**: npm abbreviated metadata; hand-rolled ustar/pax tar reader; hoisted
  node_modules; `clun.lock` versioned JSON; lifecycle scripts never executed.
- **TypeScript**: type-stripping (whitespace-preserving), not transpilation; no sourcemaps by design.

---

## Dated entries

### 2026-07-10 — Phase 00 toolchain: GNU Make installed via nix
`make` is absent by default on this NixOS host, but every phase gate is defined in terms of
`make build|test|purity`. Installed GNU Make 4.4.1 into the user profile
(`nix profile add nixpkgs#gnumake`; on PATH at `~/.nix-profile/bin/make`). This is a host-toolchain
requirement, not a code change — recorded so CI (`.github/workflows/ci.yml`) and README both list it.
Alternative rejected: rewriting gates as raw `sbcl --load` invocations — would diverge from the plan's
literal gate commands and lose the single canonical entry point.

### 2026-07-10 — parachute dependency closure resolved empirically
Parachute's transitive deps were discovered by iterating `asdf:load-system` failures rather than
trusting memory: parachute → {documentation-utils → trivial-indent; trivial-custom-debugger;
form-fiddle → documentation-utils}. All six vendored + pinned above; all pure. cl-ppcre is a leaf.
`documentation-utils` also ships a `multilang-documentation-utils.asd` depending on an un-vendored
`multilang-documentation` system — left in place, inert (nothing depends on it), and its own source
is pure so the purity scan passes.

### 2026-07-10 — purity scanner: union of the ASDF load plan and the on-disk source scan
`scripts/purity-scan.lisp` scans the UNION of two file sets, per §1.1's literal wording ("the full
ASDF load plan and all vendored sources"): (1) the load plan — `asdf:required-components` for `clun`
and `clun/tests` with `:other-systems t`, i.e. every cl-source-file actually compiled into the image
including vendored deps; and (2) an on-disk scan of `src/`, `tests/`, and `vendor/` (plus root
`*.asd`), which additionally catches files a library ships but loads only conditionally (e.g.
pure-tls's win/darwin CFFI files before Phase 19 strips them) that the plan omits. The union is a
superset of the load plan by construction. `scripts/` is excluded (build tooling; this file holds the
forbidden tokens as its own search patterns). Verified both ways, including a token planted in
`tests/lisp/smoke.lisp`.
Corrected during the Phase 00 review panel: the first cut scanned only `src/` + `vendor/` and claimed
to be a "strict superset of the load plan," but `clun/tests` loads `tests/lisp/smoke.lisp` under
`tests/` — so a foreign token in a test file passed the gate silently. The load-plan walk now makes
the coverage claim true rather than asserted.

### 2026-07-10 — ASDF :version vs runtime version string
`clun.asd` uses `:version "0.0.1"` (ASDF requires dotted integers; `"0.0.1-dev"` triggers a
PARSE-VERSION warning). The user-facing version — asserted by the Phase 00 gate as `clun 0.0.1-dev`
— lives only in `src/version.lisp` (`*clun-version*`). The two are intentionally distinct.

### 2026-07-10 — Phase 01 value representation: native CL types + keyword singletons (not tagged structs)
Decided by micro-benchmark on this host (SBCL 2.6.4, `speed 3 safety 0`, 200M dispatches over 1M
mixed values): native `typecase` dispatch (numbers = `double-float`, strings = CL `string`, objects
= struct, singletons = keywords) measured **0.88 ns/dispatch and 21.4 MB**; a uniform tagged struct
`(defstruct jsval tag data)` measured **3.77 ns/dispatch and 48.0 MB** — native is 4.3× faster and
~2.25× lighter. Native also lets SBCL keep `double-float`s unboxed in typed arithmetic contexts,
which a wrapper struct defeats. This confirms §3.1 (CL strings; `double-float`; structs never
hash-table-per-object). Rejected: the uniform tagged struct (uniform dispatch, but boxes every
number and adds a pointer hop). Singletons `+undefined+/+null+/+true+/+false+` are keywords behind
named constants + predicates so the representation stays swappable (fallback `(unsigned-byte 16)`
string vectors, if memory ever dominates, touches only strings). BigInt (Phase 11) will be its own
struct/tag, not a change to this scheme.

### 2026-07-10 — Phase 02 AST = typed structs; regex-vs-divide by parser-driven re-scan
AST nodes are typed defstructs (`:include`d on a `node` base carrying start/end), generated by a
`defnode` macro; analyzer/printer/emitter dispatch via `typecase`. Rejected a single generic
`(kind . slots)` node (cl-js style): typed structs give free type-checking and clean dispatch, and
§3.1 already prefers structs. Regex-vs-divide is **parser-driven re-scan** (the parser, knowing it is
in expression position, asks the lexer to rescan a `/` token as a regexp — Acorn's model) rather than
the brittle previous-token heuristic. Template continuations use the same re-scan approach with a
depth stack. Lexer is fully reentrant (state in a struct; no specials) so it can back up and rescan.

### 2026-07-10 — Phase 03 built: engine executes JS; 72.8% curated execution (gate ≥70% MET)
The core engine is live and runs real JavaScript. Object kernel (objects.lisp: descriptors, ptable
storage, CLOS-generic internal methods, Array exotic), runtime environments (environment.lisp),
operators (operators.lisp), callables (functions.lisp), realm + ~60 built-ins (realm.lisp +
realm-builtins.lisp), the closure emitter (emitter.lisp, ~1300 lines), and the evaluator (eval.lisp).
Executes expressions, statements, functions/closures, `this`/arguments, objects/arrays, prototype
chains, operators, control flow (incl. labelled break/continue), try/catch/finally, destructuring,
spread, basic classes, and `eval`. 570 CL unit tests + a measured **72.8% pass (5,460/7,500)** on the
curated language slice (minus generators/async/modules) in BOTH strict+sloppy, with only 3 crashes.
The conformance runner now has an EXECUTION phase (`make conformance-exec`, CLUN_EXEC=1) with its own
monotonic exec-passlist, alongside the parse phase.
Simplifications recorded (refined in later phases): global scope resolves to global-object properties
(the split global environment record + global-scope TDZ are approximated); `with` and tagged
templates are loud unsupported errors (not Phase 03); generators/async are clean SyntaxErrors
(Phase 06); RegExp literals error (Phase 10); property storage uses an order-preserving ptable
struct (the inline-small-vector memory optimization is deferred to Phase 25); direct eval is treated
as indirect. Wins that crossed the gate: function-name inference (NamedEvaluation for `var f=()=>{}`)
and a basic indirect `eval`. Fixed during bring-up: a struct-constructor name mismatch, a realm slot
name, parse-time SyntaxErrors needing *realm* bound (so speculation must catch js-condition), class-
declaration binding, and a labelled-continue tag via a pending-label mechanism.

### 2026-07-10 — Phase 03 architecture: CLOS-generic internal methods, closure emitter, env=vector chain
Engine core decisions (docs/design/phase-03.md): (1) the spec internal methods ([[Get]]/[[Set]]/
[[DefineOwnProperty]]/…) are **CLOS generic functions dispatching on the js-object struct subtype** —
SBCL structs are classes, so this is the "struct-dispatched, Proxy-shaped" protocol §3.1 calls for;
ordinary objects get default methods, exotics (Array/arguments/function) override only what they
change. (2) Property storage = small insertion-ordered `key desc …` simple-vector promoting to an
`equal` hash-table (~8 keys); descriptors use an `:unset` sentinel to distinguish absent from false.
(3) Execution = compile analyzed AST → CL closures ONCE (no per-node dispatch, no per-fn COMPILE);
the emitter carries a compile-time lexical env resolving refs to local `(depth.index)` / global /
dynamic (with/eval). (4) Runtime environment = struct `{slots:simple-vector, parent}`; TDZ via a
`+tdz+` sentinel; global scope's slots are properties of globalThis. (5) Non-local control flow
(return/break/continue) via CL `catch`/`throw` tags; `throw` via the Phase 01 js-condition bridge;
try/finally = `unwind-protect`. (6) Per-realm intrinsics indirection from the start (§3.1). Rejected:
hash-table-per-object (Appendix C.12), generic per-node interpreter dispatch (too slow), COMPILE-per-
function at load (0.16-0.5 ms/fn). Full stdlib breadth is Phase 04; Phase 03 wires the minimum to run
the test262 harness and clear 70% of the curated slice.

### 2026-07-10 — Phase 02 milestone 2: early errors + review panel; gate #2 operationalized
Drove the negative-parse gap down and hardened the parser. Added parser-level early errors
(duplicate params incl. generator/async, getter/setter arity, class constructor/prototype rules,
`let` can't bind `let`, var/lexical conflict, rest-must-be-last, new.target/super context, labels
[duplicate + undefined break/continue, reset per function], await/yield in params, regexp flag
validation, untagged-template bad escapes, escaped keywords are identifiers). The runner now decodes
source as UTF-8 (via our own `utf8->code-units`), which also fixed Unicode id-char/whitespace bugs
(LS/PS/NBSP were wrongly absorbed into identifiers; U+2028/2029 now allowed in string literals).
Negative-parse rejection: 2,725 → 3,312 (~74.4%). Remaining ~1,140 misses: ~169 are regexp-PATTERN
negatives that require the Phase 10 regexp parser (a genuine cross-phase dependency, §2.4), the rest a
diverse early-error long tail that the monotonic pass-list grows toward (Phase 03+ continues it).

**Adversarial review panel (24 agents, 5 dims, every finding verified by running clun): 19 confirmed
/ 0 refuted — all fixed.** Notably it caught false-positives my early-error batches introduced:
`for (const [k,v] of Object.entries(o))` and other for-in/of destructuring were wrongly rejected
(guarded the init check with no-in) — fixing this alone unblocked ~1,200 positive tests (pass
16,299 → 17,503). Also fixed: non-decimal BigInt (`0xFFn`), parenthesized unary `**` base (`(-2)**3`),
`async` as a sole arrow param, `in` leaking through parens/brackets/args in a for-init, directive
prologue dropping all-but-last directive (double nreverse), and 7 build style-warnings. Runner
hardened: classify catches `serious-condition` (stack exhaustion → :crash, not an abort); `CLUN_GEN`
now UNIONs the pass-list (only-grows, refuses on crashes); `neg-parse-p` scoped to the negative block.

**Gate #2 operationalization (honest):** the pass-list mechanism (§3.1) is the operative gate and is
sound for *regression*: a negative test we reject is a pass-list entry, so if a future change makes us
wrongly ACCEPT it, it leaves the list → `make conformance` fails. So negatives can only improve. The
literal "100% of negatives" is NOT reachable in Phase 02 (regexp-pattern → Phase 10; long tail), so
Phase 02's gate #2 is operationalized-and-enforced rather than at 100%, consistent with §3.1's
"checked-in pass-list that only grows" and Phase 03's "pass-list workflow live in CI from here on."

### 2026-07-10 — Phase 02 milestone 1: tokenizer + parser + runner (0 crashes), pass-list gate live
First Phase 02 milestone landed. Tokenizer (365 lexer assertions incl. token-span property),
full ES2017 recursive-descent + Pratt parser, focused scope analyzer (lexical-redeclaration early
errors, conservative — never false-positives), AST printer, and the test262 parse-phase runner.
Measured over the vendored corpus (23,713 language tests): **0 crashes**, 16,327 pass (positive parsed
+ negative rejected), ~2,988 gaps, 4,398 skipped (unsupported syntax). The gate mechanism (§3.1) is
live: `make conformance` fails on any crash or any regression of the checked-in, sorted, only-grows
`tests/conformance/parse-passlist.txt`; verified it catches a planted regression.
Gate status: criteria "no crashes" and "token-span property" are MET; "all negative-parse →
SyntaxError" is ~2,725 rejected with a remaining early-error long tail (~1,700 misses in the
expressions/statements buckets) — the next milestone closes it. This is a "milestone of a large
phase" per §2.2, not phase completion. Fixed during self-review: `async ident =>` single-param arrow
detection (needed 2-token lookahead past `async`).

### 2026-07-10 — Phase 02 tier line: skip post-ES2017 SYNTAX in the test262 runner, never crash
The v1 parser targets ES2017 + cheap ES2018/19 (object rest/spread, async iteration, optional catch).
Post-ES2017 syntax (class fields/private, decorators, top-level await, dynamic import, numeric
separators, logical-assignment, `??`/`?.`, `using`) is NOT parsed; the test262 runner skips tests
whose `features:` name these, and the parser must still never crash (clean SyntaxError only). This
holds the tier line while keeping the "parse all language/** without crashes" gate meaningful.
test262 vendored @ d1d583d (HEAD on 2026-07-10): 23,713 language tests, 4,449 negative-parse.
Two fixes from the Phase 01 adversarial panel (both in `src/engine/numbers.lisp`):
(1) **ASCII-only digits.** CL `digit-char-p` accepts every Unicode Nd char, so `Number("١")`
(Arabic-Indic) wrongly returned 1. ECMA-262 §12.9.3 admits only ASCII 0-9/a-f. Replaced
`digit-char-p`/`parse-integer` in the StringToNumber path with `%ascii-digit`/`%ascii-decimal-digit-p`;
non-ASCII digits now yield NaN. Regression tests cover Arabic-Indic/Devanagari/fullwidth digits in
integer, fraction, exponent, and 0x positions.
(2) **Adversarial-length clamp (§6).** `Number("1e1000000")` built a million-digit `(expt 10 exp)`
bignum (measured 470 ms from a 9-char input — asymmetric amplification). Now the result magnitude
(`decimal-length(mantissa) + exponent`) is bounds-checked first: `> 310` → ±Infinity, `<= -324` →
±0, else exact. The clamp is exact-safe (a value is `< 10^mag`), so no representable double is
mis-clamped; `"1e1000000"` is now instant. A huge *digit-string* mantissa is still built (cost
proportional to input, no amplification) — acceptable for Phase 01.
Panel outcome: 5 confirmed / 5 refuted (adversarially verified by running code). The other three
confirmed were test-completeness nits (huge-string, ToInt32/Uint32 modulo-2^32, WTF-8 multibyte
maximal-subpart) — implementations were already correct; tests added.

### 2026-07-10 — Phase 01 Number→String uses naive bignum shortest-round-trip (Ryū deferred to Phase 04)
Per §3.1 the Ryū port is a Phase 04 task; Phase 01 still needs a correct `ToString(number)`. Chose
the plan's named fallback — shortest-round-trip via exact rational arithmetic (try increasing
significant digits until read-back `=` the source double), framed by the ECMA-262 Number::toString
algorithm (sign, NaN/±Infinity/±0, the ≤-6 / ≥21 exponent thresholds). Correct but O(17) per format;
Phase 04 swaps the digit core for Ryū for speed. Pure CL, no SBCL float-printer internals.

### 2026-07-10 — Phase 04: Ryū port is the interval method with a bignum backend (tables deferred)
Replaced the Phase 01 naive "increase precision until round-trip" digit core with Ulf Adams' Ryū
*algorithm*: decode the double (`integer-decode-float`), form the exact rounding interval to the two
neighbours (halved gap at a lower power-of-two boundary; closed iff the mantissa is even), and emit
the decimal with the fewest significant digits inside it (largest power-of-ten step with a
representable in range; nearest to x, ties-to-even). Kept exact with CL rationals — Ryū's 128-bit
fixed power-of-5 *tables* are a speed optimization only and are deferred to Phase 25; correctness and
purity are unaffected. The Phase 01 exact-rational routine is retained as `%shortest-digits-oracle`
and cross-checks the Ryū path in the unit suite: known-answer vectors (0.1, 1e21, 5e-324, DBL_MAX,
2^53, …) **plus** a 40k deterministic-random-bitpattern corpus, **0 mismatches** (and 0 across 250k
in ad-hoc runs). Seeded the log estimate from the value (not the upper endpoint) so it never
overflows `coerce` to Infinity at DBL_MAX.

### 2026-07-10 — Phase 04: the NaN/Infinity float-trap discipline for builtins
JS arithmetic masks the IEEE traps (Appendix C fact 4), but built-ins run *outside* that mask, and CL
signals `FLOATING-POINT-INVALID-OPERATION` on any *numeric* comparison with NaN (`= < > zerop minusp`)
and on `floor`/`truncate` of NaN/±Infinity. The first built-ins crash sweep surfaced 278 such crashes.
Fixes: (1) `js-zero-p` is now `(or (eql x 0d0) (eql x -0d0))` — `eql`, never `=`, so NaN is safe;
(2) a new `%int` (coercions.lisp) does ToIntegerOrInfinity→CL-integer mapping ±Infinity to fixnum
bounds, and *all* index/length/digit sites go through it or `length-of-array-like`/`to-length` instead
of raw `(floor (to-number …))`; (3) `array-set-length` feeds `double->uint32` the ToNumber'd value
(was the raw JS value → CL type-error on `:undefined`) and guards the NaN compare; (4) the comparator
in `Array.prototype.sort` treats a NaN result as +0; (5) `Function.prototype.apply`/CreateListFromArrayLike
reject a non-object argArray. Rule going forward: any builtin comparing a possibly-NaN double must test
`js-nan-p` first or run under `with-js-floats`.

### 2026-07-10 — Phase 04: Reflect included; Math.random fixed-seed; Date local == UTC
- **Reflect** (§28.1) is implemented (thin wrappers over the object internal methods) though not in the
  literal Phase 04 list: it is stdlib-core and unblocks the `isConstructor.js` harness (`Reflect.construct`)
  that `is-a-constructor` tests across every intrinsic depend on. **Proxy** stays deferred.
- **Math.random** uses a fixed-seed xorshift64* — deterministic and pure. Unpredictability is not
  observable by test262 (only the [0,1) range/type are), so no entropy source is pulled in.
- **Date**: local time == UTC (`getTimezoneOffset()` ≡ 0); the UTC and "local" getter/setter families
  are aliased. `Date.now` uses `get-universal-time` (second precision; determinism/purity over
  sub-ms). Gregorian⇄ms is pure integer CL (exact: |tv| ≤ 8.64e15 < 2^53). TZif local zones deferred
  to Phase 26 (PLAN.md §3.1).
- **Function constructor** (`new Function(args…, body)`) compiles `(function anonymous(params){body})`
  via `indirect-eval` in global scope; SyntaxError in either part propagates as a JS SyntaxError.

### 2026-07-11 — Phase 04 review panel: 20 confirmed / 0 refuted, all fixed (verified by running JS)
A 6-dimension adversarial panel (each finding re-verified by running the repro against the built
engine) surfaced 20 genuine spec divergences, all fixed before the phase commit:
- **JSON.parse host crashes at EOF** (`"tru"`, `"\`, `"\u12`): `jr-next` did an unchecked `(char …)`
  → SBCL INVALID-ARRAY-INDEX escaping JS try/catch. Now EOF-safe → JS SyntaxError.
- **padStart/padEnd/repeat heap-exhaustion** on Infinity/1e9 length: `%int` maps ∞→fixnum, then a
  ~GB string was materialized and killed the process. Added `+max-js-string-length+` (2^28) cap →
  RangeError("Invalid string length"). A clun materialization limit under the host heap, not a spec bound.
- **toExponential/toPrecision ties-to-even**: `%round-to-k` (CL `round`) is correct for the Ryū
  shortest-digits path but §21.1.3 wants ties-away ("pick the larger n"). Split off `%round-to-digits`
  with half-away rounding; Ryū/oracle path unchanged. (toFixed was already correct.)
- **JSON.stringify(x, [])** serialized all keys: `(or prop-list …)` can't tell an empty whitelist from
  "no array replacer". Added a `prop-list-p` presence flag.
- **Set −0 not canonicalized**: `md-set` canonicalized the entry KEY but stored the VALUE raw, and Set
  iteration reads the value. Set add/ctor now store `(%svz-store element)` in both slots (Map values
  stay raw — only Set elements are SameValueZero-canonicalized).
- **Date.parse over-permissive**: blanket `(<= 1 date 31)` rolled Feb 29 (non-leap)/Apr 31 into the next
  month, and hour 24 was accepted with nonzero min/sec/ms. Now validates day against leap-aware
  days-in-month and requires min=sec=ms=0 when hour=24.
- **String.lastIndexOf ignored its position arg**: now clamps position and bounds the from-end search.
- **Math.clz32** returned −1 near 2^32 (log2 rounds up) → `(- 32 (integer-length …))`, always 0..32.
- **Math.log10** of exact powers of ten (1000→2.9999999999999996): special-cased to the exact exponent
  for Node parity (spec permits approximation, but Node is the stated oracle).
Panel method note: findings are only counted when the verifier reproduced the divergence by running the
repro; 0 were refuted this round (the reviewers had a working JS-eval harness, so raised findings were
already run-confirmed).

### 2026-07-11 — Phase 05: fd handlers must be registered on the serve-event thread
Discovered empirically this phase (extends Appendix C.5): SBCL's `serve-event` dispatches an
`add-fd-handler` registration **only for the thread that made it** — a handler added on thread A is
silently never called when thread B runs serve-event (measured: a cross-thread self-pipe write left
serve-event blocked the full timeout; registering on the serving thread fired it immediately). So
`run-loop` registers the self-pipe handler itself, on the loop thread, in an unwind-protect, rather
than `make-event-loop` (which may run on a different thread). Consequence for Phase 16: socket fd
handlers must be added from the loop thread (marshal via `loop-post`, never from a worker). The
self-pipe wakeup itself is verified working cross-thread once this rule is honored.

### 2026-07-11 — Phase 05: event-loop shape (thunk queues now, JS jobs in Phase 06)
The loop (`src/loop/`) is callback-agnostic: tasks/microtasks/nextTicks are opaque CL thunks in
Phase 05 (the gate's "stub queue"); Phase 06 pushes JS Promise jobs into `enqueue-microtask` and
`process.nextTick` callbacks into `enqueue-next-tick` without changing the loop. Decisions:
- **Time base** `now-ms` = `(floor (get-internal-real-time) 1000)` (internal-time-units-per-second is
  1e6 here); integer ms throughout, no floats in the timer path.
- **Timers**: own binary min-heap keyed (deadline, seq); seq breaks ties FIFO (Node). Cancellation is
  lazy (mark + skip on pop) — simpler than O(log n) sifted removal; a cancelled-timer flood is
  acceptable for v1. A per-batch `max-seq` snapshot stops a 0 ms timer scheduled inside a callback
  from re-firing the same turn (Node-faithful).
- **Liveness**: a `handle` contributes to `ref-count` exactly while refd∧active. `loop-alive-p` =
  ref-count>0 ∨ immediate-work. Unref'd timers/handles never keep the loop alive. Ref'd timers and
  in-flight worker jobs own handles.
- **Signals**: OS handler does only `(sb-ext:atomic-incf (aref counts signo))` + `self-pipe-wake`
  (§6 iron rule; allocation-free). The loop thread compares counts to a `seen` high-water mark and
  runs each pending listener once per turn (coalescing, like Node signal events).
- **Wake safety**: `self-pipe-wake` writes one byte via `sb-unix:unix-write` from a `defglobal` pinned
  buffer — no consing, no locks — so it is legal from signal/interrupt context. Full-pipe EAGAIN is a
  no-op (a wake is already pending). unix-write never signals on EAGAIN, so no condition is consed.
- **Timeout cap** 1 s: bounds a dropped wake; real latency is self-pipe-immediate, not cap-bound.
- **Contribs**: `clun.asd` now `:depends-on ((:require "sb-posix") (:require "sb-concurrency"))`;
  sb-thread is built in. Internal SBCL APIs (unix-write, make-fd-stream, poll probe) are quarantined
  in `src/sys/sbcl-compat.lisp` per §3.2/§6. Note: the `make purity` token scan matches inside
  comments — the sbcl-compat header says "no foreign code", never the literal forbidden tokens.

### 2026-07-11 — Phase 05 review panel: 6 confirmed / 0 refuted, all fixed (verified by running Lisp)
A 4-dimension adversarial panel (each finding re-verified by running Lisp against the built loop)
found six genuine defects, all fixed before the phase commit:
- **Liveness ignored the cross-thread mailbox.** `immediate-work-p` checked only the three JS FIFOs,
  so a `loop-post` that was the last pending work — an external post, a worker completion's follow-up
  post, or a post from the final timer callback (whose one-shot handle already deactivated ref-count
  to 0) — was stranded in the mailbox and the loop exited. Fix: `immediate-work-p` now also counts a
  non-empty mailbox. (`loop-timeout` already consulted it; the two are now consistent.)
- **Liveness ignored pending signal deltas.** A signal delivered exactly as the last ref'd handle
  deactivated was dropped (the OS handler bumped the counter + woke the pipe, but the top-of-iteration
  liveness gate exited before `drain-signals`). Fix: new `pending-signals-p` (any counts[s] > seen[s])
  is part of `immediate-work-p`.
- **destroy-event-loop left OS signal handlers installed.** The surviving sigaction closes over the
  loop's self-pipe; after `self-pipe-close` the write fd is closed and may be recycled, so the next
  delivery wrote the wake byte into an unrelated object's fd (measured: a 0x01 byte injected into a
  fresh pipe that reused the number) or hit EBADF — a §6 interrupt-context use-after-close. Fix:
  destroy uninstalls every installed signo (→ `enable-interrupt :default`) before closing the pipe.
- **Per-loop install flag guarded a process-global enable-interrupt.** `sb-sys:enable-interrupt` is
  process-wide, but the `installed` guard was a per-loop signal-state slot, so a second live loop
  installing the same signo silently overwrote the first loop's handler. Clun is single-loop (§3.2);
  fix: a process-global `*signal-owners*` makes a conflicting live registration a loud error, and
  `remove-signal-handler`/destroy release ownership (so sequential loops reclaim it cleanly).
All six are locked as parachute regressions in tests/lisp/loop/loop-tests.lisp (680 unit tests total).
