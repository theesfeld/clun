# Phase 15 — Test runner (`clun test`)

Objective (§5, §3.6): a Bun-compatible test runner good enough to self-host — discovery, a
hook-ordered collection/scheduler, ~22 matchers on the shared deepEquals/inspector, `.resolves`/
`.rejects`, timeouts, an LCS-diff reporter with Bun's summary block, `--bail`/`--todo`/`-t`, and
migration of the expect-style `tests/js` suites onto `clun test`. **Gate:** meta-test matrix
(pass/fail/skip/todo/only/bail/zero-tests→1) asserted from parachute via the built binary; a
hook-order fixture byte-exact; self-hosted suites green under `make test`.

The framework (describe/test/expect/hooks/scheduler) is implemented in **CL against the engine object
API** — no JS in the implementation (Purity Contract §1.1). Test *files* are JS; their describe/test
calls register into a CL-side tree; a CL scheduler runs the tree, driving async bodies over the
existing event loop.

## 1. Package + files (`src/test-runner/`, package `clun.test-runner`)

`clun.test-runner` gains local-nicknames `(:eng :clun.engine) (:sys :clun.sys) (:rt :clun.runtime)`.
Serial ASDF submodule after `runtime`, before `cli`:
- `registry.lisp` — the test tree (describe/test/hook node structs) + the JS globals
  (`describe`/`test`/`it` + `.skip/.todo/.only/.skipIf/.todoIf/.if/.each`, `beforeAll`/`beforeEach`/
  `afterAll`/`afterEach`, `setDefaultTimeout`) installed on a realm; each records into the tree.
- `expect.lisp` — `expect(v)` → a matcher object; the ~22 matchers + `.not` + `.resolves`/`.rejects`
  + `expect.assertions`/`hasAssertions`, on `eng:js-deep-equal` + `eng:inspect-value`.
- `diff.lisp` — LCS line diff producing Bun's `- Expected`/`+ Received` block.
- `scheduler.lisp` — the hook-ordered executor; drives each callback to settlement with a timeout.
- `reporter.lisp` — per-test lines + the summary block.
- `discovery.lisp` — file discovery + positional substring filters.
- `runner.lisp` — `run-test-command (argv cwd)`: parse test flags, discover, per-file realm →
  load → schedule → report, aggregate, return the exit code.

## 2. Engine seams (added to the engine; keep the loop encapsulated)

Running async test bodies needs to drive the per-realm loop *between* tests without tearing it down,
and to time out. Three engine additions (exported):
- `run-module-file (entry &key realm (teardown t))` — `teardown nil` loads + drives-to-idle but leaves
  the loop + coroutines ALIVE and returns the realm. (Same for the internal load path.)
- `teardown-realm (realm)` — `teardown-coroutines` + `destroy-realm-loop`; the runner calls it in an
  unwind-protect per file.
- `run-callback-to-settlement (thunk realm &key (timeout-ms 5000)) → (values kind value)` where
  `kind ∈ :fulfilled :rejected :timeout`. Binds `*realm*`, `funcall`s THUNK (which `js-call`s the JS
  callback). A synchronous JS throw → `(:rejected value)`. A pending Promise result → attach
  `then(onOk,onErr)` reactions (each records the outcome + `lp:loop-stop`), arm a ref'd
  `lp:set-timer` timeout (fires → `:timeout` + stop), `lp:run-loop`, then `lp:clear-timer`. A
  non-promise / already-settled result → drain microtasks, return its state. This is the ONE place
  the runner touches async; it lives in the engine because it uses the promise internals + loop.

## 3. The tree + collection

Structs: `t-describe` (name, parent, children, hooks {beforeAll/beforeEach/afterAll/afterEach lists},
mode {:normal/:skip/:todo/:only}, has-only-descendant) and `t-test` (name, fn, mode, timeout-override,
line). A file is a root `t-describe`. Registration: `describe(name, fn)` pushes a child describe, binds
it as the "current parent", `funcall`s `fn` (which registers nested describe/test), pops. `test(name,
fn, opts?)` appends a `t-test`. Hook calls append to the current describe's hook lists. Modes come from
the `.skip/.todo/.only` variant used. `.each(table)` expands to one registration per row (name via
`%s`/`%i`/`$var` substitution — subset; document). `setDefaultTimeout(ms)` sets a per-file override.

## 4. Scheduler — Bun-exact hook order

