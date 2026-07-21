# STATE

**Derived resume cache** — not process constitution.
**Wins on conflict:** `~/.config/agents/AGENTS.md`, then the canonical GitHub Issue.
Ship path: topic branch → PR → squash-merge into `master` (not direct push).

---

## Current phase: **26 - Final hardening residual / updater fix**

**Canonical issue:** https://github.com/theesfeld/clun/issues/304
**Program phase:** 26 (closed for hardening beta.1; residual updater bugs)
**Published surface tip:** `0.2.0-beta.1` / `v0.2.0-beta.1`
**Candidate release:** `0.2.0-beta.2` / `v0.2.0-beta.2`
**Installer default (until beta.2 assets):** `verified_installer_tag=v0.2.0-beta.1`
**SemVer impact:** `patch`

### Scope (Issue #304)
- Prefer Clun maturity rank (`dev` < `alpha` < `beta` < `rc` < stable) when selecting update targets
- Clear TLS session tickets between multi-asset update fetches
- Human recovery text for TLS update failures (curl reinstall)
- TTY update-available notice on `--version` / `--help` (12h cache)

### Gates
`make build` · focused update tests · `make public-claims-check` · CI

---
