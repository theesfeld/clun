# STATE

**Derived resume cache** — not process constitution.
**Wins on conflict:** `~/.config/agents/AGENTS.md`, then the canonical GitHub Issue.
Ship path: topic branch → PR → squash-merge into `master` (not direct push).
Update when work completes; keep consistent with the Issue, README, and site.

---

## Current phase: **82 - Purity-compatible Bun-surface final audit and release**  (Release ship #216)

**Canonical issue:** https://github.com/theesfeld/clun/issues/56
**Parent:** https://github.com/theesfeld/clun/issues/177
**Current implementation unit:** Issue #216 pre-tag release hardening, layered on the merged
Issue #234 bounded WebPKI and Issue #235 TLS fatal-alert/close-notify work.
**SemVer impact:** `major` intent, published as the pre-1.0 minor-core transition to `0.2.0`.
**Candidate release:** `0.2.0-dev.1` / `v0.2.0-dev.1`
**Published release:** `0.1.0-dev.21` / `v0.1.0-dev.21`
**Tagged without a GitHub Release:** `v0.1.0-dev.68`, `v0.1.0-dev.69`, and
`v0.1.0-dev.70`; dev.70 is immutable at `0f01413c2922121de142ba732866580e9e070a79`.

**Current integration tree:** Issue #234 is merged at
`456467556c394e4e31b26e19747d25e6ce05a873`; Issue #235 is merged via PR #238 at
`bf96273a28d5c6907c26a887a454a69afdb225b9`; Issue #216 is the current topic unit. No
`v0.2.0-dev.1` tag or GitHub Release exists, and the final ship SHA is not selected yet.

**Public npm status:** the published `v0.1.0-dev.21` binary reproduces the fatal TLS
`protocol_version` failure. The #233 implementation is merged and has live receipts
for both `clun add <pkg>` and Bun-compatible `clun install <pkg>`, a transitive graph, SRI, execution,
and frozen transport-denied reinstall. The compatibility row remains honestly Partial. Issue #233
stays open through final publication proof; #234 WebPKI hardening and #235 fatal-alert/close-notify
wire compliance are merged into this candidate tree.

**Release publication gate:** Issue #216 requires the newest run ID at each exact CI, Documentation,
Compatibility, and Pages workflow path to be a successful push on the exact frozen `master` SHA. The
tag must equal the fetched `origin/master` tip. Staged assets, fresh publication, and every immutable
rerun must contain exactly the four named native archives plus `checksums.txt`, require four exact
checksum records, and pass `sha256sum --check --strict` before success.

**Next scope:** land this single #216 commit through its PR, pass all four workflows on that exact
merged `master` SHA, then and only then create the immutable annotated tag and publish.
