# test262 execution failure buckets

This is a deterministic analysis of the authoritative execution classification ledger. Only `fail` rows contribute to the bucket and tag counts.

## Provenance

| Item | Value |
|---|---|
| generator | `scripts/test262-buckets.lisp` |
| vendor-test262-commit | `d1d583db95a521218f3eb8341a887fd63eda8ff1` |
| source-revision | `working-tree@7c10d91e92413d9728c137265e9cb3922e65e884` |
| classification-ledger | `tmp-test/m5-final-classifications.tsv` |
| frozen-passlist | `tests/conformance/exec-passlist.txt` |
| classification-ledger-fnv-1a-64 | `C104919DBAF109E4` |

The digest is FNV-1a-64 over the ledger's exact input bytes; it is not SHA.

## Exact coverage target

| Measure | Exact value |
|---|---:|
| Total | 40654 |
| Pass | 25051 |
| Fail | 3112 |
| Skip | 12491 |
| Crash | 0 |
| Eligible (`pass + fail`) | 28163 |
| Pass rate | 25051 / 28163 = 88.950041% |
| Frozen baseline pass count | 25051 |
| Current-pass delta from frozen baseline | +0 |
| `ceil(90% * eligible)` | 25347 |
| Required pass lift | 296 |

## Phase-owner counts

| Phase owner | Fail rows |
|---|---:|
| `phase-25b` | 2227 |
| `phase-37` | 885 |

Phase ownership is orthogonal to the implementation work buckets below.

## Work-bucket counts

| Order | Work bucket | Fail rows |
|---:|---|---:|
| 1 | `binding-patterns` | 16 |
| 2 | `dynamic-scope-eval` | 315 |
| 3 | `async-iteration` | 509 |
| 4 | `async-generators` | 0 |
| 5 | `generators` | 10 |
| 6 | `classes` | 20 |
| 7 | `binary-data` | 643 |
| 8 | `regexp` | 224 |
| 9 | `iterator-protocol` | 11 |
| 10 | `promises` | 101 |
| 11 | `collections` | 238 |
| 12 | `arrays` | 334 |
| 13 | `objects` | 98 |
| 14 | `functions-arguments` | 44 |
| 15 | `operators-references` | 177 |
| 16 | `primitive-builtins` | 224 |
| 17 | `other-runtime` | 148 |

The work buckets are mutually exclusive, first-match wins, and their counts sum to 3112.

## Top 25 owner counts

| Count | Value |
|---:|---|
| 466 | `language:expressions` |
| 433 | `language:statements` |
| 422 | `builtin:Array` |
| 382 | `builtin:TypedArray` |
| 204 | `builtin:RegExp` |
| 183 | `language:eval-code` |
| 156 | `builtin:Set` |
| 129 | `builtin:DataView` |
| 104 | `builtin:Object` |
| 103 | `builtin:Promise` |
| 65 | `builtin:TypedArrayConstructors` |
| 63 | `builtin:Date` |
| 50 | `builtin:String` |
| 48 | `builtin:ArrayBuffer` |
| 43 | `builtin:Map` |
| 41 | `builtin:Error` |
| 36 | `builtin:WeakMap` |
| 25 | `builtin:JSON` |
| 19 | `builtin:Math` |
| 19 | `builtin:Number` |
| 18 | `language:global-code` |
| 17 | `builtin:AsyncGeneratorPrototype` |
| 15 | `builtin:Symbol` |
| 10 | `language:literals` |
| 9 | `builtin:AsyncFromSyncIteratorPrototype` |

Counts are sorted by count descending, then raw value ascending. Showing 25 of 40 distinct values.

## Top 25 topic counts

| Count | Value |
|---:|---|
| 173 | `language/eval-code/direct` |
| 142 | `language/statements/with` |
| 105 | `language/expressions/async-generator` |
| 100 | `language/statements/class` |
| 96 | `language/expressions/class` |
| 95 | `built-ins/Array/fromAsync` |
| 78 | `language/expressions/compound-assignment` |
| 59 | `built-ins/Object/hasOwn` |
| 56 | `language/expressions/object` |
| 55 | `language/statements/async-generator` |
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

Counts are sorted by count descending, then raw value ascending. Showing 25 of 326 distinct values.

## Top 25 raw feature counts

| Count | Value |
|---:|---|
| 449 | `TypedArray` |
| 418 | `async-iteration` |
| 323 | `Symbol.asyncIterator` |
| 322 | `Symbol.iterator` |
| 203 | `BigInt` |
| 188 | `Symbol.species` |
| 151 | `set-methods` |
| 121 | `change-array-by-copy` |
| 95 | `Array.fromAsync` |
| 94 | `Symbol` |
| 75 | `await-dictionary` |
| 72 | `globalThis` |
| 63 | `align-detached-buffer-semantics-with-web-reality` |
| 59 | `Object.hasOwn` |
| 59 | `array-find-from-last` |
| 51 | `Reflect.construct` |
| 49 | `upsert` |
| 44 | `immutable-arraybuffer` |
| 43 | `Symbol.unscopables` |
| 40 | `Float16Array` |
| 38 | `Symbol.replace` |
| 31 | `Symbol.match` |
| 31 | `WeakMap` |
| 30 | `ArrayBuffer` |
| 30 | `DataView` |

Counts are sorted by count descending, then raw value ascending. Showing 25 of 83 distinct values.

## Top 25 raw include counts

| Count | Value |
|---:|---|
| 441 | `testTypedArray.js` |
| 334 | `compareArray.js` |
| 258 | `detachArrayBuffer.js` |
| 217 | `propertyHelper.js` |
| 148 | `asyncHelpers.js` |
| 49 | `isConstructor.js` |
| 19 | `nativeErrors.js` |
| 15 | `regExpUtils.js` |
| 9 | `temporalHelpers.js` |
| 3 | `compareIterator.js` |
| 2 | `byteConversionValues.js` |
| 2 | `decimalToHexString.js` |
| 2 | `proxyTrapsHelper.js` |
| 1 | `nativeFunctionMatcher.js` |

Counts are sorted by count descending, then raw value ascending. All 14 distinct values are shown.
