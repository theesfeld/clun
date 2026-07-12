# Phase 07 — Module resolution & CJS/ESM loading

Objective (PLAN.md line 422): run real multi-file projects from `node_modules`.
Gate: resolution corpus green; a fixture app (ESM entry importing a CJS dep from
hand-placed `node_modules` with exports maps + a scoped package) runs.

This design distils a Plan-agent pass over the actual engine seams. Cited
`file:line` are anchors, not contracts.

## 0. Layering (per §3.6, line 301)

The Node resolution algorithm is a **standalone pure-CL library** (`src/resolver/`,
package `clun.resolver`, *no engine dependency*). Both the engine's ESM loader
hooks and the CJS `require` call it. The engine (`clun.engine`) owns module
records, linking, evaluation, and interop. The filesystem/path primitives the
resolver needs live in `clun.sys` (`src/sys/`), also engine-free.

```
clun.sys  (paths, fs, json)  ──►  clun.resolver  (Node algorithm)
                                        ▲
                                        │  calls
clun.engine  (module-record, loader, require, emitter clauses, interop)
```

## 1. `src/sys/` — path discipline + fs + JSON  (Milestone 1)

Every user-supplied path crosses `sb-ext:parse-native-namestring` /
`sb-ext:native-namestring` (§3.2, line 204: raw strings with `[` crash SBCL
pathname parsing). All raw-namestring use is confined to `src/sys/`; the CI
grep-gate flags it elsewhere.

- `src/sys/paths.lisp` — `native->pathname`, `pathname->native`, `path-join`,
  `path-dirname`, `path-basename`, `absolute-p`, `normalize` (collapse `.`/`..`
  lexically, no fs access). Package `clun.sys`.
- `src/sys/fs.lisp` — `path-exists-p`, `file-p`, `directory-p` (via `sb-posix:stat`,
  errno→nil), `realpath` (via `truename`, with a dangling-symlink handler →
  returns nil), `read-file-string` (UTF-8), `read-directory`. Engine-free.
- `src/sys/json.lisp` — a hand-rolled pure-CL JSON reader (§3.5) for
  `package.json`. Returns CL data: alists (string keys) for objects, vectors for
  arrays, strings, `double-float`, `t`/`:false`/`:null`. Shared with Phase 21.
  ~250 LOC; no engine JSON dependency (resolver must stay engine-free).

## 2. `src/resolver/` — Node resolution  (Milestone 2, the gate's bulk)

Pure functions over the `clun.sys` fs primitives. Entry point:

```lisp
(resolve specifier referrer-dir &key conditions type) ; -> (values abs-path format)
```

`format` ∈ `:esm :cjs :json :builtin`. `conditions` defaults to
`("node" "import")` for ESM callers, `("node" "require")` for CJS.

Algorithm (CommonJS + ESM merged, per Node's `LOAD_*`/`ESM_RESOLVE`):
- **Relative** (`./`, `../`) / **absolute** (`/`) → `LOAD_AS_FILE` (exact, then
  extension probing `.js .json .node→n/a .mjs .cjs`, honoring an explicit
  extension) then `LOAD_AS_DIRECTORY` (`package.json` `main`/`exports["."]`, then
  `index.*`).
- **Bare** (`pkg`, `pkg/sub`, `@scope/pkg`, `@scope/pkg/sub`) → walk
  `node_modules` up the directory chain; within a package apply `exports` (subpath
  patterns `./*`, conditions object, `null` blocks) or fall back to `main`/`index`.
- **Self-reference** (`import "mypkg/..."` from inside `mypkg`) via the nearest
  `package.json` `name` + `exports`.
- **`imports`** (`#foo` internal specifiers) resolved against the nearest
  `package.json` `imports`.
- **Format detection**: `.mjs`→`:esm`, `.cjs`→`:cjs`, `.json`→`:json`, `.js`→
  nearest `package.json` `"type"` (`module`→`:esm`, else `:cjs`).
- **realpath**: the resolved path is `truename`'d (symlink → real identity) so the
  registry dedups (§3.2, line 205). Preserve-symlinks is not a Bun default.

Conditions matching for `exports`/`imports`: ordered object keys, first match
wins; `default` last; nested condition objects; array fallbacks; `"."` and `"./x"`
subpaths; `*` pattern expansion. `null` target → "not exported" error.

Errors are `clun.resolver` conditions (`module-not-found`, `package-path-not-exported`,
`invalid-package-target`, …) carrying specifier + referrer; the engine maps them
to JS errors at the boundary.

## 3. Module record + graph  (Milestone 3)

New engine module `src/engine/modules/` (ASDF component after `eval`).

```lisp
(defstruct (module-record (:conc-name mr-))
  resolved-path format (status :unlinked) source ast
  environment namespace exports        ; ESM: frame, ns-object, name->binding
  (requested '()) (import-bindings '())
  cjs-exports eval-error)              ; CJS: live module.exports
```

Per-realm registry: add a `modules` slot to the realm struct
(`environment.lisp:38`), a hash keyed by **truename string** (dedup + cycle base
case). Accessors `realm-module` / `(setf realm-module)`.

**ESM pipeline** (two-phase, so cycles are spec-correct):
1. `load-module(spec, referrer)` — resolve → registry lookup (hit = cycle/dedup
   base case) → create+register `:unlinked` *before recursing* → read+parse →
   recurse over `import`/`export…from` sources into `mr-requested`.
2. `link-module(mr)` — DFS: build each module's Option-A frame (all top-level
   slots allocated, lexicals `+tdz+`); resolve every import binding to
   `(source-mr . export-name)`; wire export map. Link the whole SCC *before* any
   body runs → a cyclic read sees a hoisted-or-TDZ binding.
