# Phase 01 — Engine values & coercions

Objective: the value substrate everything else sits on — the JS value domain in CL, the
JS-exception↔CL-condition bridge, the UTF-8/WTF-8 host boundary, and the ECMA-262 abstract-operation
coercion kernel (ToPrimitive/ToNumber/ToString/ToBoolean/ToInt32/ToUint32). ES ref: ECMA-262 §6.1
(types), §7.1 (abstract ops). All coercion functions cite their spec subsection in-source.

## Value representation — DECIDED: native CL types + keyword singletons

Micro-benchmarked on this host (200M dispatches / 1M mixed values, `speed 3 safety 0`):

| Representation | ns/dispatch | MB / 1M values |
|---|---|---|
| **native `typecase` (chosen)** | **0.88** | **21.4** |
| uniform tagged `(defstruct jsval tag data)` | 3.77 | 48.0 |

Native is 4.3× faster and ~2.25× lighter, and lets SBCL keep `double-float`s unboxed in typed
arithmetic. See DECISIONS.md. The JS value domain maps to CL as:

| JS type | CL representation |
|---|---|
| undefined | `+undefined+` = keyword `:undefined` |
| null | `+null+` = keyword `:null` |
| boolean | `+true+`/`+false+` = keywords `:true`/`:false` (NOT CL `t`/`nil` — avoids nil-confusion) |
| number | `double-float` |
| string | CL `string` (simple-string), one char = one UTF-16 code unit |
| symbol | struct (Phase 04) |
| bigint | struct/CL-integer wrapper (Phase 11) |
| object | struct (Phase 03) |

The singletons are keywords behind named constants (`+undefined+` …) and predicates
(`js-undefined-p` …) so the representation is swappable — no bare `:undefined` literals in engine
code. CL keywords can never collide with a JS value (numbers are doubles, strings are strings,
everything else is a struct), so `eq` on the constants is unambiguous.

## Module layout (`src/engine/`)

```
values.lisp      singletons + constants, type predicates, js-type (spec Type()), js-truthy hook
conditions.lisp  JS-exception↔CL-condition bridge
strings.lisp     UTF-8 ⇄ UTF-16-code-unit (WTF-8) converters, string helpers
numbers.lisp     float-trap macro, NaN/Inf/−0 helpers, ToInt32/ToUint32, number→string, string→number
coercions.lisp   ToPrimitive, ToBoolean, ToNumber, ToString (ties the above together)
```

All in package `clun.engine`; public API exported from the defining file. Depends on nothing but
`:cl`. Loaded after `src/version.lisp` in `clun.asd` (a new `engine` module).

## JS-exception ↔ CL-condition bridge (`conditions.lisp`)

A JS `throw` of an arbitrary value becomes a CL condition; an uncaught one is rendered at the top
level (Phase 08). Shape:

- `js-condition` (subtype of `error`) carries `value` — the thrown JS value. `throw-js-value` signals
  it. This is how user `throw x` propagates through CL.
- `js-native-error` (subtype of `js-condition`) carries `kind` (`:type-error` `:range-error`
  `:syntax-error` `:reference-error` …) + `message`. Engine-internal throws use
  `(throw-type-error "…")` / `(throw-range-error "…")` etc. **Real JS `TypeError`/`RangeError`
  objects don't exist until Phase 04**; until then `js-condition-value` on a native error yields a
  lightweight placeholder. Phase 04 redefines the constructors to build real Error objects (with
  `.stack`), so call sites never change — the bridge is the seam.

In Phase 01, no primitive-only input actually throws (Symbol/BigInt/Object coercion throws land with
those types in later phases), so the bridge is tested via the `throw-*` helpers directly: the right
condition type, kind, and message are signalled and catchable.

## UTF-8 / WTF-8 boundary (`strings.lisp`)

Internally a string is UTF-16 code units (one CL char each); astral scalars are stored as surrogate
**pairs** (two chars). At host boundaries (fs, sockets, argv) we convert to/from UTF-8 bytes. SBCL's
built-in `string-to-octets :utf-8` can't do this correctly — it errors on lone surrogates and would
CESU-8-encode a pair as two 3-byte sequences — so we hand-roll **WTF-8**:

