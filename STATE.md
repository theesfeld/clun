# STATE

**Derived resume cache** — not process constitution.
**Wins on conflict:** `~/.config/agents/AGENTS.md`, then the canonical GitHub Issue.
Ship path: topic branch → PR → squash-merge into `master` (not direct push).
Update when work completes; keep consistent with the Issue, README, and site.

---

## Current phase: **59 - Package registry and dependency-spec breadth**  (YES CONVERSION #131)

**Canonical issue:** https://github.com/theesfeld/clun/issues/131
**Parallel compatibility issues:** https://github.com/theesfeld/clun/issues/33,
https://github.com/theesfeld/clun/issues/2, https://github.com/theesfeld/clun/issues/34,
and https://github.com/theesfeld/clun/issues/35
**Current implementation unit:** `package-manager.npm` Partial→Yes (#131).
`package-manager.npm` is **Yes** — `clun install`/`add`/`remove` with registry packages (semver
ranges, dist-tags), npm: aliases, file:/link: local packages, optionalDependencies soft-fail,
hoisted node_modules, clun.lock offline reinstall, SRI-verified tarballs, and four-target hermetic
install receipts. Workspaces remain `package-manager.monorepo` No; publish and git-deps stay Phase
61/59 residual outside this Yes claim (Bun matrix Yes is install-class; Deno Partial for publish).
**SemVer impact:** `minor`
**Candidate release:** `0.1.0-dev.44` / `v0.1.0-dev.44`
**Published release:** `0.1.0-dev.21` / `v0.1.0-dev.21`
**Entry boundary:** installer on `v0.1.0-dev.21`; this unit stages `0.1.0-dev.44` after master tip
`0.1.0-dev.43` (server.http Yes #128).
**Next scope:** fleet Yes queue; monorepo / publish / git+ssh remain separate phases.

