# Phase 09 — TypeScript type-stripping

Objective (PLAN.md line 443, §3.3): `.ts` runs by erasing type syntax to
exact-length whitespace (line **and** column preserved, no sourcemaps); non-erasable
syntax errors like Node's `ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX`. `.ts/.mts/.cts` only;
`.tsx` rejected. Distilled from a Plan-agent pass; cited `file:line` are anchors.

## 0. Approach — a strip *scanner*, not a peephole and not a TS parser

A pure token peephole can't place `:`/`<`/modifiers (context-sensitive); a full TS
parser is overkill (we never type-check). The stripper is a **reentrant
recursive-descent scanner over the shared `clun.engine` token stream** that (1) drives
the lexer exactly as the parser does, (2) tracks just enough JS structure to locate
type positions, (3) skips balanced type expressions, and (4) records erase-spans,
rendered by copying the source and space-filling each span (newlines kept). It
**errors loudly** wherever the heuristic is uncertain — never silently mis-strips.

`src/transpiler/` (package `clun.transpiler`, loads after the engine module):
- `conditions.lisp` — `unsupported-ts-syntax` (message + line + col + path).
- `ts-type.lisp` — the balanced type-expression skipper (`skip-type`) + `<…>`
  type-args disambiguation, with `>>`/`>>>`/`>=` over-close splitting.
- `ts-scan.lisp` — `advance-tok` (the lexer driver) + the JS-structure tracker that
  finds type positions and calls the skipper.
- `strip.lisp` — public `strip-types (source path) -> stripped-string` + the
  erase-plan renderer.

## 1. The lexer driver (make-or-break) — `advance-tok`

The lexer defaults `/`→divide and needs parser context for regex/templates. The
scanner replicates both via the lexer's own `reread-regexp`/`reread-template`:

- **regex-vs-divide:** track `prev-tok` (last significant token). A `/`/`/=` is a
  regex iff a `/` there begins an expression — i.e. `prev-tok` is nil or a punct
  other than `) ] } ++ --`, or a regex-preceding keyword (`return typeof delete void
  in instanceof do else yield await case new`). Else divide. Regexes are never type
  positions but MUST be re-lexed or offsets desync.
- **template `${}`:** a `tmpl-stack` of per-substitution net-brace-depth ints. On a
  `:template` head/middle → push 0. Inside a substitution: `{`→inc top, `}`→ if top>0
  dec else pop + `(setf lexer-pos (1+ start))` + `reread-template` (push 0 again if
  the continuation is `:middle`).

Every rule reads tokens only through `advance-tok`, so the scanner sees the same
stream the parser will see on the stripped output.

## 2. Type-position recognition

**`skip-type`** consumes a full type and returns its end, counting `() [] {} <>`
delimiters and staying in "type mode" across `| & => extends ? :` (conditional
types), `typeof/keyof/infer`, literal types, `import("…")` types, template-literal
types. `>>`/`>>>`/`>=`/`>>=`/`>>>=` close *N* `<` when angle-depth ≥ N, splitting the
punct if it over-closes (the residual `=`/`>` stays as JS). Terminates at a balanced
type terminator (`) ] } , ; = =>` / EOF); errors on depth underflow.

Erase spans:
- `: Type` in var/let/const declarators, params, return type, class fields, `catch`.
- optional `?` before `:`/`,`/`)` in a param/field position (single char).
- decl generics `<T,U extends V=W>` after a function/class/interface/type name; arrow
  generics `<T,>(x)=>…`; call/`new` type-args `foo<T>(…)`/`new Foo<T>()`.
- `as`/`satisfies Type` (contextual keyword in expression tail).
- postfix `!` (`x!`, `x!.y`, `f()!`) — distinguished from prefix `!x` by `prev-tok`.
- `interface X …{…}` (whole); `type X … = …;` (whole).
- `declare …` (whole ambient decl); `abstract`/`public`/`private`/`protected`/
  `readonly`/`override` (keyword span only — whitespace untouched, so column holds).
