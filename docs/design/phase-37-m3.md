# Phase 37 Milestone 3 - Set methods

Status: accepted for implementation as the third bounded Phase 37 milestone.

## Objective and boundary

This milestone implements the seven ES2025 `Set.prototype` set-methods — the
largest remaining Phase 37 residual feature cluster after milestones 1 and 2
(151 frozen failing execution rows under `set-methods`).

| Built-in | Frozen failing rows |
| --- | ---: |
| `Set.prototype.union` | 24 |
| `Set.prototype.intersection` | 23 |
| `Set.prototype.difference` | 23 |
| `Set.prototype.symmetricDifference` | 23 |
| `Set.prototype.isSubsetOf` | 18 |
| `Set.prototype.isSupersetOf` | 20 |
| `Set.prototype.isDisjointFrom` | 20 |
| **Total** | **151** |

The frozen execution source is Test262 commit
`d1d583db95a521218f3eb8341a887fd63eda8ff1`. The selection is the exact set of
`exec-gaps.tsv` rows whose topic is one of the seven method directories above,
preserved in the immutable `tests/conformance/phase-37-m3-paths.txt` manifest
with sorted path SHA-256
`f1eab29419cbd5ed293797f0c37bec4141bccd34af4115874920734ca4a659f2`.

This milestone does not implement remaining Phase 37 residuals (keyed Promise
combinators, RegExp.escape, groupBy, Float16, WeakRef, upsert, error-stack,
immutable ArrayBuffer, etc.), change the public compatibility ledger, claim
completion of Phase 37, or promote a matrix Yes row. Full exec-passlist
reclassification is deferred to the release/integration unit unless required
for a green gate here.

## Semantics

All seven methods:

1. Require the receiver to be a Set (`[[SetData]]` / `js-set-p`).
2. Call `GetSetRecord(other)`: object with `size` (ToNumber → NaN TypeError,
   negative RangeError), callable `has`, callable `keys` — all observed even
   when a given algorithm never invokes `has` or `keys`.
3. Accept Set-like objects and Maps; reject arrays and primitives.
4. Compare `SetDataSize(this)` with `otherRecord.[[Size]]` to choose the
   cheaper iteration strategy for intersection / difference / isDisjointFrom.
5. Canonicalize keys with SameValueZero (`-0` → `+0`).
6. Constructing methods return an ordinary Set with `%Set.prototype%` — never
   `Symbol.species` and never a subclass instance. They write `[[SetData]]`
   directly and never call `Set.prototype.add`.

| Method | Core contract |
| --- | --- |
| `union` | Copy this; append keys from other not already present |
| `intersection` | If this ≤ other: has-walk this; else keys-walk other |
| `difference` | Copy this (after GetSetRecord); remove via has or keys |
| `symmetricDifference` | Copy this; toggle membership from other keys |
| `isSubsetOf` | Early false if this.size > other.size; else has-walk |
| `isSupersetOf` | Early false if this.size < other.size; else keys-walk + IteratorClose |
| `isDisjointFrom` | has-walk or keys-walk with early exit + IteratorClose |

## Architecture

- Extend `src/engine/builtins-collections.lisp` only.
- Reuse existing map/set data (`md-*`), SameValueZero keys, iterator records,
  and `IteratorClose` / `GetIteratorFromMethod` via `get-iterator-record`.
- Pure Common Lisp; no CFFI, fixture-specific dispatch, or skip-list changes.

## Evidence and gates

1. `make phase-37-m3-check`: 151/151 pass, 0 fail/skip/tmo/crash.
2. Focused Lisp assertions cover descriptors, combinators, Set-like objects,
   species/subclass, `-0`, and GetSetRecord errors.
3. `make build`, focused tests, `make purity` pass.
4. Phase 37 stays open; measured residual ownership after m3 is **452** fail
   rows when pass-list is reclassified (603 − 151), still not a matrix Yes.

## SemVer

Backward-compatible public built-ins → **minor** within the `0.1.0-dev.N` train.
This candidate stages **`0.1.0-dev.23` / `v0.1.0-dev.23`** under Issue #11 (do
not steal `dev.18`/`dev.19`/`dev.20`/`dev.21`/`dev.22` owned by
shell/test-runner/transport/m2/transport-reslot). Installer default stays on
published `v0.1.0-dev.18`. No compatibility-table **Yes** claim.
