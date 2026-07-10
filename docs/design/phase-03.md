# Phase 03 — Core evaluator + object kernel

Objective: run ES5-ish code in both strict and sloppy modes; the conformance runner goes from
parse-only to **execution**. This is the heart of the engine. Spec: ECMA-262 §6 (values), §9-10
(objects, environments), §13-14 (expressions/statements), §19-20 (fundamental objects). Blueprint:
cl-js jsos.lisp/translate.lisp (Appendix C.15) — closure compilation + struct objects.

## 1. Execution model — compile analyzed AST → CL closures (§3.1)

Each AST node is compiled ONCE to a CL closure; the closure is then called with a runtime
environment. No per-node dispatch at run time, and no `COMPILE` per function (Appendix C.3: 0.16-0.5
ms/fn is too slow). Two closure shapes:

- **expression closure**: `(lambda (env) …) → js-value`.
- **statement closure**: `(lambda (env) …) → completion` (see §5).

The emitter carries a **compile-time lexical environment** (ctenv) — a chain of scope records, each
mapping names → slot indices — and resolves every identifier reference at compile time to one of:
local `(depth . index)`, `global` (a property of the global object), or `dynamic` (a name that must
be looked up at run time because a `with` or direct `eval` scope is in the chain). Pre-resolved refs
compile to `(lambda (env) (frame-ref env depth index))`; dynamic refs compile to a run-time scope
walk. This keeps the common case allocation-free and fast while still supporting `with`/eval.

## 2. Object kernel (`src/engine/objects.lisp`)

Builds on the Phase 01 `js-object` base struct. Every object is a struct; NEVER a hash-table-per-
object (Appendix C.12: 4×/2.7× win). `js-object` gains slots: `shape/props` (property storage, §3),
`proto` (the [[Prototype]], a js-object or +null+), `extensible` (bool), and `class` (a keyword tag:
`:object :array :function :error :arguments :boolean :number :string …` for `[[Class]]`/brand).

### Internal methods — the spec protocol, struct-dispatched (Proxy-shaped)

The [[…]] internal methods are **CLOS generic functions dispatching on the object's struct type**
(SBCL structs are classes, so this is genuine struct dispatch): `jm-get-own-property`, `jm-define-own-
property`, `jm-get`, `jm-set`, `jm-has-property`, `jm-delete`, `jm-own-keys`, `jm-get-prototype-of`,
`jm-set-prototype-of`, `jm-is-extensible`, `jm-prevent-extensions`, and for callables `jm-call`,
`jm-construct`. Ordinary objects use the default (Ordinary*) methods (§10.1); exotic objects (Array,
arguments, function, String wrapper) `:include` `js-object` and override only the methods they change
(Array overrides define-own-property for `length`; arguments overrides get/set/etc. for the mapped
case; functions add call/construct). This is exactly the shape Proxy will slot into post-v1.

The user-facing abstract operations `Get(O,P)`, `Set(O,P,V,Throw)`, `GetV`, `CreateDataProperty`,
`DefinePropertyOrThrow`, `HasProperty`, `GetMethod`, `Call`, `Construct` are plain functions built on
the generic internal methods.

### Property descriptors & storage (§3)

`property-descriptor` struct: `value get set (writable :unset) (enumerable :unset) (configurable
:unset)` where `:unset` distinguishes "absent" from "false" (needed for [[DefineOwnProperty]]'s
descriptor merging, §10.1.6.3 ValidateAndApplyPropertyDescriptor). A data descriptor has value/
writable; an accessor descriptor has get/set. `IsDataDescriptor`/`IsAccessorDescriptor`/
`IsGenericDescriptor` classify.

Storage: per §3.1 a small **simple-vector** of alternating `key desc key desc …` (preserves insertion
order — needed for OwnPropertyKeys ordering) that **promotes to an `equal` hash-table** past a
threshold (~8 keys). Integer index keys and string keys and symbols coexist; OwnPropertyKeys returns
integer indices in ascending numeric order, then strings in insertion order, then symbols
(§10.1.11.1 OrdinaryOwnPropertyKeys). Property keys are normalized via ToPropertyKey → either a string
(canonical) or a js-symbol.

### Array exotic

`js-array` `:include`s `js-object`; dense storage is an adjustable `(vector js-value)` plus the sparse
overflow going to the ordinary property table (holes = a sentinel). `length` is a computed exotic data
property; [[DefineOwnProperty]] enforces the length/index invariants (§10.4.2). Fast paths for dense
integer get/set; slow path falls back to Ordinary.

## 3. Environment & frames (`src/engine/environment.lisp`)

A runtime **environment** is a struct `{ slots : simple-vector, parent : environment-or-nil }` (an
"environment record" flattened to a vector). `frame-ref`/`frame-set` walk `depth` parents then `aref`
`index`. TDZ: let/const slots are initialized to a unique `+tdz+` sentinel; reading it → ReferenceError
(§6.2.4). Function scope pre-fills `var`/function-declaration slots (hoisting) — `var` to `undefined`,
function decls to their closure at scope entry. `this`, `new.target`, and the home-object for `super`
live in dedicated frame slots of the nearest function environment; arrows resolve them up the chain.

The **global environment** is special: its "slots" are properties of the global object, so top-level
`var x`/`function f` become properties of `globalThis` (§9.1.1.4), and unresolved bare references go
through the global object's [[Get]] (→ ReferenceError if absent). `with`/direct-`eval` scopes are
**object/declarative slow frames** consulted by name at run time (the `dynamic` ref path from §1).

## 4. Functions

