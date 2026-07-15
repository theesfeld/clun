# Phase 25 — §5 Background-Thread Hot-Function COMPILE Tier

Status: DESIGN (operator-approved to build; scope is large and honestly spans several
milestones — reconfirm after m1). This document specifies the COMPILE tier deferred from
`docs/design/phase-25.md` §5 and named as an option in the m10 open decision. Its single
target is to push **deltablue** from its current **3.81×** (`phase-25.md` m9) to a
per-benchmark **≥5×**. Richards (6.62×) and splay (5.30×) already meet the gate; they are
in scope only as correctness/regression guards, not as the thing this tier is trying to fix.

Everything below is grounded in the actual Phase-03 emitter (`src/engine/emitter.lisp`),
the function kernel (`src/engine/functions.lisp`), the object/IC layer
(`src/engine/objects.lisp`), and the frame model (`src/engine/environment.lisp`). Where a
claim is a proposal rather than existing code, it is marked as such.

---

## 1. Overview and the core idea

### 1.1 What a compiled body is today

A user function's `compiled-body` slot (`objects.lisp` `js-function`; invoked at
`functions.lisp:14–15` in `jm-call`) holds a closure of signature
`(lambda (fn this args new-target) -> js-value)`. That closure is built by
`compile-function-common` (`emitter.lisp:667–762`) and its body is a **tree of per-node
closures**: `compile-node` (`emitter.lisp:115–179`) dispatches each AST node to a
`compile-*` function that returns a `(lambda (env) ...)`. Each such lambda evaluates its
children by `funcall`ing their closures and threading the runtime frame `env` through.

Concretely, the emitter produces exactly these shapes (verbatim from the source):

- Non-computed member read (`emitter.lisp:289–296`):
  ```lisp
  (let ((key (identifier-name ...)) (cache (%make-ic)))
    (lambda (env) (%ic-read (funcall obj-fn env) key cache)))
  ```
- Method call (`emitter.lisp:322–328`):
  ```lisp
  (lambda (env) (let* ((o (funcall obj-fn env)) (f (%ic-read o key cache)))
                  (js-call f o (funcall args-fn env))))
  ```
- Local variable read (`emitter.lisp:229–231`): `(lambda (env) (frame-ref env depth index name))`.
- Return (`emitter.lisp:689–730`): the body is wrapped in
  `(catch return-tag (funcall body-fn frame) +undefined+)`; `return e` compiles to
  `(throw return-tag <value>)`.

### 1.2 The overhead

For a body of `N` AST nodes, evaluating it does on the order of `N` indirect `funcall`s,
one per node, each re-threading `env`. SBCL cannot see across a `funcall` boundary: it
cannot inline `js-add` into its caller, cannot keep an intermediate in a register across
two sibling nodes, cannot hoist the `frame-ref` depth-walk out of a loop. The per-node
closure tree is *already* SBCL-compiled machine code individually (each `compile-*` defun
runs at load), but the **edges between nodes are opaque indirect calls**, so there is no
cross-node optimization and a fixed per-node dispatch cost. That per-node dispatch cost is
the residual the earlier Phase-25 milestones (m2–m9) could not remove without changing the
execution model — it is the "tree-walker case" called out in `phase-25.md` §8.1 and m10.

### 1.3 The core idea

The tier is a **second emitter backend**. Instead of returning a tree of closures for a
function body, it walks the same analyzed AST and emits **one CL source form** for the
whole body, then `cl:compile`s that form into a single native function of the same
`(fn this args new-target)` signature. The generated form **reuses every existing runtime
primitive unchanged** — `%ic-read`/`%ic-write`, `js-getv`/`js-set`, `js-call`,
`js-add`/`js-sub`/…, `frame-ref`/`frame-set`/`frame-init`, `js-truthy`, `to-property-key`,
the catch/throw return protocol. It introduces **no new semantics**: byte-for-byte the same
runtime helpers run, just wired together with direct calls inside one function body so SBCL
can register-allocate and inline across node boundaries and drop the per-node `funcall`.

This is the only lever left for deltablue that does not either (a) rewrite the object/IC
kernel again (diminishing, per m10 option B) or (b) invent new observable behavior. It is
deliberately a backend swap, not a new VM.

---

## 2. Approach decision

