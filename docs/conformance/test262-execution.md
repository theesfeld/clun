# test262 execution failure buckets

This is a deterministic analysis of the authoritative execution classification ledger. Only `fail` rows contribute to the bucket and tag counts.

## Provenance

| Item | Value |
|---|---|
| generator | `scripts/test262-buckets.lisp` |
| vendor-test262-commit | `d1d583db95a521218f3eb8341a887fd63eda8ff1` |
| source-revision | `cb7de5d30b3a9c0df96bf857fe091a86f09da2cd` |
| classification-ledger | `tmp-test/test262-exec-classifications.tsv` |
| frozen-passlist | `tests/conformance/exec-passlist.txt` |
| classification-ledger-fnv-1a-64 | `51F51CA8B22FAB6D` |

The digest is FNV-1a-64 over the ledger's exact input bytes; it is not SHA.

## Exact coverage target

| Measure | Exact value |
|---|---:|
| Total | 40654 |
| Pass | 25474 |
| Fail | 2689 |
| Skip | 12491 |
| Crash | 0 |
| Eligible (`pass + fail`) | 28163 |
| Pass rate | 25474 / 28163 = 90.452012% |
| Frozen baseline pass count | 25474 |
| Current-pass delta from frozen baseline | +0 |
| `ceil(90% * eligible)` | 25347 |
| Required pass lift | 0 |

## Phase-owner counts

| Phase owner | Fail rows |
|---|---:|
| `phase-25b` | 1808 |
| `phase-37` | 881 |

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
| 7 | `binary-data` | 643 |
| 8 | `regexp` | 224 |
| 9 | `iterator-protocol` | 10 |
| 10 | `promises` | 97 |
| 11 | `collections` | 238 |
| 12 | `arrays` | 333 |
| 13 | `objects` | 91 |
| 14 | `functions-arguments` | 44 |
| 15 | `operators-references` | 177 |
| 16 | `primitive-builtins` | 222 |
| 17 | `other-runtime` | 148 |

The work buckets are mutually exclusive, first-match wins, and their counts sum to 2689.

## Top 25 owner counts

| Count | Value |
|---:|---|
| 421 | `builtin:Array` |
| 382 | `builtin:TypedArray` |
| 284 | `language:statements` |
| 232 | `language:expressions` |
| 204 | `builtin:RegExp` |
| 183 | `language:eval-code` |
| 156 | `builtin:Set` |
| 129 | `builtin:DataView` |
| 99 | `builtin:Promise` |
| 97 | `builtin:Object` |
| 65 | `builtin:TypedArrayConstructors` |
| 63 | `builtin:Date` |
| 50 | `builtin:String` |
| 48 | `builtin:ArrayBuffer` |
| 43 | `builtin:Map` |
| 40 | `builtin:Error` |
| 36 | `builtin:WeakMap` |
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
| 59 | `built-ins/Object/hasOwn` |
| 47 | `built-ins/TypedArrayConstructors/internals` |
| 44 | `built-ins/TypedArray/prototype/slice` |
| 39 | `built-ins/Array/prototype/concat` |
| 38 | `built-ins/Promise/allKeyed` |
| 37 | `built-ins/Promise/allSettledKeyed` |
| 37 | `built-ins/RegExp/prototype/Symbol.replace` |
| 35 | `built-ins/Array/prototype/lastIndexOf` |
| 35 | `built-ins/TypedArray/prototype/filter` |
| 29 | `built-ins/Array/prototype/indexOf` |
| 29 | `built-ins/Array/prototype/toSpliced` |
| 28 | `built-ins/Error/prototype/stack` |
| 28 | `built-ins/TypedArray/prototype/findLast` |
| 28 | `built-ins/TypedArray/prototype/findLastIndex` |
| 28 | `built-ins/TypedArray/prototype/map` |
| 27 | `built-ins/RegExp` |
| 26 | `built-ins/Array/prototype/map` |
| 26 | `built-ins/RegExp/prototype/Symbol.split` |
| 25 | `built-ins/TypedArray/prototype/subarray` |
| 24 | `built-ins/Set/prototype/union` |
| 24 | `language/expressions/tagged-template` |

Counts are sorted by count descending, then raw value ascending. Showing 25 of 310 distinct values.

## Top 25 raw feature counts

| Count | Value |
|---:|---|
| 449 | `TypedArray` |
| 203 | `BigInt` |
| 188 | `Symbol.species` |
| 151 | `set-methods` |
| 121 | `change-array-by-copy` |
| 95 | `Array.fromAsync` |
| 93 | `Symbol` |
| 75 | `await-dictionary` |
| 72 | `globalThis` |
| 63 | `align-detached-buffer-semantics-with-web-reality` |
| 59 | `Object.hasOwn` |
| 59 | `array-find-from-last` |
| 49 | `Reflect.construct` |
| 49 | `upsert` |
| 44 | `immutable-arraybuffer` |
| 43 | `Symbol.unscopables` |
| 40 | `Float16Array` |
| 38 | `Symbol.replace` |
| 31 | `Symbol.match` |
| 31 | `WeakMap` |
| 30 | `ArrayBuffer` |
| 30 | `DataView` |
| 28 | `Symbol.isConcatSpreadable` |
| 28 | `Symbol.split` |
| 28 | `error-stack-accessor` |

Counts are sorted by count descending, then raw value ascending. Showing 25 of 79 distinct values.

## Top 25 raw include counts

| Count | Value |
|---:|---|
| 441 | `testTypedArray.js` |
| 325 | `compareArray.js` |
| 258 | `detachArrayBuffer.js` |
| 217 | `propertyHelper.js` |
| 141 | `asyncHelpers.js` |
| 47 | `isConstructor.js` |
| 19 | `nativeErrors.js` |
| 15 | `regExpUtils.js` |
| 9 | `temporalHelpers.js` |
| 3 | `compareIterator.js` |
| 2 | `byteConversionValues.js` |
| 2 | `decimalToHexString.js` |
| 2 | `proxyTrapsHelper.js` |
| 1 | `nativeFunctionMatcher.js` |

Counts are sorted by count descending, then raw value ascending. All 14 distinct values are shown.
