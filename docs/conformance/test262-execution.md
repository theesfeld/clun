# test262 execution failure buckets

This is a deterministic analysis of the authoritative execution classification ledger. Only `fail` rows contribute to the bucket and tag counts.

## Provenance

| Item | Value |
|---|---|
| generator | `scripts/test262-buckets.lisp` |
| vendor-test262-commit | `d1d583db95a521218f3eb8341a887fd63eda8ff1` |
| source-revision | `working-tree@9c46a3d63c058ec85df1a70c19340f7cbb1c5fd9` |
| classification-ledger | `tmp-test/p25b-m2-final-classifications.tsv` |
| frozen-passlist | `tests/conformance/exec-passlist.txt` |
| classification-ledger-fnv-1a-64 | `72AB4ABE50DA227B` |

The digest is FNV-1a-64 over the ledger's exact input bytes; it is not SHA.

## Exact coverage target

| Measure | Exact value |
|---|---:|
| Total | 40654 |
| Pass | 22862 |
| Fail | 5301 |
| Skip | 12491 |
| Crash | 0 |
| Eligible (`pass + fail`) | 28163 |
| Pass rate | 22862 / 28163 = 81.177431% |
| Frozen baseline pass count | 22862 |
| Current-pass delta from frozen baseline | +0 |
| `ceil(90% * eligible)` | 25347 |
| Required pass lift | 2485 |

## Phase-owner counts

| Phase owner | Fail rows |
|---|---:|
| `phase-25b` | 4416 |
| `phase-37` | 885 |

Phase ownership is orthogonal to the implementation work buckets below.

## Work-bucket counts

| Order | Work bucket | Fail rows |
|---:|---|---:|
| 1 | `binding-patterns` | 1412 |
| 2 | `dynamic-scope-eval` | 319 |
| 3 | `async-iteration` | 561 |
| 4 | `async-generators` | 1 |
| 5 | `generators` | 108 |
| 6 | `classes` | 190 |
| 7 | `binary-data` | 690 |
| 8 | `regexp` | 237 |
| 9 | `iterator-protocol` | 85 |
| 10 | `promises` | 117 |
| 11 | `collections` | 255 |
| 12 | `arrays` | 346 |
| 13 | `objects` | 137 |
| 14 | `functions-arguments` | 215 |
| 15 | `operators-references` | 186 |
| 16 | `primitive-builtins` | 241 |
| 17 | `other-runtime` | 201 |

The work buckets are mutually exclusive, first-match wins, and their counts sum to 5301.

## Top 25 owner counts

| Count | Value |
|---:|---|
| 1445 | `language:statements` |
| 1255 | `language:expressions` |
| 436 | `builtin:Array` |
| 396 | `builtin:TypedArray` |
| 217 | `builtin:RegExp` |
| 194 | `language:eval-code` |
| 163 | `builtin:Set` |
| 153 | `builtin:Promise` |
| 145 | `builtin:DataView` |
| 125 | `builtin:Object` |
| 75 | `builtin:Function` |
| 71 | `builtin:TypedArrayConstructors` |
| 64 | `builtin:Date` |
| 53 | `builtin:Map` |
| 53 | `builtin:String` |
| 49 | `builtin:ArrayBuffer` |
| 44 | `builtin:WeakMap` |
| 42 | `builtin:Error` |
| 40 | `language:arguments-object` |
| 28 | `builtin:AsyncGeneratorPrototype` |
| 26 | `builtin:JSON` |
| 24 | `builtin:Symbol` |
| 20 | `builtin:Math` |
| 20 | `language:global-code` |
| 19 | `builtin:Number` |

Counts are sorted by count descending, then raw value ascending. Showing 25 of 52 distinct values.

## Top 25 topic counts

| Count | Value |
|---:|---|
| 430 | `language/statements/class` |
| 338 | `language/expressions/class` |
| 230 | `language/statements/for-await-of` |
| 207 | `language/expressions/object` |
| 187 | `language/expressions/async-generator` |
| 181 | `language/statements/for-of` |
| 177 | `language/eval-code/direct` |
| 142 | `language/statements/with` |
| 95 | `built-ins/Array/fromAsync` |
| 94 | `language/statements/async-generator` |
| 85 | `language/expressions/assignment` |
| 85 | `language/statements/function` |
| 78 | `language/expressions/compound-assignment` |
| 71 | `language/expressions/super` |
| 59 | `built-ins/Object/hasOwn` |
| 56 | `language/expressions/generators` |
| 54 | `language/statements/for` |
| 52 | `language/expressions/function` |
| 48 | `language/expressions/arrow-function` |
| 48 | `language/statements/generators` |
| 47 | `built-ins/TypedArrayConstructors/internals` |
| 44 | `built-ins/TypedArray/prototype/slice` |
| 39 | `built-ins/Array/prototype/concat` |
| 38 | `built-ins/Promise/allKeyed` |
| 38 | `built-ins/RegExp/prototype/Symbol.replace` |

Counts are sorted by count descending, then raw value ascending. Showing 25 of 389 distinct values.

## Top 25 raw feature counts

| Count | Value |
|---:|---|
| 1030 | `destructuring-binding` |
| 983 | `async-iteration` |
| 767 | `generators` |
| 689 | `Symbol.iterator` |
| 476 | `TypedArray` |
| 358 | `default-parameters` |
| 336 | `Symbol.asyncIterator` |
| 214 | `BigInt` |
| 192 | `Symbol.species` |
| 170 | `Symbol` |
| 151 | `set-methods` |
| 123 | `change-array-by-copy` |
| 95 | `Array.fromAsync` |
| 75 | `await-dictionary` |
| 73 | `class` |
| 72 | `globalThis` |
| 63 | `align-detached-buffer-semantics-with-web-reality` |
| 61 | `array-find-from-last` |
| 59 | `Object.hasOwn` |
| 52 | `Reflect.construct` |
| 50 | `async-functions` |
| 49 | `upsert` |
| 44 | `immutable-arraybuffer` |
| 43 | `Symbol.unscopables` |
| 40 | `Float16Array` |

Counts are sorted by count descending, then raw value ascending. Showing 25 of 97 distinct values.

## Top 25 raw include counts

| Count | Value |
|---:|---|
| 461 | `testTypedArray.js` |
| 412 | `propertyHelper.js` |
| 342 | `compareArray.js` |
| 258 | `detachArrayBuffer.js` |
| 159 | `asyncHelpers.js` |
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