3. `evaluate-module(mr)` — post-order DFS; `:evaluating` guard short-circuits
   cycle back-edges; run the compiled body over the frame; capture a thrown value
   to `mr-eval-error` and re-throw on re-import.

## 4. Module environment = a frame (Option A)

A module's top-level scope is a frame (`simple-vector`), *not* the global object —
compiled like a function body (reuse the `compile-function-common` machinery,
`emitter.lisp:588`). Top-level `var`/function/`let`/`const` are slots (TDZ for
free). This keeps every module-local access a `frame-ref` (the engine's whole
design bet, §3.1).

**Imports as getter-thunks in slots.** An import slot holds a thunk; a use of an
imported name derefs it (`(funcall (frame-ref …))`). At link time the thunk closes
over the exporter's live slot ⇒ true live binding; a snapshot is the same shape
with the value captured. **Gate ships snapshot (🟡)**: the gate fixture is ESM→CJS
(no live bindings), and function/`const`/`class` exports are never reassigned, so
snapshot is observably identical for them. Upgrading to full live binding is a
one-line link-time change (thunk closes over slot, not value). Documented 🟡 in
the matrix; reassigned-`export let`-observed-cross-module is the only gap.

**Emitter changes** (minimal):
- `comp` gains `module` (the record being compiled, or nil) and `imports`
  (local-name → import descriptor) slots (`emitter.lisp:15`).
- `compile-identifier` (`emitter.lisp:165`): if the name is in `comp-imports` and
  resolves `:local`, emit a thunk-deref instead of a plain `frame-ref`.
- `compile-reference` setter for an import local → `throw-type-error`
  ("Assignment to constant variable"): imports are immutable bindings.
- Four `compile-node` clauses (`emitter.lisp` etypecase, currently CASE-FAILUREs
  on module nodes):
  - `import-declaration` → runtime no-op (`:normal`); real work is link-time.
  - `export-named-declaration` → with `declaration`: compile it (ordinary slot);
    with `specifiers`/`source`: no-op (link-time metadata).
  - `export-default-declaration` → bind the value into a reserved `*default*`
    slot; anonymous fn/class named `"default"`.
  - `export-all-declaration` → no-op; link-time splice of source's names.
- `compile-module-body` mirrors `compile-function-common`'s scope build minus
  `%this%`/`arguments`/params, plus import + `*default*` + `%import.meta%` slots.

## 5. CJS `require`  (Milestone 3)

CJS runs in sloppy script semantics inside the Node wrapper idiom
`(function (exports, require, module, __filename, __dirname) { … })`:
- Parse the `.cjs`/CJS-`.js` body with `:source-type :script` (a bare `import`
  there is a syntax error, as in Node).
- Synthesize a `function-node` with those 5 params + the body block; compile with
  the existing `compile-function-common` — the 5 names resolve `:local`, zero new
  emitter code, genuinely sloppy.
- `module` = fresh object; `module.exports` = fresh object; `exports` param
  aliases `module.exports`. Exported value = `module.exports` re-read after the
  body (a body may replace it).
- `require` = native fn closing over the referrer path → resolver → dispatch by
  format. Cache = the realm `modules` registry keyed by resolved path.
- **Cycle → partial exports**: set `mr-cjs-exports` to the fresh `module.exports`
  *before* running the body; a re-entrant `require` of an `:evaluating` module
  returns the current (partial) object.

