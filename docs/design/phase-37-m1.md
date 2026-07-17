# Phase 37 Milestone 1 - Modern Built-in Foundations

Status: accepted for implementation as the first bounded Phase 37 milestone.

## Objective and boundary

This milestone implements nine post-ES2017 built-ins that are already supported by the pinned Bun
surface and account for 173 failures in Clun's frozen Phase 37 execution inventory:

| Built-in | Frozen failing rows |
| --- | ---: |
| `Object.hasOwn` | 59 |
| `Array.prototype.toReversed` | 16 |
| `Array.prototype.toSorted` | 19 |
| `Array.prototype.toSpliced` | 29 |
| `Array.prototype.with` | 20 |
| `String.prototype.isWellFormed` | 8 |
| `String.prototype.toWellFormed` | 8 |
| `Error.isError` | 10 |
| `Promise.withResolvers` | 4 |

The frozen execution source is Test262 commit
`d1d583db95a521218f3eb8341a887fd63eda8ff1`. The complete Phase 37 residual manifest is the set of rows
whose `phase_owner` is `phase-37` in `tests/conformance/exec-gaps.tsv`; at milestone entry that file has
SHA-256 `b4c3980e54cb96814c9a67475350df4d7413004ebe7c2a6553eaf89bef88e24e` and contains 881 such rows.
The milestone selection is the exact intersection of those rows with the nine `topic` values listed
above. That entry set is preserved in the immutable
`tests/conformance/phase-37-m1-paths.txt` manifest with sorted path SHA-256
`8c6b2bf439427982128a1eaa69c0e48321986c20d2992c9147f87492ccb6a886`, so the focused gate remains
reproducible after successful paths leave the live gap ledger. No failure is removed, reclassified, or
skipped to improve the result.

The behavioral reference is Bun 1.4.0-dev at engineering commit
`c1076ce95effb909bfe9f596919b5dba5567d550`, with Bun 1.3.14 at
`0d9b296af33f2b851fcbf4df3e9ec89751734ba4` as the executable stable baseline. The selected APIs are
standard ECMAScript APIs rather than Bun extensions, so the Test262 fixtures are the normative observable
contract. The committed shipped-runtime differential records exact Bun 1.3.14 output. Clun agrees on all
common probes except `Promise.withResolvers` own-key order: Bun 1.3.14 emits `resolve,reject,promise`, while
Clun retains the Test262-required `promise,resolve,reject` order as a documented correctness improvement.

This milestone does not implement the other 708 frozen Phase 37 residuals, change the public compatibility
ledger, claim completion of Phase 37, or modify release/version/publication files. Proxy, modern RegExp,
`Array.fromAsync`, keyed Promise combinators, collection methods, Float16, immutable ArrayBuffer,
WeakRef/FinalizationRegistry, Intl, Temporal, Atomics, and SharedArrayBuffer retain Phase 37 ownership.

## Semantics

### `Object.hasOwn`

`Object.hasOwn(value, key)` performs `ToObject(value)` before `ToPropertyKey(key)` and then calls the
object's `[[GetOwnProperty]]` internal method. It accepts symbol keys, never invokes an own or inherited
property getter merely to test existence, and exposes Proxy `getOwnPropertyDescriptor` behavior through the
ordinary internal-method path. Nullish values throw. The function has name `hasOwn`, length 2, the ordinary
built-in descriptor, and no `prototype` property.

### Array copy-by-change methods

All four methods are generic over array-like receivers, perform `ToObject` and `LengthOfArrayLike` in spec
order, ignore `Symbol.species`, return a fresh ordinary Array, read holes through `Get`, and therefore create
dense `undefined` entries in the result. They snapshot `length` once but perform element gets in the required
observable order. `ArrayCreate` rejects lengths above `2^32 - 1` before element access.

- `toReversed()` reads from highest source index to lowest and writes ascending result indices.
- `toSorted(compareFn)` rejects a present non-callable comparator before coercing the receiver or reading
  its length, reads all values in ascending order,
  performs a stable sort with `undefined` after defined values, treats comparator `NaN` as zero, and never
  calls the comparator for `undefined` values.
- `toSpliced(start, deleteCount, ...items)` implements the omitted-argument distinctions, computes the new
  length before source element access, throws `TypeError` above `2^53 - 1`, then applies the Array length
  ceiling. Prefix and suffix gets occur in ascending order.
- `with(index, value)` applies `ToIntegerOrInfinity`; a negative finite index is relative to the captured
  length. Out-of-range indices, including either infinity, throw `RangeError` before allocation or element
  access. The replacement index is not read from the source.

### Well-formed strings

`String.prototype.isWellFormed()` and `toWellFormed()` first apply RequireObjectCoercible and `ToString` to
the receiver. They scan Clun's UTF-16 code-unit string representation. A high surrogate is well formed only
when immediately followed by a low surrogate; an unpaired high or low surrogate is ill formed.
`isWellFormed` returns a boolean. `toWellFormed` returns the original code-unit sequence when it is well
formed and replaces each unpaired surrogate with U+FFFD otherwise. Both methods are non-constructible,
length 0 functions with ordinary built-in descriptors.

### `Error.isError`

`Error.isError(value)` returns true for every Clun native Error instance, including subclasses, without
property access or user-code execution. It returns false for ordinary objects that imitate Error properties
or prototypes. Proxies must not be unwrapped: even a Proxy around an Error returns false, including a revoked
Proxy. The method is non-constructible and has length 1.

### `Promise.withResolvers`

`Promise.withResolvers()` uses its receiver as the constructor and performs the same NewPromiseCapability
operation as the other Promise combinators. The result is a fresh ordinary object with enumerable writable
configurable own properties `promise`, `resolve`, and `reject` in that order. A non-constructor receiver or a
constructor that does not supply callable resolving functions throws. Subclassing and observable constructor
behavior are preserved. The method is non-constructible and has length 0.

## Architecture

- Extend the existing Object, Array, String, Error, and Promise bootstrap modules; do not add fixture-specific
  dispatch or a second object model.
- Reuse `jm-get-own-property`, `to-property-key`, array-like abstract operations, Promise capability creation,
  and the existing stable sort only where their observable contract matches this design.
- Keep implementation in pure Common Lisp. No CFFI, implementation JavaScript, native dependency, or shell-out
  is permitted.
- Any shared abstract operation added here must be named for the ECMAScript operation it implements and must
  remain usable by later Phase 37 milestones.

## Evidence and gates

The milestone is accepted only when all of the following hold on the implementation commit:

1. Every selected Test262 row passes through the ordinary execution runner in both applicable strictness
   modes, with zero crash, timeout, skip, or regression. The exact pass delta is measured against entry commit
   `7f443be629d66f5d11f3a81590de8160b6522ab0`.
2. Focused Lisp tests cover descriptors, coercion order, abrupt completion, Proxy interactions, sparse arrays,
   length ceilings, stable sorting, mutation during reads/comparison, surrogate edges, Error impostors, Promise
   subclassing, and hostile constructors.
3. The shipped-runtime fixture matches the committed expected output; pinned Bun 1.3.14 matches all common
   observables, and every divergence is structured, reviewable, and backed by normative Test262 evidence.
4. The complete frozen execution pass list remains monotonic; no selected feature is added to a skip list.
5. `make build`, focused tests, `make test`, `make purity`, and `make docs-check` pass. Full Phase 37 completion
   additionally retains every gate in the canonical Phase 37 issue and `PLAN.md`.

The public compatibility ledger, README, site, release notes, version, `STATE.md`, and `PLAN.md` are owned by
the release integration unit and intentionally remain unchanged on this implementation branch.
