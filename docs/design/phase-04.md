# Phase 04 — Stdlib core

Objective: broaden the built-ins real code touches first, raising conformance. The object kernel,
realm, and closure emitter are settled (Phase 03); this phase is largely breadth against the stable
object API. Spec: ECMA-262 §20-24. Gate: built-ins slices for the implemented globals ≥ 65%; overall
curated ≥ 55%; Ryū known-answer vectors pass.

## Module layout

Each global (or cluster) gets a self-contained file `src/engine/builtins-<area>.lisp` exposing a
`%bootstrap-<area> ()` bootstrap function (run with `*realm*` bound), called from `make-realm`. Files
are disjoint → the breadth work fans out cleanly (⚡). They use the Phase 03 helpers: `arg`,
`new-object`, `new-array`, `data-prop`/`hidden-prop`, `make-native-function`, `install-method`,
`install-getter`, `make-constructor`, `to-*` coercions, and the object internal-method API
(`js-get`/`js-set`/`jm-*`/`create-data-property`/`define-property-or-throw`).

Areas: `math`, `json`, `number` (+ Ryū), `array-methods`, `string-methods`, `object-extra`,
`function-extra`, `iterator` (the protocol + %ArrayIteratorPrototype% etc.), `map-set`, `date`,
`symbol-extra`, `global-fns` (parseInt/encodeURI/…).

## Number→String: Ryū (§6.1.6.1.20)

Replace the Phase 01 naive exact-rational shortest-round-trip with a **Ryū** port (Ulf Adams' Ryū —
positive-integer 64-bit multiply/shift shortest-representation). The public entry `number->js-string`
keeps its ECMA framing (sign, NaN/±∞/±0, the −6/21 exponent thresholds); only the shortest-digit
generation swaps to Ryū. A **known-answer vector set** (0.1, 5e-324, 1e21, 2^53, 9007199254740993,
the round-trip corpus, and Ryū's own hard cases) gates it. The naive rational path is kept as a
cross-check oracle in the test (both must agree). Ryū is pure integer arithmetic — no floats, no
SBCL internals.

## JSON (§25.5)

- `JSON.parse(text[, reviver])`: a hand-rolled recursive-descent JSON reader over code units (strict
  JSON grammar — not the JS grammar); builds js-values (objects via new-object, arrays via new-array,
  numbers via the number lexer path, strings with `\uXXXX`/escapes). Reviver walk post-parse.
- `JSON.stringify(value[, replacer[, space]])`: SerializeJSONProperty with toJSON, replacer
  (function or key array), indentation (space as number or string, clamped to 10), cycle detection
  (TypeError), and the exact escaping (§25.5.2.2 QuoteJSONString). undefined/function/symbol → omitted
  (property) or null (array element).

## Collections: Map / Set / WeakMap / WeakSet (§24)

Backed by an insertion-ordered structure: a CL `equal`-ish hash won't do (keys use SameValueZero and
include objects by identity), so use a hash-table keyed by a canonicalized key (numbers via a boxed
form so −0/NaN behave per SameValueZero; objects/strings/symbols by identity/content) PLUS an
insertion-order vector for iteration. WeakMap/WeakSet use SBCL weak-key hash-tables
(`:weakness :key`, verified available). Iteration yields entries in insertion order; `forEach`,
`@@iterator`, and the size getter are wired. A `[[MapData]]`/`[[SetData]]` slot on the object holds it.

## Iterator protocol (§27)

Define `%IteratorPrototype%` (with `@@iterator` returning this) and `%ArrayIteratorPrototype%`,
`%StringIteratorPrototype%`, `%MapIteratorPrototype%`, `%SetIteratorPrototype%`. `Array.prototype`
gets `@@iterator`/`values`/`keys`/`entries`; String, Map, Set likewise. The emitter's spread and
for-of already call the protocol via `iterable->list`; a spec-faithful step-wise driver
(`iterator-step`/`iterator-close`) is added for correctness where laziness/early-close matters.

## Date (UTC core, §21.4)

Time value = a double (ms since epoch). Own gregorian ↔ ms conversion (day-from-year, month tables,
leap years) in pure CL — no `sb-posix` time (determinism + purity). `Date.now()` needs a clock:
`get-internal-real-time` is monotonic-ish; wall-clock via `sb-unix:clock-gettime` (allowed contrib).
Getters/setters for the UTC and (with `getTimezoneOffset()` ≡ 0, documented) "local" families;
`Date.parse`/`toISOString`/`toJSON`/`valueOf`/`toString`. TZif local time is deferred (§3.1, Phase 26).

## String (code-unit exact, §22.1)

~40 prototype methods operating on UTF-16 code units: charAt/charCodeAt/codePointAt/at, indexOf/
lastIndexOf/includes/startsWith/endsWith, slice/substring/substr, toUpperCase/toLowerCase (ASCII +
the simple Unicode foldings we have; full UCD casing later), trim/trimStart/trimEnd, padStart/padEnd,
repeat, concat, split (string separator; regexp separator → Phase 10), replace/replaceAll (string
pattern), normalize (stub/error where UCD-dependent), fromCharCode/fromCodePoint, raw, `@@iterator`
(code-point iteration). Regexp-taking overloads defer to Phase 10.

## Array (ES2017, §23.1)

Complete the prototype: push/pop/shift/unshift/splice/slice/concat/join/reverse/fill/copyWithin,
indexOf/lastIndexOf/includes/find/findIndex, every/some/forEach/map/filter/reduce/reduceRight,
sort (comparator + default lexicographic; a stable pure-CL merge sort), flat/flatMap (feature-gated),
keys/values/entries/@@iterator, Array.of/from/isArray. Array `from` uses the iterator protocol.

## Risks & sequencing

- Ryū correctness is the one algorithmic risk → known-answer vectors + the naive oracle cross-check.
- Map/Set key canonicalization (SameValueZero, −0/NaN, object identity) is subtle → unit-tested.
- Breadth work fans out across `builtins-*.lisp`; each is integrated then verified by its test262
  slice. Build order: number/Ryū + JSON (own), then the fan-out (math/array/string/object/iterator/
  map-set/date/symbol), then measure → iterate to the gate. Each step keeps build/test/purity green.
