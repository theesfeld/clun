# Phase 02 — Lexer + parser + scope analysis

Objective: source → analyzed AST. The lexer doubles as the TS-strip lexer (§3.3), so it must have:
exact token offsets, parser-driven regex-vs-divide, a template mode stack, trivia retention, and no
global state. Spec: ECMA-262 §12 (lexical grammar), §13-16 (expression/statement/module grammar),
§8.x (early errors / static semantics). Reference (behavior, not structure): parse-js tokenize.lisp,
cl-js translate.lisp (Appendix D).

## Scope of "ES2017-ish" for parsing (§3.1 tier)

Support: all ES2015 syntax (classes, destructuring, arrows, generators, modules, spread, computed
props, template literals, `for-of`, default/rest params), ES2016 `**`, ES2017 async/await; plus the
cheap ES2018/2019 additions (object rest/spread, async generators / `for-await`, optional catch
binding, trailing commas). BigInt literals lex now (values Phase 11).

Deliberately NOT parsed in v1 (the test262 runner **skips** tests whose `features:` name them; the
parser must still never crash — a clean SyntaxError is acceptable): class fields (public/private),
private methods, decorators, top-level await, dynamic `import()`, `import.meta`, import
assertions/attributes, source-phase imports, numeric separators, logical-assignment (`&&= ||= ??=`),
nullish `??` / optional chaining `?.`, explicit resource management (`using`), RegExp `v` flag.
(Several are post-ES2017; keeping them out holds the tier line — Appendix A tracks this.)

## Tokenizer (`src/engine/lexer/`)

**Reentrant**: all state in a `lexer` struct (source string, position, line, a template/paren depth
stack, the last significant token type). No specials.

`token` struct: `type` `value` `start` `end` `line` `col` `nl-before` (a LineTerminator occurred in
the trivia before this token — drives ASI) and, for templates, `cooked`/`raw`/`tail?`.

Token `type` keywords: `:name` (identifiers AND keywords — keyword-ness is contextual, decided by the
parser), `:punct`, `:string`, `:num`, `:bigint`, `:regexp`, `:template`, `:eof`. Numbers cook to
`double-float` (via Phase 01), strings/templates cook to code-unit strings with all escapes
(`\x`, `\u{}`, `\u`, line continuations, legacy octal in sloppy only). `raw` retained for templates
and regexp.

