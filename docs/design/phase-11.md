# Phase 11 — Binary data + BigInt

Objective (§5): ArrayBuffer, all TypedArray kinds, DataView, detach; TextEncoder/Decoder (UTF-8);
BigInt (literals, ops, ToBigInt, mixing TypeErrors, toString radix, BigInt64Array).
**Gate:** TypedArray/DataView/BigInt curated slices ≥65%; overall curated ≥80%; 0 crashes/regressions.

Grounded in the actual source (verified, not assumed). The front-end is already done: the lexer emits
`:bigint` tokens with a CL integer value (`lexer.lisp:216-233`), the parser builds a `:bigint` literal
(`parser.lisp:751`), and `compile-literal` passes the integer through unchanged. Phase 11 is purely
runtime + stdlib.

## 1. BigInt = a plain CL integer (not a wrapper struct)

No engine-internal JS value is ever a raw CL integer: JS numbers are `double-float`; lengths/indices are
consumed as CL integers *locally* but never stored/returned as a JS value. So a bare integer is an
unambiguous free slot in the value domain (exactly `values.lisp:10-11`'s intent). This is faithful *and*
cheaper than a wrapper: `=`/`js-strict-eq`/`js-same-value` work for free, no per-literal allocation, and
the `:bigint` arms already scaffolded in `js-loose-eq` light up.

- `js-bigint-p v` = `(integerp v)` (total; add to the `declaim inline` + export in `packages.lisp`).
- `js-type` (`values.lisp:55`): add `(integer :bigint)` clause before the `t` fallback.
- `js-typeof` (`operators.lisp:9`): `(integer "bigint")`.
- `js-strict-eq` (`operators.lisp:79`): `(:bigint (= x y))`.
- `js-loose-eq`: BigInt==Number is **mathematical equality**, NOT auto-false (`1n == 1` → true): false
  if the number is NaN/±Inf/non-integral, else `(= bigint (rational double))`; BigInt==String parses the
  string to a BigInt (`nil` on parse fail); BigInt==Boolean routes through `1n/0n`.
- Arithmetic: one `numeric-binary` dispatch helper — `ToNumeric` both sides, both integer → CL bigint op,
  exactly one integer → **TypeError** ("Cannot mix BigInt and other types"), else float path.
  `js-add` keeps its string-concat branch first. `/` truncates toward zero (0 divisor → RangeError);
  `%` uses `rem` (dividend sign); `**` negative exponent → RangeError (+ DoS guard on the exponent).
- Bitwise `& | ^ ~ << >>`: natural on CL integers (`logand/logior/logxor/lognot/ash`, arbitrary-precision,
  two's-complement-consistent). Mixed → TypeError. `>>>` on BigInt → **TypeError** (spec).
- Unary: `-10n` → `-10`; `+bigint` → **TypeError** (§13.5.4, the one asymmetry). `++`/`--`
  (`compile-update`, `emitter.lisp`) switch to ToNumeric + integer/double branch.
- Relational `%abstract-lt`: both integer → `(< a b)`; bigint↔double via rationals (NaN→undefined);
  bigint↔numeric-string parses the string.

**coercions.lisp:** `to-boolean` — `0n` falsy; `to-number` on a BigInt → **TypeError** (the honesty
linchpin — no implicit BigInt→Number); `to-string` → `(format nil "~d" v)` (no `n`); add `to-numeric`
(§7.1.4) and `to-bigint` (§7.1.13: string→StringToBigInt with 0x/0o/0b, `SyntaxError` on `1.5`/`1n`;
number→TypeError; boolean→1/0). `to-index`/`to-length` unchanged (they call `to-number`, which now
correctly TypeErrors on a BigInt arg — so `new Uint8Array(10n)` throws).

**inspect.lisp** (line 79): `((integerp v) (format nil "~dn" v))`. **realm.lisp** `*to-object-hook*`:
`(integer (make-wrapper :bigint-prototype :bigint v))` so method calls on a primitive receiver work; add
`this-bigint` mirroring `this-number`.

`builtins-bigint.lisp` (new, after `builtins-number`): `BigInt` callable-not-constructor (`new BigInt()`
→ TypeError); `BigInt.prototype` toString(radix 2..36, lowercase, `~vR`)/valueOf/`@@toStringTag`;
`BigInt.asIntN/asUintN` (`bits` via `to-index`, `(ldb (byte bits 0) v)` + sign-fold).

## 2. ArrayBuffer / TypedArray / DataView (objects.lisp structs + builtins-binary.lisp)

Structs `:include js-object` (like `js-array`/`js-regexp`):
- `js-array-buffer` — `bytes` = `(simple-array (unsigned-byte 8) (*))` | NIL when detached.
- `js-typed-array` — `buffer kind byte-offset array-length content(:number|:bigint)`. ONE struct with a
  `kind` slot (not 11 structs).
- `js-data-view` — `buffer byte-offset byte-length`.

`*typed-array-kinds*` = the single-source alist: Int8/Uint8/Uint8Clamped/Int16/Uint16/Int32/Uint32/
Float32/Float64 (`:number`) + BigInt64/BigUint64 (`:bigint`), each with `(name size content signed)`.

**Byte assembly (pure SBCL, fixed little-endian for TypedArrays regardless of host):** integers via
`le-uint`/`le-put-uint` (loop of `ash`/`ldb (byte 8 …)`), signed via sign-fold; Float32 via
`sb-kernel:single-float-bits`/`make-single-float`, Float64 via `double-float-high-bits`/`low-bits`/
`make-double-float`. DataView chooses endianness from its arg (**default big-endian**). All verified
present, no CFFI.

**Exotic (override the `jm-*` generics on `js-typed-array`, same pattern as `js-array`):** a
`canonical-numeric-index-p` helper (any canonical numeric string, per §10.4.5) drives `jm-get`
(detached/OOB → undefined, else read per kind), `jm-set` (coerce value first — `to-bigint` for BigInt
kinds — even when OOB/detached, then no-op the store if OOB/detached), `jm-define-own-property`,
`jm-get-own-property` (synthesize writable+enumerable+configurable data desc), `jm-own-property-keys`
(indices ascending, then string keys, then symbols). DataView is NOT integer-indexed → no kernel override.

**Constructors:** one abstract `%TypedArray%` (throws if called directly) + 11 concrete ctors chained by
prototype (intrinsic subclassing, not `extends`), each with `BYTES_PER_ELEMENT`. `new Uint8Array(x)`:
ArrayBuffer→view (offset/length bounds + alignment RangeError); TypedArray→copy (BigInt↔Number cross →
TypeError); object/iterable→materialize; number/undefined→zero-filled. Prototype methods for the gate:
`length/byteLength/byteOffset/buffer/@@toStringTag` getters, `at fill set subarray slice copyWithin
indexOf lastIndexOf includes join reverse forEach map filter reduce reduceRight some every find findIndex
keys values entries @@iterator sort` (numeric comparator). ArrayBuffer: `byteLength` getter, `slice`,
`isView`, `@@toStringTag`, `transfer`/`transferToFixedLength` (detach). DataView: 20 accessors
`getInt8`…`setBigUint64` + float (detached→TypeError, OOB→RangeError). **Detach = a single flag in the
buffer** (`bytes`→NIL); every op re-reads it so all aliasing views see it at once.

## 3. TextEncoder / TextDecoder (reuse strings.lisp)

`code-units->utf8` / `utf8->code-units` (`strings.lisp:41,88`) are already WTF-8/WHATWG-correct.
`TextEncoder.encode(str)` → fresh Uint8Array; `encoding` = "utf-8". `TextDecoder(label)` accepts the
utf-8 aliases else **RangeError** (loud, no silent fallback); `decode` extracts bytes from any
TypedArray/DataView/ArrayBuffer then `utf8->code-units` (non-fatal default = maximal-subpart U+FFFD;
`fatal:true` = a shared `%decode-utf8 :on-error :error` that throws TypeError on the first bad sequence).

## Deliberate gaps (loud errors, never silent — `tests/conformance/bigint-binary-gaps.txt`)

Resizable/growable ArrayBuffer (ctor option → RangeError); SharedArrayBuffer + Atomics (stay
`*exec-skip*`); some ES2023 change-by-copy TypedArray methods (absent); TextDecoder streaming +
non-UTF-8 labels (label → RangeError); `encodeInto` (may be absent); `@@species` subclass return types
(return base intrinsic); `Number(bigint)`/implicit BigInt→Number (deliberate TypeError).

## File layout & build order

New: `src/engine/builtins-bigint.lisp` (after builtins-number), `src/engine/builtins-binary.lisp` (after
builtins-collections, before builtins-global), `tests/lisp/engine/binary-tests.lisp`,
`tests/conformance/bigint-binary-gaps.txt`. Modified: values/operators/coercions/emitter/inspect/realm/
realm-builtins/objects/packages + clun.asd + scripts/test262.lisp.

Build order (each `make build && make test` green before the next): (1) BigInt value+coercions+operators
+ inspector; (2) `builtins-bigint.lisp` (ctor/statics/prototype); (3) ArrayBuffer + byte helpers;
(4) TypedArray exotic + ctors + prototype; (5) DataView; (6) TextEncoder/Decoder; (7) vendor slices +
measure + gaps file + parachute suite + review + regen pass-list + commit.
