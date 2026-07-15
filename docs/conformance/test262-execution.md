# test262 execution failure buckets

This is a deterministic analysis of the authoritative execution classification ledger. Only `fail` rows contribute to the bucket and tag counts.

## Provenance

| Item | Value |
|---|---|
| generator | `scripts/test262-buckets.lisp` |
| vendor-test262-commit | `d1d583db95a521218f3eb8341a887fd63eda8ff1` |
| source-revision | `working-tree@fef8020d6aebb451be69e872ef61c52e5e0408f3` |
| classification-ledger | `tmp-test/test262-exec-classifications.tsv` |
| frozen-passlist | `tests/conformance/exec-passlist.txt` |
| classification-ledger-fnv-1a-64 | `1DF243B2047FC7F1` |

The digest is FNV-1a-64 over the ledger's exact input bytes; it is not SHA.

## Exact coverage target

| Measure | Exact value |
|---|---:|
| Total | 40654 |
| Pass | 24504 |
| Fail | 3659 |
| Skip | 12491 |
| Crash | 0 |
| Eligible (`pass + fail`) | 28163 |
| Pass rate | 24504 / 28163 = 87.007776% |
| Frozen baseline pass count | 24504 |
| Current-pass delta from frozen baseline | +0 |
| `ceil(90% * eligible)` | 25347 |
| Required pass lift | 843 |

## Phase-owner counts

| Phase owner | Fail rows |
|---|---:|
| `phase-25b` | 2775 |
| `phase-37` | 884 |

Phase ownership is orthogonal to the implementation work buckets below.

## Work-bucket counts

| Order | Work bucket | Fail rows |
|---:|---|---:|
| 1 | `binding-patterns` | 44 |
| 2 | `dynamic-scope-eval` | 315 |
| 3 | `async-iteration` | 544 |
| 4 | `async-generators` | 0 |
| 5 | `generators` | 86 |
| 6 | `classes` | 189 |
| 7 | `binary-data` | 650 |
| 8 | `regexp` | 224 |
| 9 | `iterator-protocol` | 11 |
| 10 | `promises` | 110 |
| 11 | `collections` | 238 |
| 12 | `arrays` | 334 |
| 13 | `objects` | 133 |
| 14 | `functions-arguments` | 213 |
| 15 | `operators-references` | 186 |
| 16 | `primitive-builtins` | 229 |
| 17 | `other-runtime` | 153 |

The work buckets are mutually exclusive, first-match wins, and their counts sum to 3659.

## Top 25 owner counts

| Count | Value |
|---:|---|
| 657 | `language:expressions` |
| 582 | `language:statements` |
| 422 | `builtin:Array` |
| 384 | `builtin:TypedArray` |
| 204 | `builtin:RegExp` |
| 183 | `language:eval-code` |
| 156 | `builtin:Set` |
| 129 | `builtin:DataView` |
| 115 | `builtin:Object` |
| 112 | `builtin:Promise` |
| 74 | `builtin:Function` |
| 70 | `builtin:TypedArrayConstructors` |
| 63 | `builtin:Date` |
| 50 | `builtin:String` |
| 48 | `builtin:ArrayBuffer` |
| 43 | `builtin:Map` |
| 41 | `builtin:Error` |
| 38 | `language:arguments-object` |
| 36 | `builtin:WeakMap` |
| 28 | `builtin:AsyncGeneratorPrototype` |
| 25 | `builtin:JSON` |
| 19 | `builtin:Math` |
| 19 | `builtin:Number` |
| 18 | `language:global-code` |
| 16 | `builtin:Symbol` |

Counts are sorted by count descending, then raw value ascending. Showing 25 of 49 distinct values.

## Top 25 topic counts

| Count | Value |
|---:|---|
| 206 | `language/statements/class` |
| 173 | `language/eval-code/direct` |
| 142 | `language/statements/with` |
| 115 | `language/expressions/class` |
| 111 | `language/expressions/async-generator` |
| 95 | `built-ins/Array/fromAsync` |
| 95 | `language/expressions/object` |
| 78 | `language/expressions/compound-assignment` |
| 71 | `language/expressions/super` |
| 59 | `built-ins/Object/hasOwn` |
| 56 | `language/statements/async-generator` |
| 48 | `language/statements/function` |
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
| 29 | `built-ins/Function` |
| 28 | `built-ins/Error/prototype/stack` |
| 28 | `built-ins/TypedArray/prototype/findLast` |

Counts are sorted by count descending, then raw value ascending. Showing 25 of 354 distinct values.

## Top 25 raw feature counts

| Count | Value |
|---:|---|
| 457 | `TypedArray` |
| 453 | `async-iteration` |
| 339 | `Symbol.iterator` |
| 327 | `Symbol.asyncIterator` |
| 205 | `BigInt` |
| 190 | `Symbol.species` |
| 151 | `set-methods` |
| 121 | `change-array-by-copy` |
| 115 | `Symbol` |
| 95 | `Array.fromAsync` |
| 87 | `generators` |
| 75 | `await-dictionary` |
| 72 | `globalThis` |
| 63 | `align-detached-buffer-semantics-with-web-reality` |
| 59 | `Object.hasOwn` |
| 59 | `array-find-from-last` |
| 52 | `Reflect.construct` |
| 50 | `async-functions` |
| 49 | `class` |
| 49 | `upsert` |
| 44 | `default-parameters` |
| 44 | `immutable-arraybuffer` |
| 43 | `Symbol.unscopables` |
| 40 | `Float16Array` |
| 38 | `Symbol.replace` |

Counts are sorted by count descending, then raw value ascending. Showing 25 of 86 distinct values.

## Top 25 raw include counts

| Count | Value |
|---:|---|
| 448 | `testTypedArray.js` |
| 336 | `compareArray.js` |
| 294 | `propertyHelper.js` |
| 258 | `detachArrayBuffer.js` |
| 158 | `asyncHelpers.js` |
| 50 | `isConstructor.js` |
| 19 | `nativeErrors.js` |
| 15 | `regExpUtils.js` |
| 9 | `temporalHelpers.js` |
| 3 | `compareIterator.js` |
| 3 | `nativeFunctionMatcher.js` |
| 2 | `byteConversionValues.js` |
| 2 | `decimalToHexString.js` |
| 2 | `proxyTrapsHelper.js` |
| 2 | `wellKnownIntrinsicObjects.js` |

Counts are sorted by count descending, then raw value ascending. All 15 distinct values are shown.
