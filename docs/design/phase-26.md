# Phase 26 — Final hardening, docs, and release

**Canonical issue:** [#58](https://github.com/theesfeld/clun/issues/58)  
**Status:** active → first stable `0.2.0`  
**Deps:** Phase 82 (#56) complete

## Goal

Harden and publish the post–Phase-82 system as the first **beta** prerelease of the `0.2.0` core.

## Non-goals

- Stable `0.2.0` (later unit)
- Matrix expansion (30 Yes remains the bar)
- Full Darwin multi-hour soak (deterministic fix already shipped; four-platform CI is the beta gate)
- Third-party WebPKI audit claims
- TZif local-time implementation (unassigned)

## SemVer

| Field | Value |
|-------|--------|
| Impact | `minor` (maturity promotion + hardening; no intentional API expansion) |
| From | published `0.2.0-dev.11` |
| To | `0.2.0-beta.1` / `v0.2.0-beta.1` |
| Note | Same core; prerelease **prefix** advances `dev` → `beta` at `.1` (version-transition maturity ladder) |

## Finite checklist

See Issue #58 and `STATE.md`. Executable gate:

```bash
make phase-26-gate
```

## Hardening smokes (`scripts/phase-26-hardening-smokes.sh`)

1. **Backtrace discipline** — missing file + JS throw never leak SBCL debugger without `--backtrace`
2. **Resource plateau** — 400 write/read/unlink cycles without crash
3. **Interruption** — SIGINT stops a live timer loop without Lisp noise
4. **Partial-install** — bogus `clun add` fails with human error; package root remains intact
5. **Long-run server** — ~1.2s `Clun.serve` + fetch loop then clean `stop`

## Evidence order

1. Local `make phase-26-gate`
2. PR CI (build-test-purity, claims, docs)
3. Squash-merge to `master`
4. Exact-SHA CI / Documentation / Compatibility green
5. Annotated tag `v0.2.0-beta.1` on that SHA
6. Release assets + checksums
7. Reconcile installer default + `publication_state=published`
8. Close #58 with receipts