### 2.1 Options considered

**Option A — "compile the closure tree as-is."** No-op. Each `compile-*` closure is
*already* native code (its `defun` was compiled at load). `cl:compile`-ing the outer
`compiled-body` closure again changes nothing: the edges are still indirect `funcall`s
through slots and captured variables. Rejected — it is what `phase-25.md` §5 already warned
buys nothing.

**Option B — full IR / rewrite.** Build a real bytecode or SSA IR, a register allocator,
generators-as-state-machines, etc. Correct in principle but enormous, and it duplicates
work SBCL already does well. Rejected as far out of proportion to a single-benchmark gap.

**Option C (chosen) — source-generating backend over a coverable subset.** Emit one CL
`(lambda (fn this args new-target) ...)` source form for functions whose every feature is
in a statically-decidable "coverable subset," `cl:compile` it, and **fall back to the
existing closure tree for everything else**. This reuses all runtime primitives, adds no
semantics, and is correctness-boundable because the fallback is the already-shipping,
already-conformant interpreter. The subset analysis and the fallback are the whole safety
story.

### 2.2 What CL source is generated (concretely)

The new backend (`compile-source-*`, proposed, living beside the closure emitter) walks the
same analyzed AST and returns CL *forms* (not closures). The generated function body is one
form; call it with the emitter's existing frame protocol.

- **Frame / locals.** A local read `frame-ref(env, depth, index, name)` becomes a literal
  call `(frame-ref env <depth> <index> "<name>")` with `depth`/`index` as compile-time
  constants (they are already constant-folded into the closures at
  `emitter.lisp:229–269`). Writes → `(frame-set env <depth> <index> <vform>)`, TDZ-bypassing
  declaration init → `(frame-init …)`. `env` is the frame the wrapper hands to the body.
  The reserved slots `%this%`, `%new.target%`, `%coro%`, and `arguments` keep their existing
  slot indices; `this` reads compile to `(frame-ref env <d> <i> "this")` exactly as today
  (`emitter.lisp:237`). **No change to the frame model** — the generated code calls the same
  three frame primitives.

