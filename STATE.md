# STATE

**Derived resume cache** — not process constitution.
**Wins on conflict:** `~/.config/agents/AGENTS.md`, then the canonical GitHub Issue.
Ship path: topic branch → PR → squash-merge into `master` (not direct push).
Update when work completes; keep consistent with the Issue, README, and site.

---

## Current phase: **82 - Purity-compatible Bun-surface final audit and release**  (Release ship #216)

**Canonical issue:** https://github.com/theesfeld/clun/issues/56
**Parent:** https://github.com/theesfeld/clun/issues/177
**Current implementation unit:** Issue #235 TLS fatal-alert and close-notify compliance, layered on
the completed Issue #234 bounded WebPKI tree.
**SemVer impact:** `major` intent, published as the pre-1.0 minor-core transition to `0.2.0`.
**Candidate release:** `0.2.0-dev.1` / `v0.2.0-dev.1`
**Published release:** `0.1.0-dev.21` / `v0.1.0-dev.21`
**Tagged without a GitHub Release:** `v0.1.0-dev.68`, `v0.1.0-dev.69`, and
`v0.1.0-dev.70`; dev.70 is immutable at `0f01413c2922121de142ba732866580e9e070a79`.

**Current integration base:** Issue #234 completed at
`f03fc0c2f71a31e81d8a0ca943fa91bb0f833ea7`; Issue #235 is the current topic branch.

**Public npm release blocker:** the published `v0.1.0-dev.21` binary reproduces the fatal TLS
`protocol_version` failure, while the current source succeeds through its bounded TLS 1.2 fallback.
Issue #233 supplied live receipts for both `clun add <pkg>` and `clun install <pkg>`, SRI, execution,
and frozen offline reinstall; Issue #234 completed the bounded WebPKI profile; Issue #235 adds
one-shot fatal alerts and reciprocal clean closure. The package-manager row remains honestly Partial
because npm publishing and the full registry-auth/publishing corpus are not implemented.

**Next scope:** land Issue #235, require exact push-event CI, Documentation, four-target Compatibility,
and Pages on the resulting frozen master, then create the immutable release tag only from that exact
green commit.
