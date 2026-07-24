# STATE

**Derived resume cache** — not process constitution.
**Wins on conflict:** `~/.config/agents/AGENTS.md`, then the canonical GitHub Issue.
Ship path: topic branch → PR → squash-merge into `master` (not direct push).

---

## Current phase: **46 - Processes, VM, workers, zero-stubs closed**

**Canonical issue:** https://github.com/theesfeld/clun/issues/339
**Related:** https://github.com/theesfeld/clun/issues/338 · PR https://github.com/theesfeld/clun/pull/340 · PR https://github.com/theesfeld/clun/pull/341
**Program note:** Phase 26 patch `0.2.2` remains the last **published** installable boundary.
**Source candidate:** `0.3.0` / `v0.3.0` (candidate; not published)
**Installer default:** `verified_installer_tag=v0.2.2`
**SemVer impact:** `minor` (shared-memory multithreading + zero-stubs completion)

### Shipped
- SharedArrayBuffer + Atomics + real worker_threads (#338)
- Zero-stubs inventory closed (#339): exported hollow no-ops destubbed or documented intentional design no-ops only
- Source version staged `0.3.0` candidate; installer stays on published `v0.2.2`

### Gates
`make build`, `make test`, `make purity`, `make public-claims-check` when claims/docs change, version-transition for release-bearing units.
