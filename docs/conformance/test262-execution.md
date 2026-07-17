# test262 execution failure buckets

This is a deterministic analysis of the authoritative execution classification ledger. Only `fail` rows contribute to the bucket and tag counts.

## Provenance

| Item | Value |
|---|---|
| generator | `scripts/test262-buckets.lisp` |
| vendor-test262-commit | `d1d583db95a521218f3eb8341a887fd63eda8ff1` |
| source-revision | `working-tree@132d7b711e0cdef712fa41ed832e26b917d6e650` |
| classification-ledger | `tmp-test/test262-exec-classifications.tsv` |
| frozen-passlist | `tests/conformance/exec-passlist.txt` |
| classification-ledger-fnv-1a-64 | `C69927D3946A20FB` |

The digest is FNV-1a-64 over the ledger's exact input bytes; it is not SHA.

## Exact coverage target

| Measure | Exact value |
|---|---:|
| Total | 40654 |
| Pass | 25688 |
| Fail | 2475 |
| Skip | 12491 |
| Crash | 0 |
| Eligible (`pass + fail`) | 28163 |
| Pass rate | 25688 / 28163 = 91.211874% |
| Frozen baseline pass count | 25688 |
| Current-pass delta from frozen baseline | +0 |
| `ceil(90% * eligible)` | 25347 |
| Required pass lift | 0 |

## Phase-owner counts

| Phase owner | Fail rows |
|---|---:|
| `phase-25b` | 1767 |
| `phase-37` | 708 |

Phase ownership is orthogonal to the implementation work buckets below.

## Work-bucket counts

| Order | Work bucket | Fail rows |
|---:|---|---:|
| 1 | `binding-patterns` | 16 |
| 2 | `dynamic-scope-eval` | 315 |
| 3 | `async-iteration` | 102 |
| 4 | `async-generators` | 0 |
| 5 | `generators` | 10 |
| 6 | `classes` | 19 |
| 7 | `binary-data` | 642 |
| 8 | `regexp` | 224 |
| 9 | `iterator-protocol` | 10 |
| 10 | `promises` | 93 |
| 11 | `collections` | 238 |
| 12 | `arrays` | 249 |
| 13 | `objects` | 32 |
| 14 | `functions-arguments` | 43 |
| 15 | `operators-references` | 141 |
| 16 | `primitive-builtins` | 193 |
| 17 | `other-runtime` | 148 |

The work buckets are mutually exclusive, first-match wins, and their counts sum to 2475.

## Top 25 owner counts

| Count | Value |
|---:|---|
| 382 | `builtin:TypedArray` |
| 337 | `builtin:Array` |
| 284 | `language:statements` |
| 204 | `builtin:RegExp` |
| 195 | `language:expressions` |
| 183 | `language:eval-code` |
| 156 | `builtin:Set` |
| 129 | `builtin:DataView` |
| 95 | `builtin:Promise` |
| 65 | `builtin:TypedArrayConstructors` |
| 63 | `builtin:Date` |
| 48 | `builtin:ArrayBuffer` |
| 43 | `builtin:Map` |
| 38 | `builtin:Object` |
| 36 | `builtin:WeakMap` |
| 30 | `builtin:Error` |
| 30 | `builtin:String` |
| 25 | `builtin:JSON` |
| 19 | `builtin:Math` |
| 19 | `builtin:Number` |
| 18 | `language:global-code` |
| 14 | `builtin:Symbol` |
| 10 | `language:literals` |
| 7 | `builtin:WeakSet` |
| 7 | `builtin:decodeURI` |

Counts are sorted by count descending, then raw value ascending. Showing 25 of 38 distinct values.

## Top 25 topic counts

| Count | Value |
|---:|---|
| 173 | `language/eval-code/direct` |
| 142 | `language/statements/with` |
| 95 | `built-ins/Array/fromAsync` |
| 78 | `language/expressions/compound-assignment` |
| 47 | `built-ins/TypedArrayConstructors/internals` |
| 44 | `built-ins/TypedArray/prototype/slice` |
| 39 | `built-ins/Array/prototype/concat` |
| 38 | `built-ins/Promise/allKeyed` |
| 37 | `built-ins/Promise/allSettledKeyed` |
| 37 | `built-ins/RegExp/prototype/Symbol.replace` |
| 35 | `built-ins/Array/prototype/lastIndexOf` |
| 35 | `built-ins/TypedArray/prototype/filter` |
| 29 | `built-ins/Array/prototype/indexOf` |
| 28 | `built-ins/Error/prototype/stack` |
| 28 | `built-ins/TypedArray/prototype/findLast` |
| 28 | `built-ins/TypedArray/prototype/findLastIndex` |
| 28 | `built-ins/TypedArray/prototype/map` |
| 27 | `built-ins/RegExp` |
| 26 | `built-ins/Array/prototype/map` |
| 26 | `built-ins/RegExp/prototype/Symbol.split` |
| 25 | `built-ins/TypedArray/prototype/subarray` |
| 24 | `built-ins/Set/prototype/union` |
| 23 | `built-ins/Set/prototype/difference` |
| 23 | `built-ins/Set/prototype/intersection` |
| 23 | `built-ins/Set/prototype/symmetricDifference` |

Counts are sorted by count descending, then raw value ascending. Showing 25 of 299 distinct values.

## Top 25 raw feature counts

| Count | Value |
|---:|---|
| 449 | `TypedArray` |
| 202 | `BigInt` |
| 188 | `Symbol.species` |
| 151 | `set-methods` |
| 95 | `Array.fromAsync` |
| 89 | `Symbol` |
| 75 | `await-dictionary` |
| 72 | `globalThis` |
| 63 | `align-detached-buffer-semantics-with-web-reality` |
| 59 | `array-find-from-last` |
| 49 | `upsert` |
| 44 | `immutable-arraybuffer` |
| 43 | `Symbol.unscopables` |
| 41 | `Reflect.construct` |
| 40 | `Float16Array` |
| 38 | `Symbol.replace` |
| 37 | `change-array-by-copy` |
| 31 | `Symbol.match` |
| 31 | `WeakMap` |
| 30 | `ArrayBuffer` |
| 30 | `DataView` |
| 28 | `Symbol.isConcatSpreadable` |
| 28 | `Symbol.split` |
| 28 | `error-stack-accessor` |
| 25 | `arrow-function` |

Counts are sorted by count descending, then raw value ascending. Showing 25 of 73 distinct values.

## Top 25 raw include counts

| Count | Value |
|---:|---|
| 441 | `testTypedArray.js` |
| 270 | `compareArray.js` |
| 258 | `detachArrayBuffer.js` |
| 193 | `propertyHelper.js` |
| 141 | `asyncHelpers.js` |
| 39 | `isConstructor.js` |
| 19 | `nativeErrors.js` |
| 15 | `regExpUtils.js` |
| 9 | `temporalHelpers.js` |
| 3 | `compareIterator.js` |
| 2 | `byteConversionValues.js` |
| 2 | `decimalToHexString.js` |
| 2 | `proxyTrapsHelper.js` |
| 1 | `nativeFunctionMatcher.js` |

Counts are sorted by count descending, then raw value ascending. All 14 distinct values are shown.