- **Encode (code units → bytes):** scan; a valid high(D800–DBFF)+low(DC00–DFFF) pair → combine to the
  scalar (0x10000 + ((hi−0xD800)<<10) + (lo−0xDC00)) → 4-byte UTF-8; a **lone** surrogate → its own
  3-byte encoding (WTF-8, code point = the surrogate value); BMP non-surrogate → standard 1–3 byte.
- **Decode (bytes → code units):** a 4-byte scalar (cp ≥ 0x10000) → **two** surrogate code units;
  1–3 byte → one char (including 3-byte encodings of D800–DFFF → lone surrogate char, legal per
  Appendix C fact 1). Malformed input follows the **WHATWG maximal-subpart rule** — one U+FFFD per
  error, the offending byte reprocessed, per-byte second-byte range checks reject overlong/out-of-
  range (but keep surrogates) — so this decoder is the foundation for Phase 11's `TextDecoder`.

Round-trip property (gate): `decode(encode(s)) ≡ s` for all s including lone surrogates and astral
pairs.

## Numbers (`numbers.lisp`)

- **Trap mask:** `(with-js-floats … )` wraps `sb-int:with-float-traps-masked (:overflow :invalid
  :divide-by-zero)` (Appendix C fact 4: gives correct Inf/NaN/−0). Engine entry points wrap once.
  The emitter (Phase 03) must never emit a constant-foldable trapping literal — regression test lives
  there, noted here.
- **Helpers:** `js-nan` (`(/ 0d0 0d0)` under mask, cached), `+js-infinity+`/`+js-neg-infinity+`,
  `js-nan-p` (`sb-ext:float-nan-p`), `js-neg-zero-p` (`(eql x -0d0)`; note `(eql -0d0 0d0)` = NIL),
  `js-integer-valued-p`.
- **ToInt32 / ToUint32** (§7.1.6/7.1.7): via `(ldb (byte 32 0) (truncate mag))` + sign fixup; NaN/±0/
  ±∞ → +0. Int32 re-signs values ≥ 2³¹.
- **Number→String** (§6.1.6.1.20): NaN→"NaN", ±0→"0", negative→"-"+abs, ∞→"Infinity"; finite via
  naive bignum shortest-round-trip (see DECISIONS.md), then the k/n/s exponent formatting: `n-1`
  in [−6, 20] uses fixed notation, else `e`-notation with sign.
- **String→Number** (§7.1.4.1 StrNumericLiteral): trim `StrWhiteSpace` (incl. `\t\n\r\v\f`, space,
  NBSP, BOM, USP); "" → +0; `0x`/`0o`/`0b` non-decimal integer literals; optional `+`/`-`;
  `Infinity`; decimal with optional fraction/exponent; anything else → NaN. Note: no legacy octal
  (leading `0` is decimal), unlike parseInt.

## Coercions (`coercions.lisp`) — ECMA-262 §7.1

- **ToPrimitive(input, hint)** §7.1.1: non-object → identity. Object → `OrdinaryToPrimitive`
  (valueOf/toString via `[[Get]]`/`[[Call]]`) through a hook var installed in Phase 03/04; Phase 01
  raises an internal error if an object is passed (no objects yet).
- **ToBoolean** §7.1.2: undefined/null→false; boolean→self; number→ not(±0 or NaN); string→ not empty;
  symbol→true; bigint→ ≠0n; object→true.
- **ToNumber** §7.1.4: undefined→NaN; null→+0; boolean→1/+0; number→self; string→String→Number;
  symbol/bigint→TypeError; object→ToNumber(ToPrimitive(v, number)).
- **ToString** §7.1.17: undefined→"undefined"; null→"null"; boolean→"true"/"false"; number→Number→
  String; string→self; symbol→TypeError; bigint→digits; object→ToString(ToPrimitive(v, string)).

## Risks

- **Number→String correctness** is the highest risk; mitigated by exact-rational round-trip + a
  known-answer vector set (incl. 0.1, 5e-324 min subnormal, 1e21 threshold, 9007199254740993).
- **WTF-8 surrogate handling** is fiddly; mitigated by the round-trip property test over generated
  strings with embedded lone/paired surrogates.
- **Float traps leaking** through callbacks — entry-point masking only; revisited when the evaluator
  (Phase 03) establishes the real entry points.
