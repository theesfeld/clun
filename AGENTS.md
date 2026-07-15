# Clun Agent Instructions

The keyword `phase` is a complete execution request.

When the user's message is exactly `phase`, read `PHASE_PROMPT.md` and execute it for the current
phase or milestone recorded in `STATE.md`. When the message is `phase NN`, execute the same prompt
for Phase NN after verifying that its dependencies are complete. Do not require the user to paste
the long prompt again.

These instructions apply to the Clun repository, excluding nested directories with their own
`AGENTS.md` instructions.

## Canonical phase tracking

Every active or planned phase and independently tracked defect must have a GitHub issue. A phase
issue may canonically track all of that phase's milestones unless a milestone is explicitly split
into its own issue. The matching phase or defect issue is the canonical source of truth for live scope,
status, blockers, decisions, measured evidence, and completion. `PLAN.md` remains the technical
contract and `STATE.md` remains the local resume checklist; neither may silently disagree with the
canonical issue.

Keep the issue, `README.md`, and `site/index.html` synchronized in the same completed unit whenever
behavior, compatibility, roadmap status, counts, or claims change. There must never be a publication
gap between those three surfaces. Keep the issue body current for live scope and status, and add
substantive issue comments for implementation decisions, diagnosed residuals, gate results, commit
hashes, and deployment status. Create or update the issue before implementation if necessary, and
close it only when its complete scope and acceptance gates are actually finished.

## Release versioning

Follow the authoritative workflow and publication order in [`docs/versioning.md`](docs/versioning.md).
Treat SemVer disposition as part of the canonical issue record for every completed unit. Before a
push, record both the impact and target version in the applicable issue, with a rationale when the
classification is not self-evident:

- a breaking public interface or behavior change is `major`;
- backward-compatible functionality is `minor`;
- a backward-compatible bug-only change is `patch`;
- a mixed unit takes the highest applicable impact.

Select `X.Y.Z` from the actual completed work, not from push count. Once an unreleased release train
has selected its core version, each later published release unit in that train retains the core and
increments only the numeric prerelease sequence unless the actual completed work requires a
higher-impact core. Corrective commits made before that unit's immutable tag exists do not advance
the sequence by themselves. The Phase 25b compatibility program
targets the existing planned `0.1.0` release: its first behavioral milestone is `0.1.0-dev.1`, later
published milestones are `0.1.0-dev.2`, `0.1.0-dev.3`, and so on, and Phase 26 stabilizes `0.1.0` by
removing the prerelease suffix. A documentation-only push with no behavior or public release-claim
change may record impact `none` and leave the source version unchanged only when its canonical issue
records why no version change is warranted.

When behavior or public release claims change, update `src/version.lisp`, the ASDF core version,
version tests, installer default, README, and site consistently before pushing. Push the completed
commit to `origin/master` and wait for required master checks to pass before creating the immutable
`v<version>` tag. After the tag workflow finishes, verify the GitHub release assets, checksums, and
the shell installer on the supported current system, then record the tag, asset evidence, and
installer result in the canonical issue. Never move or reuse a release tag.
