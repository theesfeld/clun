# STATE

**Derived resume cache** — not process constitution.
**Wins on conflict:** `~/.config/agents/AGENTS.md`, then the canonical GitHub Issue.
Ship path: topic branch → PR → squash-merge into `master` (not direct push).

---

## Current phase: **26 - COMPLETE (minor 0.3.0 published)**

**Canonical issue:** https://github.com/theesfeld/clun/issues/58
**Program phase:** 26 (complete)
**Published surface tip:** `0.3.0` / `v0.3.0`
**Installer default:** `verified_installer_tag=v0.3.0`
**SemVer impact:** `minor` (shipped)
**Release commit:** `ef20681c87864f554d8224f69743cc8488e38176`
**Release run:** https://github.com/theesfeld/clun/actions/runs/30307908392

### Shipped
- SharedArrayBuffer + Atomics + real worker_threads (#338 / PR #340)
- Zero-stubs inventory closed (#339 / PR #341): no product hollow exports
- NASA operator SOP + release memo 0.3.0; README/site Documents links
- Scene card `file_id.diz`
- Four native archives + `checksums.txt` on GitHub Release `v0.3.0`
- Installer and `clun --update` boundary advanced to `v0.3.0`

### Gates
Exact-master CI + Documentation + Compatibility → annotated tag `v0.3.0` → Release assets → publication reconcile.

### Notes
- GitHub Release for this repo is immutable and `verify-assets` requires exactly five assets (four archives + checksums). SOP/memo/DIZ remain tracked in-repo and linked from README/site; attach at create would require a future release-workflow + verify-assets change.
