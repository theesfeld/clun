# STATE

**Derived resume cache** — not process constitution.
**Wins on conflict:** `~/.config/agents/AGENTS.md`, then the canonical GitHub Issue.
Ship path: topic branch → PR → squash-merge into `master` (not direct push).

---

## Current phase: **26 - Final hardening (published beta.2)**

**Canonical issue:** https://github.com/theesfeld/clun/issues/58
**Program phase:** 26
**Published surface tip:** `0.2.0-beta.2` / `v0.2.0-beta.2`
**Installer default:** `verified_installer_tag=v0.2.0-beta.2`
**SemVer impact:** `patch` (shipped)
**Release commit:** `d995e3150346421d668931f8efc483e38eaeffc7`
**Release run:** https://github.com/theesfeld/clun/actions/runs/29793525055

### Shipped in beta.2 (#58 residual / #304)
- Maturity-aware update channel rank (dev < alpha < beta < rc)
- TLS session-ticket clear between multi-asset fetches + curl recovery
- TTY update-available notice on --version / --help

### Gates
Publication: tag + four-arch assets + checksums green. Installer/default reconcile in this unit.

---
