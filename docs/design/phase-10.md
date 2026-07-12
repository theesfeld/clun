# Phase 10 — RegExp

Objective (PLAN.md §3.1, line 452): working RegExp for real-world code, honestly
scoped. Approach is FIXED: own JS-regex parser → own AST → **CL-PPCRE parse trees**
→ `cl-ppcre:create-scanner`. Documented gaps ERROR LOUDLY (JS SyntaxError), never
silently mismatch. Distilled from a Plan-agent pass; cited `file:line` are anchors.

## 0. Layout + wiring

`src/engine/regex/` (package `clun.engine`, `(:pp :cl-ppcre)` nickname), 4 files:
`ast.lisp` (JS-regex AST structs), `parser.lisp` (recursive descent + 2-pass group
count), `translate.lisp` (AST → PPCRE parse tree + JS-vs-PPCRE fixes + loud gaps),
`regexp-object.lisp` (js-regexp struct, ctor/proto/@@methods/getters, exec/test).
ASDF: `cl-ppcre` added to `:depends-on`; regex module after `builtins-string`, before
`builtins-array`. `%bootstrap-regexp` called in `make-realm` after string-extra. Lexer:
add `d` to the allowed flag set (else `d`-flagged tests lex-error). Add `:match-all`
well-known symbol + `Symbol.matchAll`.

## 1. AST (regex/ast.lisp)