## 6. Interop, JSON modules, import.meta  (Milestone 4)

- **import of CJS** = default export is `module.exports`; named imports =
  best-effort enumerable own keys (🟡). Synthesise a CJS record's ESM export map:
  `"default"`→`module.exports` + one named export per enumerable key. This is the
  gate's exact path.
- **require of ESM** → `throw-type-error` "require() of ES Module <path> not
  supported" (clear error, per matrix line 704).
- **JSON module** → read + `JSON.parse` (engine's JSON); default export = parsed
  value; no named exports.
- **import.meta** → per-module object in the reserved `%import.meta%` slot, built
  at instantiation: `url` (`file://` of resolved path), `dirname`, `filename`,
  `main` (`(eq mr entry-module)`).

## 7. Drive path  (Milestone 4)

- `run-source` branches on `source-type :module` → the loader path.
- New public `run-module-file (path &key realm) -> realm`: structurally like
  `run-source` (`eval.lisp:49`) — resolve entry → truename → `load-module` →
  `link-module` → `evaluate-module` → `drive-jobs` → `report-unhandled-rejections`;
  `unwind-protect` teardown (`teardown-coroutines` + `destroy-realm-loop`). Phase
  08's CLI calls this.
- Raw-source `-e` module: synthesise a record with `source` set + a synthetic
  resolved path so relative imports resolve against cwd.

## 8. test262 module tests

The exec runner currently **skips** `flags:[module]` tests. Keep skipping for the
Phase-07 gate (the gate is the fixture app, not a 262-module gate → protects
"zero regressions"). A follow-on task routes them through `run-module-file` to
*grow* the pass-list. Do not un-skip and re-skip in one phase.

## 9. Milestone order (each keeps `make build && make test` green)

1. `src/sys/` paths+fs+json — pure, unit-tested, no engine change.
2. `src/resolver/` + ~40-tree fixture corpus (engine-free parachute) — the gate bulk.
3. Realm `modules` slot + `module-record` + registry + `load/link/evaluate`
   skeleton for JSON + CJS (CJS reuses `compile-function-common`; no emitter change).
4. Emitter module context + `compile-module-body` + four clauses + import
   deref/const → ESM-imports-ESM unit test.
5. Interop, `import.meta`, `run-module-file`, `run-source` branch → the gate
   fixture app.
6. Gate + adversarial review panel + STATE/DECISIONS + commit.

## 10. Review-panel outcome (2026-07-11)

A 6-dimension adversarial panel (24 agents, each finding verified by running code)
surfaced 17 confirmed correctness bugs (1 self-refuted), all fixed + locked as
regression tests. Notable divergences the initial implementation had from Node:

- **exports subpath patterns** must order by BASE (pre-`*`) length, then total
  length (Node PATTERN_KEY_COMPARE) — not total length alone (was order-dependent).
- A **bare-specifier target is legal only under `imports`**, not `exports` (threaded
  an `is-imports` flag); a `.`/`..` consumer subpath is rejected (invalidSegmentRegEx)
  so a `./*` export can't be escaped via `pkg/../secret`.
- **JSON reader**: an overflowing magnitude coerces to ±Infinity (exact-rational
  parse) rather than aborting the whole package.json; strict number grammar; a
  duplicate key keeps the LAST value at the FIRST position.
- **CJS**: top-level `this` === `module.exports` (Node invokes the wrapper via
  `.call(module.exports, …)`); a throwing module is EVICTED from the cache.
- **Interop**: `import { default as X }` from JSON/CJS binds the whole value; a
  non-`default` named import from JSON is a link SyntaxError.
- **ESM early errors** (were raw Lisp crashes or silent last-wins): `export
  {undeclared}`, duplicate exported name, duplicate `export default`, duplicate
  import binding all throw clean SyntaxErrors.
- **`export default function foo(){}` / `class C {}`** also bind a usable local
  `foo`/`C`; anonymous `export default function(){}` (+`async`/`*`) parses.

## 11. Top risks (pre-implementation)

1. **Live bindings vs closure-slot architecture** → getter-thunk-in-slot; ship
   snapshot 🟡, upgrade is a one-liner.
2. **Cycle correctness across the two-phase split** (link-all-then-evaluate; CJS
   partial exports) → register-before-recurse; `:evaluating` guards; dedicated
   cycle fixtures (ESM↔ESM and ESM↔CJS).
3. **Path identity via `truename`** — two specifiers to one file must collapse to
   one registry key or cycles/double-eval break → all fs through `src/sys/` with a
   dangling-symlink handler; grep-gate raw namestrings outside `src/sys/`.