- **Member read.** The closure form
  `(lambda (env) (%ic-read (funcall obj-fn env) key cache))` becomes the source
  `(%ic-read <obj-form> "<key>" #.<ic-cell>)`. The **per-site IC cell is preserved by
  reference**: at source-generation time we allocate the `(%make-ic)` cell exactly as the
  closure backend does, then splat that *live object* into the generated form as a literal
  (load-time-value / quoted object handed to `cl:compile`'s environment; §3.4). So the
  compiled body closes over the identical `ic` struct and mutates the identical cache cell
  the interpreter would have. IC warmup done under the interpreter is **not lost** — if we
  reuse the interpreter's existing cells for that call-site (the tier can hold the closure
  tree's cells and reuse them), the compiled body starts warm; if we allocate fresh cells,
  they simply refill on first hit. Either is correct; reusing is a performance nicety, not a
  correctness requirement.

- **Member write.** `obj.x = v` → `(%ic-write <obj-form> "<key>" <v-form> #.<ic-cell> <strict>)`,
  same cell-by-reference rule. Computed member → `(js-getv o (to-property-key <k>))` /
  `(js-set o (to-property-key <k>) v strict)` (no cell).

- **Calls.** Plain call → `(js-call <callee-form> +undefined+ <args-form>)`. Method call →
  `(let* ((o <obj-form>) (f (%ic-read o "<key>" #.<ic-cell>))) (js-call f o <args-form>))`,
  mirroring `emitter.lisp:322–328`. `<args-form>` for the simple (no-spread) case is
  `(list <a1> <a2> …)` — the source backend can build the arg list inline instead of
  `mapcar`ing over child closures, which is one of the concrete wins. Spread args fall back
  to the existing `iterable->list` append loop, or exclude the function from the subset for
  m1/m2.

- **Arithmetic / operators.** `a + b` → `(js-add <a-form> <b-form>)`; likewise `js-sub`,
  `js-mul`, `js-div`, `js-mod`, `js-exp`, the bitwise ops, `js-lt`/`js-le`/…,
  `js-strict-eq`/`js-loose-eq`, `js-typeof`, `js-neg`, etc. — the identical operator
  functions, now nested as direct calls so SBCL can keep intermediates in registers across
  the tree.

- **`if` / `while` / `for` / `do-while`.** `if (t) c else a` → `(if (js-truthy <t-form>) <c> <a>)`.
  Loops → CL `loop`/`do` with the existing break/continue **catch-tag protocol reproduced
  in source**: allocate the same fresh tag objects (`(list 'break)`, `(list 'continue)`) as
  lexical bindings in the generated body and emit
  `(catch <break-tag> (loop … (catch <continue-tag> <body-form>) …))`, `break` →
  `(throw <break-tag> :break)`, `continue` → `(throw <continue-tag> :continue)`. This is a
  literal transcription of `emitter.lisp:917–1051`'s runtime shape into source, so behavior
  is identical.

- **Return.** The whole body form is wrapped `(catch '<return-tag> <body-form> +undefined+)`
  and `return e` → `(throw '<return-tag> <e-form>)`, matching `emitter.lisp:689–730`. The
  tag is a fresh per-compile gensym/list object bound in the generated lambda, so nested
  and recursive calls each get their own dynamic extent exactly as the closure version does.

- **Parameter binding.** For the coverable subset, all params are plain identifiers
  (`simple-params`, already computed at `emitter.lisp:681`). Binding compiles to
  `(frame-init env 0 <i> (nth <i> args))`-style stores (or the existing `bind-parameters`
  call for the fallback shape). Destructuring / defaults / rest are **out of the subset**
  (§5, §6) and force fallback.

The `setup-frame` half of the wrapper (allocate the frame, seed reserved slots, hoist
nested declarations) is **kept as-is** from `compile-function-common`; only the `run-body`
inner form is swapped from "call the closure tree" to "call the cl:compiled body." That
keeps the swap surface tiny and the frame semantics literally identical.

---

## 3. Tier-up mechanism

### 3.1 Call counter

Add one slot to `js-function` (`objects.lisp`, the struct at 538–547):

```lisp
(call-count 0 :type fixnum)   ; Phase-25 COMPILE tier: hot-function trigger
```

`jm-call` (`functions.lisp:14–15`) increments it on entry:

```lisp
(defmethod jm-call ((f js-function) this args)
  (with-js-floats
    (when (< (the fixnum (incf (js-function-call-count f))) most-positive-fixnum) nil)
    (funcall (js-function-compiled-body f) f this args +undefined+)))
```

The increment is a plain (non-atomic) `incf`; the counter is a *heuristic*, not a
correctness input, so a lost increment under a race only delays tier-up. A saturating check
avoids fixnum overflow on very hot functions. `jm-construct` (`functions.lisp:25`) counts
too if we want constructors (deltablue is constructor-heavy) to tier up.

### 3.2 Trigger and enqueue

At a threshold `T` (start with `T = 10 000`; tune in m4 against deltablue), and only if the
function is (a) in the coverable subset and (b) not already compiled/queued, enqueue a
compile job. The subset flag (`compilable`, tri-state `nil` / `:pending` / `:compiled`,
proposed slot) is computed **once at function-definition time** in `compile-function-common`
(§5), so the hot path only tests a slot, never re-analyzes. Enqueue is a single push onto a
lock-protected queue; the main JS thread does not block.

### 3.3 Background worker + swap

Reuse the existing threading substrate. The engine already runs code on `sb-thread`
(`src/engine/async/coroutine.lisp` drives ordinary compiled bodies on their own
`sb-thread:make-thread` with semaphores), and the project ships a loop-level worker module
(`src/loop/workers.lisp`, wired in `clun.asd`). The tier runs a **single dedicated compiler
thread** (compilation is CPU-bound and we want at most one `cl:compile` in flight to bound
memory and contention). It loops: pop a job, generate the source form, `cl:compile` it, then
publish.

**Publish = swap the `compiled-body` slot.** The main thread keeps running the closure tree
until the swap; there is no on-stack replacement — an in-flight call finishes on the old
body, and the *next* `jm-call` picks up whichever body the slot holds. This is the safe,
standard "no OSR" tiering the coverability analysis assumed.

**Is a single slot store atomic on SBCL?** A structure-slot store of a single boxed value
compiles to one aligned word write, which SBCL/x86-64 executes atomically at the hardware
level — a concurrent reader sees either the old closure or the new one, never a torn
pointer. That is sufficient here because both closures satisfy the same contract, so any
interleaving is observably fine. To be explicit and portable, publish via
`sb-ext:atomic-update` / `sb-ext:cas` on the slot (declare it appropriately), or use a
one-word indirection cell updated by CAS. A publish barrier (the CAS) also ensures the
freshly-compiled function object's writes are visible before the pointer is. **The counter
race and the swap race are both benign**: worst case is a function compiled twice or run one
extra time on the old body.

### 3.4 Thread-safety of `cl:compile` and shared realm/intrinsics

`cl:compile` on SBCL is thread-safe to *call* from a background thread. The subtle points:

- **The generated form must not capture thread-local dynamic state.** `with-js-floats`
  masks FP traps per call chain via the `*fp-masked*` special (`phase-25.md` m2;
  `numbers.lisp` notes a fresh thread sees the global value). The **compiler thread only
  compiles**; it never *runs* the JS body, so its FP environment is irrelevant. The body
  runs later on the main thread, which enters through `jm-call`'s `with-js-floats` exactly
  as before. Confirmed safe as long as the generated body does **not** itself re-establish
  or assume FP state — it must inherit the caller's, which it does because
  `jm-call`/`jm-construct` still wrap it.
- **Referencing the same realm/intrinsics.** The generated code references `+undefined+`,
  `+true+`, IC cells, and runtime functions — all global, load-time constants or
  process-global structs. It does **not** bake in a `*realm*` pointer; per-realm data is
  reached through the frame/`env` and the objects passed in at call time, identical to the
  closure backend. So a body compiled while the main thread mutates realm state is fine: it
  reads realm state only when *run*, on the main thread, through the same channels.
- **Splatting the live IC cell into the form.** Handing a live struct to `cl:compile` as a
  literal is done via `load-time-value` of a captured lexical, or by compiling a form
  returned from a closure that lexically binds the cells (compile a
  `(lambda () (lambda (fn this args new-target) …))` whose outer lambda binds the cells, then
  funcall it). The cells are allocated on the compiler thread but only *mutated* later on the
  main thread; if the interpreter also holds them, hand-off must ensure no concurrent
  mutation during the window — simplest is to allocate **fresh** cells for the compiled body
  (they refill on first use), sidestepping any shared-mutation race entirely. m1 uses fresh
  cells; reusing warm cells is an optional m4 optimization gated on a soundness check.

---

## 4. Correctness obligation and verification

**Obligation:** for every function the tier compiles, the compiled body must be
**observably identical** to the closure tree — same return value, same thrown exceptions,
same side-effects (property writes, their order, coercion side-effects via `valueOf`/
`toString`), same `this`/`arguments`/`new.target` behavior. The source backend is a
transcription of the closure backend over the same primitives, so "identical" is the design
intent; verification must *prove* the transcription has no gaps.

**Verification harness (proposed, built in m1, extended each milestone):**

1. **Differential runner.** A debug switch `*compile-tier-mode*` with values:
   - `:off` — current behavior (closure tree only).
   - `:eager` — **compile every coverable user function at definition time** (threshold 0,
     synchronous), fall back for non-coverable. This is the coverage shake-out mode: it
     maximizes how much generated code executes so subset bugs surface immediately.
   - `:threshold` — production behavior (background tier-up at `T`).
   Run the whole test/benchmark corpus under `:off` and under `:eager` and **assert
   byte-identical stdout + identical thrown-error taxonomy + identical final heap-visible
   state** (e.g. serialize benchmark result objects). Any divergence is a coverage bug →
   the offending construct is removed from the subset (fail closed) and a regression probe
   added. This is the "tier-up forced at N=1 vs disabled, assert identical" test the operator
   asked for, generalized to eager-compile-all.
2. **Full test262 G1.** The gate is the frozen pass-list (conformance 22,643 at m9,
   `phase-25.md` m3–m9). Run the entire G1 suite under `:eager` and require the pass-list to
   be **unchanged**. Because non-coverable tests fall back to the interpreter, and coverable
   ones must match it, the only acceptable delta is zero. A single regression blocks the
   milestone.
3. **Benchmark equivalence.** deltablue/richards/splay each produce a checksummable result
   (deltablue verifies its plan; richards/splay have known outputs). Assert identical result
   under `:off`, `:eager`, and `:threshold` before trusting any timing number.
4. **Differential fuzz (m2+).** Feed random small programs restricted to the coverable subset
   through `:off` vs `:eager`, diff outputs. Cheap, and it finds transcription corners the
   fixed corpus misses.

The correctness argument reduces to: *the subset predicate is conservative, the fallback is
the shipping interpreter, and eager-compile + G1 + differential prove the compiled path
matches the interpreter on everything the subset admits.*

---

## 5. Coverable subset (decided once, at definition time)

The predicate is computed in `compile-function-common` (`emitter.lisp:667–762`) when the
function is first compiled, and cached in the proposed `compilable` slot. A function is
coverable iff **all** hold (grounded in the coverability map and the emitter):

- Not a generator, not async (`emitter.lisp:673–674` — these inject `%coro%` and run
  coroutine state machines; **hard**, always interpret).
- No `with` in the body (`emitter.lisp:1274–1277` — dynamic scope; **hard**).
- No direct `eval(...)` call site (`emitter.lisp:329` — direct eval unsupported; **hard**).
- **Simple params only** — every param a plain identifier (`simple-params`, already computed
  at `emitter.lisp:681`); no destructuring, defaults, or rest (those spawn nested thunks,
  `emitter.lisp:764–769`).
- No labeled break/continue that crosses a scope boundary, and no `try`/`finally` where
  `finally` must run on a labeled break/continue escape (`emitter.lisp:1199–1272`). Plain
  `try`/`catch` and innermost-loop unlabeled `break`/`continue` are in.
- (m1 only) additionally no spread args, no nested function declarations — widened in m2.

Everything failing the predicate keeps `compilable = nil` and runs the closure tree forever.
The predicate errs toward `nil`: any construct we have not explicitly transcribed and tested
is excluded.

**Does deltablue fit?** Per the coverability map, deltablue is constructor- and
method-heavy: plain-identifier params, `this.field = …` writes, method calls on `this`,
boolean logic, simple `if`/`for`. The map estimates ~97–99% of its functions are coverable
and observed **no** generators/`with`/`eval`/rest/labeled-break in the first 300 lines. This
is the central bet of the whole tier and m2 must **verify it directly** (see §6): if the
hot deltablue functions turn out *not* to be coverable, the tier cannot move its number and
we take the off-ramp.

---

## 6. Risks

- **Startup / closure count.** Only hot functions compile, and only on a background thread,
  so startup is unaffected — this is exactly the constraint `phase-25.md` §5 / PLAN §3.1
  imposed ("never COMPILE-per-function at load; 0.16–0.5 ms/fn → 10–25 s on big bundles").
  Confirmed: with `:threshold` mode the main thread never calls `cl:compile`; the `:eager`
  mode that *does* compile-at-definition is **debug-only** and never shipped on. Risk: low,
  by construction.
- **Correctness of source regeneration.** The real risk. Mitigation: aggressive fallback
  (§5), eager-compile shake-out + full G1 + differential (§4), and a hard rule that an
  un-transcribed/untested construct is excluded, not guessed.
- **Background-thread hazards.** Benign counter race, benign swap race (§3.3); `cl:compile`
  thread-safety and no captured thread-local FP/realm state (§3.4). Bound to one compiler
  thread to cap contention/memory. The genuine hazard is the shared IC-cell mutation window
  — eliminated in m1 by using **fresh** cells for compiled bodies.
- **Memory / compiled-code retention.** Each `cl:compile`d body is retained machine code
  plus its code component; it is never freed while the `js-function` is live. Only hot
  functions compile, so the count is bounded by the working set, not the bundle size. Risk:
  small for benchmarks; for long-lived processes add a cap on total compiled functions (LRU
  or simply stop compiling past a ceiling) — deferred past m4.
- **The tier may not help deltablue.** If deltablue's *hot* functions are dominated by
  property-dispatch cost that already lives inside `%ic-read`/`js-call` (which the tier does
  **not** speed up — it only removes the per-node `funcall` glue), then removing the glue may
  not reach 5×. m2 must measure the ceiling: eager-compile deltablue and see the number
  **before** building the async machinery in m3. If eager-compiled deltablue is still under
  5×, the background tier cannot beat it (it does strictly less compiling) — take the
  off-ramp (§7). This gate is the point of ordering m2 before m3.

---

## 7. Milestone plan (large — reconfirm after m1/m2)

Honest scope: this is several milestones and is arguably post-v1. The gate at the end of
**m2** is the decision point — it reveals the achievable ceiling with almost none of the
concurrency risk built yet.

| Milestone | Deliverable | How verified |
|---|---|---|
| **m1 — Source backend (tiny subset) + eager mode + differential harness** | `compile-source-*` backend covering: identifier/literal, local `frame-ref`/`frame-set`, member read/write via `%ic-read`/`%ic-write` (fresh cells), method + plain calls (no spread), arithmetic/comparison/logical ops, `if`, `while`, `return`. `compilable` predicate (§5, m1 tightness) + `:off`/`:eager`/`:threshold` switch. Prove **one** representative function (e.g. a deltablue accessor) compiles and runs identically. | Differential `:off` vs `:eager` byte-identical on a hand-written fixture set; the one target function's compiled body diffed against its closure output; **full test262 G1 pass-list unchanged (22,643)** under `:eager`. |
| **m2 — Widen subset to cover deltablue + measure the ceiling** | Add `for`/`do-while`, plain `try`/`catch`, `new`, object/array literals, nested member chains, unlabeled break/continue, `this`/reserved-slot reads. Confirm the **hot** deltablue functions are all coverable. Eager-compile deltablue, measure. | G1 pass-list unchanged under `:eager`; deltablue/richards/splay result checksums identical `:off` vs `:eager`; **eager-compiled deltablue timing recorded** — this is the ceiling. **Decision gate:** if ceiling < 5×, go to §7 off-ramp; else continue. |
| **m3 — Background tier-up + atomic swap** | `call-count` slot + `incf` in `jm-call`/`jm-construct`; tri-state `compilable`; lock-protected job queue; single dedicated compiler thread; CAS/atomic `compiled-body` publish. Main thread never blocks. | Stress test: N threads-of-work is single-threaded JS, but run the corpus with `:threshold T=1` (tier up almost immediately) and assert identical output to `:off`; ThreadSanitizer-style review of the swap; forced concurrent tier-up during a hot loop shows no torn body. G1 pass-list unchanged under `:threshold`. |
| **m4 — Measure + G1 + tune** | Tune `T`; optionally reuse warm IC cells (gated on a soundness check for the shared-mutation window); memory ceiling if needed. Record the deltablue number against the ≥5× gate (≤588 ms; `phase-25.md`). | `make bench` under `:threshold`; **deltablue ≥5× or the off-ramp is taken**; richards/splay non-regressed (still ≥5×); **G1 pass-list unchanged (22,643)**; soundness panel on the swap + cell-reuse path, 0 divergences. |

Total: four milestones, the last two of which carry the concurrency and tuning risk. The
operator should reconfirm after **m2** (ceiling known, minimal risk spent) whether m3/m4 are
worth it.

---

## 8. Fallback / off-ramp

If, at the m2 gate, **eager-compiled deltablue is still below 5×** — i.e. removing the
per-node `funcall` glue does not close the gap because the residual cost is inside the
shared runtime primitives (`%ic-read`, `js-call`, `setup-frame`) that the tier does **not**
change — then the background tier (m3/m4) cannot do better (it compiles a strict subset of
what eager mode already compiled) and building it is wasted risk. In that case the
recommendation is:

1. **Do not build m3/m4.** Keep the m1/m2 source backend behind `:off` (or drop it) — it has
   value as a validated second backend even if unshipped.
2. **Return to `phase-25.md` m10 option A:** accept G2 on the geomean/majority basis
   (richards 6.62×, splay 5.30×, geomean ≈5.1×), document deltablue at its best achieved
   number as the tree-walker holdout (`phase-25.md` §8.1), and proceed to the next phase.
   This is the pre-approved fallback and requires no new risk.

Equally, if at **m3** the background-thread correctness story cannot be made airtight (any
G1 regression or swap-race divergence that is not quickly closed), fall back to eager-only
(debug) or to option A. The tier is opt-in and bounded; abandoning it costs only the
milestones already spent, never conformance — because the interpreter path is always the
ground truth and `:off` is always available.