Depth-first over the tree. Maintaining the ancestor describe chain [root … leaf-parent]:
1. On ENTERING a describe (before its first executed test): run its `beforeAll` (outermost first —
   the file root's, then each nested). Implemented by running a describe's beforeAll the first time a
   descendant test is about to run; a `beforeAll` throw marks the describe **failed-skip** → its tests
   report `(skip)`-to-fail and we jump to its `afterAll`.
2. Per test (unless skip/todo-not-run/only-filtered): run beforeEach outer→inner; run the test; run
   afterEach inner→outer (afterEach runs even if beforeEach or the test threw).
3. On LEAVING a describe (after its last test): run its `afterAll` inner→outer; file root's afterAll
   last.
Each hook + test body goes through `run-callback-to-settlement` (async-aware, timeout-enforced).
**`.only`**: a first pass marks whether any test/describe in the FILE is `.only`; if so, only `.only`
tests (and tests inside `.only` describes) run, the rest → `(skip)` (per-file, per Bun). **`.todo`**:
not run unless `--todo`; when run, a PASS is converted to a FAILURE ("this test is marked as todo but
passed"). **`.skip`**: never runs, no beforeEach/afterEach. **CI guard**: `.only` with `CI=true` (or
`--ci`) → the file errors (Bun throws). **`-t <regex>`**: a test runs only if the regex (compiled via
the engine's RegExp) matches the space-joined "describe path + test name"; 0 matches over the whole run
→ exit 1.

## 5. expect + matchers

`expect(actual)` returns a matcher object carrying `actual`, a `not` flag, and `resolves`/`rejects`
async wrappers. Each matcher: compute pass/fail, honour `not`, on failure build an AssertionError-shaped
message (`expect(received).matcher(expected)` + a diff for the deep matchers) and `eng:throw-js-value`
it — the scheduler catches it as the test's failure. Assertion counting: a dynamic `*assertions*`
counter (bumped by every matcher) backs `expect.assertions(n)`/`expect.hasAssertions()`, checked after
the test. Matchers (~22): toBe (js-same-value), toEqual (deep, undefined-insensitive), toStrictEqual
(deep + types + undefined-sensitive), toBeTruthy/Falsy/Null/Undefined/Defined/NaN, toBeInstanceOf,
toBeGreaterThan/GreaterThanOrEqual/LessThan/LessThanOrEqual, toBeCloseTo (precision default 2 → tol
`10^-p/2`), toMatch (string/regex), toContain (SameValueZero) / toContainEqual (deep), toHaveLength,
toHaveProperty (dotted path + optional value), toMatchObject (recursive subset), toThrow
(string=substring / regex=test / class=instanceof / Error=message), `.not`, `.resolves`/`.rejects`
(await the actual promise via `run-callback-to-settlement`, then apply the inner matcher).

## 6. Reporter

Per-test line: `(pass|fail|skip|todo) <describe > path > name>` + `[N.NNms]` **only when stdout is a
TTY** (timing is non-deterministic — omitted off-TTY so fixtures/meta-tests are byte-exact; documented
divergence from Bun which always prints it). A failure prints the assertion error + the `diff.lisp`
block indented under the line. Summary block (leading space per line): `N pass`, `N fail`, `N skip`
(if >0), `N todo` (if >0), `N expect() calls`, then `Ran N tests across M files.` + `[T.TTs]`
(TTY-only timing). Exit code: 1 if any fail OR total tests run = 0 OR (`-t`) 0 matches; else 0.
`--bail[=N]` stops after N (default 1) failures and exits 1.

## 7. Discovery + CLI

`clun test [filters…] [-t re] [--timeout ms] [--bail[=N]] [--todo] [--ci]`. The Phase-08 arg parser
already routes `test` as a subcommand; the runner re-parses its own tail. No positional path → walk cwd
(skipping `node_modules`/dotdirs) for `*.{test,spec}.{js,mjs,cjs,ts,mts,cts}` and `*_{test,spec}.*`. A
positional that is an existing file/dir → use it; else treat positionals as substring filters over the
discovered file paths. `main.lisp` dispatch: `subcommand = "test"` → `tr:run-test-command`.

## 8. Self-hosting + meta-tests

The expect-style `tests/js/**` suites migrate to `tests/js/**/*.test.js` (kept runnable by the fixture
harness where they were stdout-based; the expect-style ones move onto `clun test`). Meta-tests
(`tests/lisp/test-runner/…`, parachute) spawn `build/clun test <fixture-dir>`, normalize timing
(`[\d.]+m?s → [T]`), and assert stdout + exit code across the matrix: all-pass→0, a fail→1, skip/todo
counts, `.only` isolation, `--bail`, `-t` zero-match→1, zero-tests→1, and a byte-exact hook-order
fixture (a describe tree whose hooks `console.log` a trace).

## 9. Risks / deferrals

No snapshots, no mocks/spies (v1 non-goals). `.each` name interpolation is a documented subset. Runaway
**synchronous** tests are non-preemptible (the timeout is async-enforced only — documented). errorMonitor
etc. unaffected. Concurrent tests (`test.concurrent`) run sequentially (documented).
