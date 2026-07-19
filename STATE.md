# STATE

**Derived resume cache** — not process constitution.
**Wins on conflict:** `~/.config/agents/AGENTS.md`, then the canonical GitHub Issue.
Ship path: topic branch → PR → squash-merge into `master` (not direct push).
Update when work completes; keep consistent with the Issue, README, and site.

---

## Current phase: **82 - Purity-compatible Bun-surface final audit and release**  (Release ship #216)

**Canonical issue:** https://github.com/theesfeld/clun/issues/56
**Parent:** https://github.com/theesfeld/clun/issues/177
**Current implementation unit:** Issue #233 public npm usability and publication-truth repair.
**SemVer impact:** `major` intent, published as the pre-1.0 minor-core transition to `0.2.0`.
**Candidate release:** `0.2.0-dev.1` / `v0.2.0-dev.1`
**Published release:** `0.1.0-dev.21` / `v0.1.0-dev.21`
**Tagged without a GitHub Release:** `v0.1.0-dev.68`, `v0.1.0-dev.69`, and
`v0.1.0-dev.70`; dev.70 is immutable at `0f01413c2922121de142ba732866580e9e070a79`.

**Current master:** PR #232 merged at `fe6aeab0c67907eb78c0c9347944a28de8b29c51`, restoring
exact-master push-event CI evidence after the workflow-bearing PR #230 merge at
`795fad8acc3d61183c92dfa98db15b97144be38c` emitted no push-event check suite.

**Public npm release blocker:** the published `v0.1.0-dev.21` binary reproduces the fatal TLS
`protocol_version` failure, while current master succeeds through its experimental bounded TLS 1.2 fallback.
Issue #233 owns live receipts for both `clun add <pkg>` and `clun install <pkg>`, SRI, execution, and
frozen offline reinstall, plus the honest Partial compatibility disposition. Issue #234 WebPKI
hardening and npm publishing remain release blockers.

**Next scope:** land Issue #233, require exact push-event CI, Documentation, four-target Compatibility,
and Pages on the resulting frozen master, then create the immutable release tag only from that exact
green commit.
