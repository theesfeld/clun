# STATE

**Derived resume cache** — not process constitution.
**Wins on conflict:** `~/.config/agents/AGENTS.md`, then the canonical GitHub Issue.
Ship path: topic branch → PR → squash-merge into `master` (not direct push).

---

## Current phase: **26 - First stable 0.2.0**

**Canonical issue:** https://github.com/theesfeld/clun/issues/58
**Program phase:** 26
**Published surface tip (until tag):** `0.2.0-beta.2` / `v0.2.0-beta.2`
**Candidate release:** `0.2.0` / `v0.2.0`
**Installer default (until assets):** `verified_installer_tag=v0.2.0-beta.2`
**SemVer impact:** `minor` (first stable / maturity promotion)
**Base:** published `0.2.0-beta.2`

### Scope
- Stage and publish first stable `0.2.0` (non-prerelease GitHub Release, `latest`)
- Do **not** delete or move historical `v0.2.0-beta.*` tags
- Close Phase 26 when tag + assets + installer reconcile + issue complete

### Gates
`make phase-26-gate` · `make build` · `make test` · `make purity` · public-claims · exact-master CI/Docs/Compat/Pages · Release matrix

---

---
