# Release Versioning

Clun uses [Semantic Versioning 2.0.0](https://semver.org/) for every published source version,
tag, archive, installer default, and public release claim. Version selection is based on the actual
completed unit of work, not the number of commits or pushes.

## Impact classification

Classify the completed unit before it is pushed:

- `major`: an incompatible change to a public interface or documented behavior;
- `minor`: backward-compatible public functionality;
- `patch`: a backward-compatible bug fix with no new public functionality;
- `none`: documentation or internal automation only, with no behavior or public release-claim
  change. The canonical GitHub issue must explain why no version change is warranted.

A unit containing more than one kind of change takes the highest applicable impact. A public API
addition plus bug fixes is therefore `minor`, not `patch`.

## Prerelease trains

First select the SemVer core `X.Y.Z` from the impact. A prerelease suffix describes maturity within
that already selected release train; it does not replace the impact decision. Each new published
release unit in the same unreleased scope keeps the core and increments only the numeric sequence,
unless its actual completed work requires a higher-impact core. A release-bearing correction may
retain the selected version only while that version remains unpublished. A local tag, remote tag,
or GitHub release named `v<version>` establishes publication; after any one exists, the correction
must select the next version. Publication lookups fail closed unless GitHub confirms that the
resource does not exist with a 404 response:

```text
0.1.0-dev.1
0.1.0-dev.2
0.1.0-dev.3
0.1.0
```

Phase 25b is the compatibility program for the planned `0.1.0` release. Its first behavioral
milestone is `0.1.0-dev.1`; later Phase 25b release-bearing milestones advance the `dev.N`
sequence. Phase 26 removes the prerelease suffix only after its hardening and release gates pass.

## Canonical record

The applicable GitHub issue is the live source of truth. Before publication, its body must record:

- SemVer impact (`major`, `minor`, `patch`, or `none`);
- exact bare SemVer target version, or unchanged version for `none`;
- the corresponding immutable `v<version>` release tag when the unit publishes a release;
- rationale tied to the completed behavior;
- current milestone, evidence, residual work, and release status.

Material decisions and final gate, commit, deployment, tag, asset, checksum, and installer evidence
belong in issue comments. A phase issue can cover all of that phase's milestones unless a milestone
has explicitly been split into its own issue.

## Synchronized surfaces

For a release-bearing unit, all of these must agree before the commit is pushed:

- `src/version.lisp` full SemVer;
- `clun.asd` SemVer core;
- version assertions in the test suite;
- `site/install` default tag;
- `README.md` and `site/index.html` release claims;
- generated conformance evidence and the canonical issue.

Before every push, run
`BASE_SHA=<comparison-base> HEAD_SHA=<candidate-head> make version-transition-check`, with the two
commits bounding exactly the completed unit being published. The checker compares the base and
candidate source versions, changed-path impact, and canonical issue disposition, and rejects reuse
of a version already published by a local tag, remote tag, or GitHub release. In CI, `HEAD_SHA`
defaults to `GITHUB_SHA`, but `BASE_SHA` is required.

Run `make public-claims-check` and `make roadmap-verify-live` to enforce the remaining local and live
portions of this contract. The Pages workflow must also confirm that the matching GitHub release and
all five required assets exist before deploying an installer that targets the version.

## Publication order

1. Complete the bounded milestone and every required test, conformance, review, and public-claim
   gate.
2. Push the green commit to `origin/master` and wait for required branch checks. The release-dependent
   Pages job may remain pending while it waits for the tag assets and must not itself be a branch-protection
   prerequisite for creating that tag.
3. Create a new immutable annotated `v<version>` tag on that exact commit and push it. Never move or
   reuse a tag.
4. Wait for the release workflow to publish all four native archives and `checksums.txt`.
5. Wait for the Pages workflow to verify that release and deploy the matching site/installer.
6. Verify checksums and run `https://clun.sh/install` against the published release on a supported
   system.
7. Record commit, workflow, tag, assets, checksum, installer, and Pages evidence in the canonical
   issue.

The current Phase 25b milestone adds six backward-compatible public Object APIs and includes
backward-compatible semantic fixes. Its impact is `minor`, and its first published version is
`0.1.0-dev.1` under tag `v0.1.0-dev.1`.
