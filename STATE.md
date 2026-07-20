# STATE

**Derived resume cache** — not process constitution.
**Wins on conflict:** `~/.config/agents/AGENTS.md`, then the canonical GitHub Issue.
Ship path: topic branch → PR → squash-merge into `master` (not direct push).
Update when work completes; keep consistent with the Issue, README, and site.

---

## Current phase: **82 - Purity-compatible Bun-surface final audit and release**

**Canonical issue:** https://github.com/theesfeld/clun/issues/56
**Parent:** https://github.com/theesfeld/clun/issues/177
**Release issue:** https://github.com/theesfeld/clun/issues/216
**Current implementation unit:** Issue #241 deterministic fresh-hoist materialization recovery.
**SemVer impact:** `patch` for this recovery unit inside Phase 82's `major`-intent pre-1.0
minor-core transition to `0.2.0`.
**Candidate release:** `0.2.0-dev.2` / `v0.2.0-dev.2`
**Published release:** `0.1.0-dev.21` / `v0.1.0-dev.21`
**Tagged without a GitHub Release:** `v0.1.0-dev.68`, `v0.1.0-dev.69`,
`v0.1.0-dev.70`, and `v0.2.0-dev.1`. The latter has tag object
`a5a15cf0cbbff8187bb12a3ecb7ee8e0a40de5bc`, peels to exact master
`184dfa13577ae6f24a7e6dde785a824ef46aa373`, and has no Release or assets.

**Current integration tree:** `master` is `184dfa13577ae6f24a7e6dde785a824ef46aa373`.
Issues #234 and #235 are merged and closed; Issue #216's hardening PR #240 is merged, while #216
remains open for dev.2 publication. The `v0.2.0-dev.1` release run passed Linux x64/arm64 and macOS
arm64 but failed macOS x64 because concurrent download completion could extract a nested dependency
before its parent, whose later atomic extraction erased it. The publish job was skipped. Issue #241
keeps downloads concurrent and serializes materialization in stable
ancestor-before-descendant order independent of lockfile member order, with completed bodies held in
the verified cache or a cleaned lazy disk spool.

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

**Next scope:** land Issue #241 through its PR after the deterministic regression and complete local
gates pass; prove all four workflows on the exact merged `master` SHA; then and only then create the
new immutable annotated `v0.2.0-dev.2` tag and publish. Never move, delete, or reuse
`v0.2.0-dev.1`. Issue #239 performs post-publication reconciliation without changing tag or asset
identity.