- `import type …`/`export type …` (whole); inline `{type A, B}` (the `type A` + one
  adjacent comma).
- `class C implements I, J` (the `implements` clause).
- bodyless overload signatures (whole line).

**The `<` ambiguity.** Treat `<` as type-args only when: (a) `prev-tok` is a callee
(identifier/`)`/`]`), (b) a balanced `<…>` reaches a `>` immediately followed by `(`
or a template, and (c) the content scans as a type list (idents, `.`, `,`, nested
`<…>`, `[]`, `| &`, literals). Else it's less-than (kept). Angle-bracket casts
`<T>expr` → **error** (amaro parity; only `as` erases). Accepted corner: a genuine
`a<b>(c)` chained comparison-call is mis-stripped (same corner SWC/Babel accept); the
common `a < b` is never mis-stripped.

## 3. Error catalog → `unsupported-ts-syntax` (Node-style msg + line:col)

enum/`const enum`; `namespace`/`module` with **runtime** code (type-only namespaces
erase); parameter properties (accessibility/`readonly` on a constructor param);
`import x = require()` / `export =`; **all** decorators (`@` — pre-scanned, else the
lexer lex-errors on `@`); angle-bracket cast; `.tsx`. Surfaced at the loader boundary
as a JS `SyntaxError` carrying line:col (`throw-syntax-error`). Enum-error is the
documented 🟡 vs Bun (which transpiles enums).

## 4. Position preservation

Render: copy the source into an equal-length string; for each erase span set each
char to `#\Space` **except** line terminators (10/13/2028/2029). Length identical +
newlines preserved ⇒ every surviving token keeps its exact offset, line, and column
(col = start − line-start). A post-strip parse error / thrown line:col therefore
equals the `.ts` source position — the whole point, no sourcemaps.

## 5. Loader wiring

Engine owns a pluggable hook (avoids a compile-time engine→transpiler dependency):
`(defvar clun.engine:*ts-strip-hook* nil)` — the transpiler `setf`s it at load. A
`read-source-for (path)` helper reads the file and, for `.ts/.mts/.cts` with a hook
installed, strips it. Both source-read sites call it: `esm-load`
(`module-loader.lisp:74`) and `run-cjs-body` (`require.lisp:23`). The CLI
(`main.lisp`) rejects `.tsx` before reading and lets `.ts/.mts/.cts` fall into the
normal run path. Resolver: `detect-format` gains `.mts`→:esm, `.cts`→:cjs; `.mts`/
`.cts` added to `*extensions*` (resolve.lisp). Strip errors map to JS SyntaxError.

## 6. Corpus + harness

`tests/ts/{strip,errors,runtime}/` — ≥60 authored pairs (no vendored amaro → no
license issue). `strip/<case>.ts` + `<case>.expected.js` (byte-exact, same length);
`errors/<case>.ts` + `<case>.error` (message + line:col); `runtime/<case>.ts` +
`.out`/`.exit` (strip→run→stack line:col, via the existing JS harness which already
lists `.ts`). New in-image comparator `scripts/run-ts-strip.lisp` (byte-exact +
same-length invariant + error assertions) + parachute `ts-strip-tests` for skipper
edges; both wired into `make test`.

## 7. Milestones + risks

M1 scaffold+wiring+identity strip (serial); M2 lexer driver + fidelity test (serial);
M3 type skipper + `:`/decl-generics/`as`/`!` (serial); M4 statement erases (fan-out);
M5 error catalog (fan-out); M6 corpus (max fan-out). Green after each.

Top risks: (1) `<` disambiguation mis-strip — strict following-`(` + type-list check,
error on angle-casts, big adversarial corpus; (2) lexer-driver desync — M2 fidelity
test before any erasure, reuse the engine's own reread functions; (3) `>>` over-close
splitting — explicit unit tests. Accepted corners documented; loud failure over
silent mismatch is the governing principle. Class **field** annotations strip, but
field syntax stays a downstream parse error until the class-fields phase (documented).