A `js-function` `:include`s `js-object` and carries: the compiled body closure, the captured
environment, the parameter info, `strict`, `this-mode` (`:lexical` for arrows, `:strict`, `:global`),
and `home-object`. `[[Call]]`: allocate a fresh frame, bind `this` (strict → as passed; sloppy → the
passed value ToObject'd, or globalThis if nullish), bind arguments + the `arguments` object (sloppy →
mapped/aliased to the simple parameters, §10.4.4; strict → unmapped), run the body closure, translate
the completion (`return` → value, normal → undefined). `[[Construct]]`: make an ordinary object whose
proto is the function's `prototype.prototype`, run with `this` = that object, return the object unless
the body returns an object. Built-in functions wrap a CL lambda (a `native-function`).

## 5. Completions & control flow (emitter, `src/engine/emitter.lisp`)

Statement closures return a **completion**: `:normal` / `(:return . value)` / `(:break . label)` /
`(:continue . label)` / `(:throw …)`. Rather than allocate completion records on the hot path, non-
local control flow uses CL `catch`/`throw` with per-construct tags: a loop establishes `catch` tags
for its (labelled) break/continue; `return` throws to the function's return tag; `throw` uses the
Phase 01 `js-condition` bridge (so it unwinds `unwind-protect`/`finally` correctly). `try/finally` is
CL `unwind-protect`; `catch` is `handler-case` on `js-condition`. Labels attach to the tag set.

The emitter compiles:
- expressions: literals, identifiers (resolved refs), `this`, member (dot/computed), call, new,
  tagged template, unary/update, binary/logical (via §6 operators), assignment (+ compound +
  destructuring targets), conditional, sequence, array/object literals (incl. spread, getters/
  setters, computed keys, `__proto__`), function/arrow expressions, template literals.
- statements: expression, block (new declarative frame), if, for/for-in/for-of (for-in key order =
  OwnPropertyKeys of the chain, §14.7.5.9), while/do-while, switch, try/catch/finally, throw, return,
  break/continue (labelled), labelled, var/let/const (TDZ + init), function declaration (hoisted),
  with, empty, debugger. `class` declarations are ES2015 but land here minimally (constructor +
  methods + extends) since the object kernel is present.

## 6. Operators (`src/engine/operators.lisp`)

Built on the Phase 01 coercions: `js-add` (§13.15.3 — string concat vs numeric via ToPrimitive),
`js-eq`/`js-strict-eq` (the abstract equality table §7.2.15/16), relational `< > <= >=`
(ToPrimitive number hint, string vs numeric), `js-typeof`, `js-instanceof` (@@hasInstance /
OrdinaryHasInstance), `js-in`, `delete` (Reference semantics), bitwise/shift (ToInt32/ToUint32 from
Phase 01). Assignment targets are compiled to a `reference` (a get/set closure pair) so `+=`, `++`,
and destructuring share one path.

## 7. Realm & intrinsics (`src/engine/realm.lisp`)

A `realm` struct holds the **intrinsics table** (per-realm indirection designed in from the start,
§3.1: `%Object.prototype%`, `%Function.prototype%`, `%Array.prototype%`, `%Error.prototype%`, …) and
the global object. Bootstrapping order matters (Function.prototype and Object.prototype are mutually
referential). For the Phase 03 gate the realm wires up enough to run the test262 harness and the
curated slice: `Object` (+ defineProperty/getOwnPropertyDescriptor/getPrototypeOf/keys/create/
freeze…), `Function.prototype` (call/apply/bind), `Array` (+ isArray, prototype push/…), `Boolean`,
`Number`, `String` (wrapper + a few prototype methods), `Error` and the native error subclasses with
`.stack`, `Symbol` (iterator/toPrimitive/hasInstance well-knowns — enough for the protocol), plus the
globals `globalThis`, `undefined`, `NaN`, `Infinity`, `parseInt/parseFloat/isNaN/isFinite`. Full
stdlib breadth is Phase 04; Phase 03 does the minimum to clear 70% of the curated slice. Everything is
implemented in CL against the object API (purity contract) — no JS in the implementation.

## 8. Conformance runner → execution (`scripts/test262.lisp`)

Per INTERPRETING.md: prepend `harness/sta.js` + `harness/assert.js` (unless `raw`), then each file in
`includes:`, then the test source; run in a fresh realm. `flags`: `onlyStrict`/`noStrict` select
mode(s) (default = run BOTH); `[module]`/generators/async are OUT for Phase 03 (skipped — they land in
Phase 06). A positive test passes iff it runs without throwing an uncaught error (`Test262Error` or
otherwise); a `negative` (phase runtime/… ) test passes iff it throws the declared error type. The
pass-list grows onto executed tests; `make conformance` stays regression- and crash-gated.

**Gate:** curated `language/` slice (minus generators/async/modules) executes ≥ 70% in BOTH modes;
zero pass-list regressions; zero crashes.

## Risks & sequencing

- Object-model correctness (DefineOwnProperty descriptor merging, Array length invariants) is the
  classic source of subtle bugs → dense parachute unit tests before wiring into the emitter.
- `this`/`arguments`/sloppy aliasing and strict-vs-sloppy divergence are error-prone → both modes
  tested from the first executing program.
- Scope resolution (TDZ, hoisting, with/eval dynamic path) → unit-test the ctenv resolver directly.
- Build order: objects → environment → operators → emitter (expressions) → functions → emitter
  (statements) → realm/intrinsics → harness/runner → measure → iterate to 70%. Expect multiple
  milestones; each keeps `make build/test/purity/conformance` green.