Structs: rx-disjunction(alternatives), rx-alternative(terms), rx-char(code), rx-dot,
rx-class(negated items), rx-class-range(lo hi), rx-class-esc(kind), rx-esc(kind:
:digit/:non-digit/:word/:non-word/:space/:non-space), rx-group(kind index name body),
rx-backref(index name), rx-anchor(kind: :start/:end/:word-boundary/:non-word-boundary),
rx-look(dir sense body), rx-quant(atom min max greedy). `rx-char` holds a code unit
(0..#xFFFF) so surrogates are explicit. `\p{}` is NOT represented — parser throws.

## 2. Parser (regex/parser.lisp)

`(parse-js-regex pattern flags) → (values disjunction group-count name-alist)`.
Recursive descent over the code-unit string; malformed → `throw-syntax-error` (→ JS
SyntaxError at literal-compile / `new RegExp`). **Two passes**: pass 1 counts
capturing `(` (not `(?…` except `(?<name>`) + collects names (for backref validation +
octal-vs-backref). Annex-B quirks: a `{` that isn't a valid quantifier is literal;
leading `]` in a class is literal; `-` at class edges literal; `\b` in a class =
backspace; `\1..\9` = backref iff ≤ group-count else octal; `(?:` `(?=` `(?!` `(?<=`
`(?<!` `(?<name>`; `\k<name>`; `\c` control; `\xHH` `\uHHHH`; `\u{…}` u-flag only;
duplicate named group → SyntaxError. Surrogates without u = two independent code units.

## 3. Translate (regex/translate.lisp) — the crux

`(translate-regex disjunction group-count name-alist flags) → parse-tree`. Node map +
the JS-vs-PPCRE fixes (PPCRE would silently differ — verified in vendor/cl-ppcre):
- **`.`** (no s) → `(:inverted-char-class #\Newline #\Return #  # )`; with s →
  `:everything` (scanner `:single-line-mode t`).
- **`\s`/`\S`** → explicit `(:char-class …JS-whitespace…)` / inverted (PPCRE's
  whitespace class is only 5 chars — wrong). JS set = 09 0A 0B 0C 0D 20 A0 1680
  2000–200A 2028 2029 202F 205F 3000 FEFF.
- **`\w`/`\W`** → explicit ASCII `[A-Za-z0-9_]` / inverted (PPCRE's is Unicode — wrong).
- **`\d`/`\D`** → `:digit-class`/`:non-digit-class` (matches JS `[0-9]`).
- **`^`/`$`** (no m) → `:modeless-start-anchor` / `:modeless-end-anchor-no-newline`
  (JS `$` doesn't match before a trailing `\n`); with m → `:start-anchor`/`:end-anchor`.
- **`\b`/`\B`** → `:word-boundary`/`:non-word-boundary` (PPCRE uses Unicode word-chars;
  non-ASCII `\b` divergence is a documented gap — ASCII is correct).
- flags: i→`:case-insensitive-mode`, m→`:multi-line-mode`, s→`:single-line-mode`; g/y
  drive exec/lastIndex (not the tree); u affects only parsing.
- groups → `:register` / `:named-register` (auto-number matches JS left-paren order);
  backref → `(:back-reference n)` (1-based); named backref resolved via name-alist.
- **unparticipated-group backref fix** (§3.1 "fix earliest"): translate a backref to a
  `(:filter …)` closure that reads `cl-ppcre::*reg-starts*` and matches empty when the
  register didn't participate (JS semantics; PPCRE's plain back-reference fails). The
  ONE deliberate `cl-ppcre::` internal touch — documented in DECISIONS; guarded in one
  function + unit-tested (`(a)?\1`).
- **loud gaps** (`throw-syntax-error`): variable-length lookbehind (compute body
  min/max; PPCRE is fixed-length only), `\p{…}`/`\P{…}`, astral-requiring `u`
  constructs, any unmappable node.

## 4. RegExp object (regex/regexp-object.lisp)

`(defstruct (js-regexp (:include js-object (class :regexp))) source flags scanner
name-alist group-count flag-bits)`. `lastIndex` is a writable non-enum non-config data
property (normal object path). Constructor `RegExp(pattern, flags)` incl. copy +
flag-override + the `RegExp(re)`-returns-same when called as a function. `compile-regexp`
(rewrite emitter.lisp:208): parse+translate ONCE (memoized on the node), allocate a
fresh js-regexp per eval (ES fresh-object-per-eval). Prototype: exec (build result
array w/ index/input/groups; sticky = require match-start=lastIndex; g|y advance
lastIndex; failure resets to 0), test, toString (`/source/flags`), `@@match`/
`@@matchAll`/`@@replace`/`@@search`/`@@split`, getters source/flags/global/ignoreCase/
multiline/dotAll/sticky/unicode/hasIndices (brand-checked). **`d`/indices**: accept the
`d` flag + `hasIndices` getter; populate `result.indices` if time permits (cheap from
`reg-starts/reg-ends`), else documented-deferred.

## 5. String integration (builtins-string.lisp)

`match/matchAll/replace/replaceAll/split/search` coerce a non-RegExp arg + delegate to
the RegExp `@@`-method (spec). Re-install the six String methods from `%bootstrap-regexp`
(RegExp bootstraps after String) with delegating wrappers that keep the string path as
fallback. `replaceAll` throws TypeError on a non-global RegExp. `%regexp-get-substitution`:
`$$ $& $\` $' $n $<name>`; function replacers get `(matched, cap1..capN, offset, string,
groups?)`.

## 6. UCD generator — scaffold only

`scripts/gen-unicode-tables.lisp` skeleton; `\p{}` errors loudly. No tables consumed
in Phase 10.

## 7. Gate + vendoring

Vendor `built-ins/RegExp/**` (1879 files) from `/tmp/test262-clone@d1d583d` into
`vendor-data/test262/test/built-ins/RegExp/` (runner discovers `built-ins/**` under
`CLUN_EXEC`). Skip-features: keep `\p{}` (regexp-unicode-property-escapes), regexp-v-flag,
regexp-modifiers, regexp-duplicate-named-groups skipped; RUN named-groups/lookbehind/
dotall/sticky/unicode. Measure RegExp slice pass-rate = passing `built-ins/RegExp/`
entries / run-and-not-skipped RegExp files. `tests/conformance/regexp-gaps.txt` (sorted,
only-grows, `#reason:` comments) enumerates the deliberate failures by gap. Gate:
RegExp ≥60%, String regex methods ≥75%, zero exec-passlist regressions.

## 8. Milestones (green after each)

M1 wiring+bootstrap stub (cl-ppcre dep, :pp, `d` flag, `:match-all`, bare RegExp). M2
parser+AST + unit tests. M3 translate+scanner+compile-regexp. M4 RegExp object breadth.
M5 String delegation + templates. M6 vendor+gate+expectations. Review panel + commit.

## 9. Honest v1 scope + risks

**Scope:** u-flag = BMP-only (astral constructs → loud SyntaxError); `d`/indices =
flag accepted, indices array deferred; `\p{}` = loud error + scaffold UCD. **Risks:**
(1) PPCRE semantic drift (\s/\w/./$/\b) — explicit char-classes + a property test;
(2) the backref `:filter` reaching a `cl-ppcre::` internal — guarded + documented +
fallback-to-gap; (3) u-flag depth — minimal BMP, loud on astral. All gaps in
`regexp-gaps.txt`; nothing silently mismatches.