**regex-vs-divide** — parser-driven re-scan. The lexer scans `/` as a `:punct` (`/` or `/=`) by
default. When the parser is in a position where a primary expression is expected, and the current
token is that `/` punct, it calls `(reread-regexp lexer)` which rescans from the `/`'s start as a
regexp literal. The parser knows its grammatical position, so this is exact (Acorn's model). Avoids
the brittle "previous token type" heuristic.

**template mode stack** — reading `` ` `` produces a template head up to the first `${` (tail? = nil
if it stopped at `${`, t if it closed at `` ` ``). The parser parses the substitution expression,
then on the closing `}` calls `(reread-template lexer)` to resume: it reads the middle/tail. A depth
stack distinguishes a `}` that closes a substitution from an ordinary `}`.

**trivia** — whitespace and comments are skipped for token production but their spans/newlines are
tracked; `nl-before` is set from them. Comment spans are collected in the lexer (`comments` list) for
the TS stripper (Phase 09) and for `html-like` / `#!` shebang handling. Exact offsets always.

**Gate: token-span property** — for any source, `(subseq src (token-start tok) (token-end tok))`
equals the token's raw lexeme for every token. Verified over a generated + test262 sample.

## AST (`src/engine/ast.lisp`)

Typed structs via a `defnode` macro: a base `node` with `start`/`end`, each kind an `:include`d
struct with its own slots. `etypecase`/`typecase` dispatch in analyzer/printer/emitter (Phase 03).
~60 node kinds (Program, Identifier, Literal, TemplateLiteral, Array/ObjectExpression, Property,
Function/Arrow/Class, Unary/Binary/Logical/Assignment/Update/Conditional/Sequence/Spread,
Member/Call/New/Tagged, all Statements, VariableDeclaration/Declarator, patterns
Array/Object/Assignment/Rest, Import/Export specifiers). ESTree-ish names for familiarity; not
required to match ESTree exactly.

## Parser (`src/engine/parser/`)

Reentrant recursive descent (state in a `parser` struct: lexer, `current`, `lookahead`, strict flag,
context flags `in-function`/`in-iteration`/`in-switch`/`allow-yield`/`allow-await`/`in-parameters`).
Expressions use precedence climbing (Pratt) for binary/logical operators; assignment/conditional/
unary/postfix/member/call/primary are recursive-descent. Arrow functions are detected by parsing a
parenthesized expression then, on seeing `=>`, **reinterpreting** the cover grammar as a parameter
list (CoverParenthesizedExpressionAndArrowParameterList / cover for object-literal-vs-pattern). Every
error is a `js-native-error :syntax-error` via the Phase 01 bridge — **never a Lisp crash**.

Strict AND sloppy: strict is entered by a `"use strict"` directive prologue or `[module]`/class
bodies; it changes reserved words (`implements` etc.), octal literals, `with`, duplicate params,
delete-of-name, assignment-to-eval/arguments. Early errors (static semantics) that the negative-parse
tests exercise are checked at parse time: invalid assignment/destructuring targets, duplicate lexical
bindings, `new.target` outside functions, `return`/`break`/`continue`/`yield`/`await` in wrong
contexts, label errors, `for` binding errors, etc.

## Scope analyzer (`src/engine/analyzer/`)

A post-parse pass: per-scope var/lexical binding tables, hoisting (var + function), let/const slot
indices, TDZ markers, and flags (`uses-eval`, `uses-with`, `uses-arguments`, strictness). Frames are
simple-vectors (Phase 03 consumes the slot indices); `with`/direct-eval scopes are marked for
hash-backed slow frames. Kept a distinct pass so it is independently testable.

## AST printer (`src/engine/ast-printer.lisp`)

A structural dumper (S-expression form) for debugging and round-trip tests. NOT the TS-strip codegen
(that is Phase 09, whitespace-preserving). Enough to snapshot parse results in tests.

## test262 runner (`tests/conformance/`)

Vendor the pinned slice (`vendor-data/test262/` = `harness/` + `test/language/**`). A YAML-ish
frontmatter parser reads the `/*--- … ---*/` block per INTERPRETING.md: `flags` (onlyStrict/noStrict/
module/raw/…), `features`, `negative:{phase,type}`, `includes`. The Phase 02 runner does the **parse**
phase only:
- skip `*_FIXTURE.js`; skip tests whose `features` intersect the unsupported-syntax set (above);
- honor `flags`: `[module]` → parse as Module (goal), `raw`/default → Script, `onlyStrict`/`noStrict`
  select the mode(s) (default runs both);
- for `negative.phase == parse` → expect a SyntaxError; else → expect a successful parse;
- record: crashes (any non-SyntaxError Lisp condition → gate failure), negative-parse misses, and a
  checked-in **parse pass-list** (grows monotonically; Phase 03 extends the mechanism to execution).

**Gate:** parse all non-skipped `language/**` with zero crashes; every `negative:{phase:parse}` (in
the non-skipped set) → SyntaxError; token-span property holds. Runner exposed as `make conformance`.

## Risks

- Arrow / cover-grammar reinterpretation and object-literal-vs-destructuring are the classic parser
  bugs — mitigated by parsing to a cover node then refining, with dense negative-parse coverage.
- ASI restricted productions (`return`\n) and `[`/`(`/`` ` `` continuation are error-prone — explicit
  `nl-before` handling + tests.
- Early errors are numerous; the 4,449 negative-parse tests are the oracle. Reaching 100% is the
  long pole; milestones grow the negative-parse pass count without regressions.
