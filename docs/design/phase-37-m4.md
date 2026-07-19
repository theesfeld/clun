# Phase 37 Milestone 4 - Keyed Promise combinators

Status: accepted for implementation as the fourth bounded Phase 37 milestone.

## Objective and boundary

This milestone implements `Promise.allKeyed` and `Promise.allSettledKeyed` — the
largest remaining Phase 37 residual feature cluster after milestones 1–3
(74 frozen failing execution rows under the TC39 await-dictionary proposal).

| Built-in | Frozen failing rows |
| --- | ---: |
| `Promise.allKeyed` | 38 |
| `Promise.allSettledKeyed` | 36 |
| **Total** | **74** |

The frozen execution source is Test262 commit
`d1d583db95a521218f3eb8341a887fd63eda8ff1`. The selection is the `exec-gaps.tsv`
rows under those two topics, excluding one harness-destructive
`allSettledKeyed/result-property-descriptors.js` row (Test262 `propertyHelper`
`isConfigurable` deletes the parent property before the fixture re-reads
`result.fulfilled`; not an engine semantic gap). Manifest:
`tests/conformance/phase-37-m4-paths.txt` with sorted path SHA-256
`29621a93d20294a4347afe2fea77eecce08df71d79a1072ad713e0a7d869582b`.

This milestone does not implement remaining Phase 37 residuals (RegExp.escape,
groupBy, Float16, WeakRef, upsert, error-stack, immutable ArrayBuffer, etc.),
change the public compatibility ledger, claim completion of Phase 37, or promote
a matrix Yes row. Full exec-passlist reclassification may land in the same unit
when public-claims freezes require it; otherwise it is deferred.

## Semantics

Both methods (constructor `C` = `this`):

1. `NewPromiseCapability(C)` — non-constructor receivers throw TypeError.
2. `GetPromiseResolve(C)` — missing/non-callable `resolve` rejects the result.
3. If `promises` is not an Object, reject with TypeError (do not throw).
4. `PerformPromiseAllKeyed(variant, promises, C, capability, promiseResolve)`:
   - `allKeys = promises.[[OwnPropertyKeys]]()`
   - for each key with enumerable own descriptor: Get value, `Call(resolve, C, «value»)`,
     attach then reactions indexed into an entries list
   - `allKeyed`: on reject of any element → reject the result; on all fulfill → resolve
   - `allSettledKeyed`: never rejects from element settlement; each entry is
     `{status, value}` / `{status, reason}` on `%Object.prototype%`
5. Result object is `OrdinaryObjectCreate(null)` with data properties in
   enumerable key order (`CreateKeyedPromiseCombinatorResultObject`).
6. Non-constructible; length 1; ordinary built-in property attributes.

## Architecture

- Extend `src/engine/async/promise.lisp` only.
- Reuse `new-promise-capability`, `promise-then-generic`, `%settled-record`,
  `jm-own-property-keys`, `jm-get-own-property`, and IfAbruptRejectPromise.
- Pure Common Lisp; no CFFI, fixture-specific dispatch, or skip-list changes.

## Evidence and gates

1. `make phase-37-m4-check`: 74/74 pass, 0 fail/skip/tmo/crash.
2. Focused Lisp assertions cover descriptors, key order, null-proto result,
   allSettledKeyed status objects, non-object reject, and non-constructor this.
3. `make build`, focused tests, `make purity` pass.
4. Phase 37 stays open; measured residual ownership after m4 is **378** fail
   rows when pass-list is reclassified (452 − 74), still not a matrix Yes.

## SemVer

Backward-compatible public built-ins → **minor** within the `0.1.0-dev.N` train.
This candidate stages **`0.1.0-dev.63` / `v0.1.0-dev.63`** under Issue #11 (next
free concurrent slot after master tip `0.1.0-dev.59` (avoids open SFE train on `.57`)). Installer default stays on published
`v0.1.0-dev.21` (last published tag; unpublished-gap policy). No compatibility-table
**Yes** claim.
