# Phase 37 Milestone 2 - Array.fromAsync

Status: accepted for implementation as the second bounded Phase 37 milestone.

## Objective and boundary

This milestone implements `Array.fromAsync` — the largest single Phase 37 residual
topic after milestone 1 (95 frozen failing execution rows under
`built-ins/Array/fromAsync`).

| Built-in | Frozen failing rows |
| --- | ---: |
| `Array.fromAsync` | 95 |

The frozen execution source is Test262 commit
`d1d583db95a521218f3eb8341a887fd63eda8ff1`. The selection is the exact set of
`exec-gaps.tsv` rows whose topic is `built-ins/Array/fromAsync`, preserved in the
immutable `tests/conformance/phase-37-m2-paths.txt` manifest with sorted path
SHA-256 `71f6f51fe104c05baf68ff94e337a3b6e3a35ed8f86eb1fafc4dedd72a2ab12f`.

This milestone does not implement the remaining Phase 37 residuals (keyed Promise
combinators, set methods, RegExp.escape, groupBy, Float16, WeakRef, etc.), change
the public compatibility ledger, claim completion of Phase 37, or promote a
matrix Yes row.

## Semantics

`Array.fromAsync(asyncItems [, mapfn [, thisArg ]])` is a built-in async method:

1. Always returns a Promise whose prototype is the intrinsic Promise.prototype.
2. Uses intrinsic `@@asyncIterator` / `@@iterator` (not the global `Symbol` object).
3. Prefer async iteration; else sync iteration via CreateAsyncFromSyncIterator;
   else treat `asyncItems` as array-like.
4. Async-iterable values are **not** awaited unless `mapfn` is present (mapfn
   result is always awaited). Sync-iterable values are adopted by AsyncFromSync.
   Array-like element gets are always awaited.
5. The `this` value is used as the result constructor when `IsConstructor`; else
   an ordinary Array is created. Iterable path constructs with no arguments;
   array-like path constructs with the length.
6. Mapping and CreateDataPropertyOrThrow failures close an open async iterator
   via AsyncIteratorClose.
7. Non-constructible; length 1; ordinary built-in property attributes.

## Architecture

- Extend `src/engine/builtins-array.lisp`; reuse existing Promise,
  coroutine/await, async-iterator, and AsyncFromSync machinery.
- Drive the body with `start-async-function` + `await-value` so Await is the same
  microtask path as user async functions.
- Nine observation-order controls include `temporalHelpers.js`, which requires
  nullish coalescing (`??`) and numeric separators (`1_000n`) in the harness
  text. Lexer/parser already had an emitter path for `??`; this milestone
  admits `??` tokens and NumericLiteralSeparator so the harness parses. The
  parse-phase skip tags for those features remain (no silent parse pass-list
  expansion).
- Pure Common Lisp; no CFFI, fixture-specific dispatch, or skip-list changes.

## Evidence and gates

1. `make phase-37-m2-check`: 95/95 pass, 0 fail/skip/tmo/crash.
2. Focused Lisp assertions cover promise shape, constructor/thisArg, async and
   array-like inputs, mapping, and rejection.
3. `make build`, focused tests, `make purity` pass.
4. Pass-list remains monotonic when updated by the release/integration unit.
5. Phase 37 stays open; residual ownership after m2 is **708 − 95 = 613** if the
   full corpus reclassifies exactly those paths (measured at gate time).

## SemVer

Backward-compatible public built-in → **minor** within the `0.1.0-dev.N` train.
Release version assignment is owned by the release unit; reserved slots
`dev.18`/`dev.19` must not be stolen — target **`0.1.0-dev.20+`**. This
implementation branch does not bump version files or public claims.
