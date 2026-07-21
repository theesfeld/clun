# STATE

**Derived resume cache** — not process constitution.
**Wins on conflict:** `~/.config/agents/AGENTS.md`, then the canonical GitHub Issue.
Ship path: topic branch → PR → squash-merge into `master` (not direct push).

---

## Current unit: **man page install + hard CLI sync rule**

**Canonical issue:** https://github.com/theesfeld/clun/issues/320
**Source candidate:** `0.2.1` / `v0.2.1` (not yet tagged)
**Installer default:** `verified_installer_tag=v0.2.0` (last published until `v0.2.1` assets land)
**SemVer impact:** `patch`
**Program context:** Phase 26 complete (first stable `0.2.0`); this unit ships `man clun` packaging.

### Scope
- Catalog-driven `docs/man/clun.1` (`src/cli/catalog.lisp` + `clun --emit-man`)
- Hard rule: man always matches live CLI (`make man-check` in CI + release)
- Package `share/man/man1/clun.1`; installer stages XDG man path

### Next after merge
- Tag `v0.2.1` on master merge SHA when four-target release gates green
- Publication reconcile: ledger `published`, installer default → `v0.2.1`

---
