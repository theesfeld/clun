# Release Versioning

Clun uses [Semantic Versioning 2.0.0](https://semver.org/) for every published source version,
tag, archive, installer default, and public release claim. Version selection is based on the actual
completed unit of work, not the number of commits or pushes.

## Impact classification

Classify the completed unit before it is pushed:

- `major`: an incompatible change to a public interface or documented behavior;
- `minor`: backward-compatible public functionality;
- `patch`: a backward-compatible bug fix with no new public functionality;
- `none`: documentation or internal automation only, with no behavior change. A post-publication
  evidence-only update may report an already verified release, assets, Pages deployment, or hosted
  installer without a bump when it does not change the source version, installer target, packaged
  artifacts, capabilities, or compatibility claims. The canonical GitHub issue must record the
  evidence and explain why no version change is warranted.

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
0.1.0-dev.4
0.1.0-dev.5
0.1.0-dev.6
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

Phase 25b milestone 3 added backward-compatible shared iterator-record operations, lazy
iterable consumers, iterator-closing behavior, and binding/destructuring fixes. Its impact is `minor`.
The original `v0.1.0-dev.2` tag failed its darwin-arm64 release gate before assets were published.
The deterministic issue-60 teardown correction was published as `0.1.0-dev.3` under tag `v0.1.0-dev.3`,
as required by the immutable-tag rule; issue #59 retains the longer Darwin stress
evidence for Phase 26. Dev.3 publication is verified across all four native builders, its five release
assets and checksums, Pages, and the hosted installer. Issue #60 is closed.

Phase 25b milestone 4 adds backward-compatible function, class, parameter-environment, `super`,
arguments-object, bound-function, and callable-metadata behavior. Its impact is `minor`. The
release-bearing unit selects `0.1.0-dev.4` under tag `v0.1.0-dev.4` within the existing `0.1.0`
train; the ASDF core therefore remains `0.1.0`. The dev.4 master checks, annotated tag, all four native
archives, checksums, Pages deployment, and hosted installer are verified. The post-publication handoff
to milestone 5 is evidence-only with impact `none`, so it retains the dev.4 source and installer target.

Phase 25b milestone 5 adds backward-compatible same-realm synchronous generator functions, dynamic
`GeneratorFunction` construction, per-function generator prototypes, and `yield*` delegation with
iterator-result identity and specified close/error precedence. Cross-realm generator semantics remain
outside this milestone. Its impact is `minor`; it is published as `0.1.0-dev.5` under tag `v0.1.0-dev.5`,
an immutable annotated tag within the existing `0.1.0` train, so the ASDF core remains `0.1.0`. Master CI
and documentation, all four native archives and checksums, and the release-gated hosted installer are
verified. The post-publication handoff to milestone 6 is evidence-only with impact `none`, so source and
installer remain dev.5 and no tag is created. Its published-status page must pass Pages and be recorded in
the canonical issue before milestone 6 implementation begins. That gate is complete; milestone 6's selected
impact and target are recorded below and in the canonical issue before the implementation candidate.

Phase 25b milestone 6 adds backward-compatible FIFO async-generator requests, awaited yield and return
resumptions, AsyncFromSync iteration, async `yield*`, and completion-correct `for await` close behavior. Its
impact is `minor`; dev.5 is immutable, so the local source candidate is `0.1.0-dev.6` under tag
`v0.1.0-dev.6` within the existing `0.1.0` train, while the ASDF core remains `0.1.0`. Dev.5 remains the
last published release. No dev.6 tag, native assets, Pages deployment, or hosted-installer result is claimed
until the complete focused/full conformance, master-check, release, and deployment lifecycle passes. The
focused candidate gate is **407 m6 pass / 7 m11 fail / 95 Phase-37 fail / 0 skip / 0 timeout / 0 crash**.
Its confirmed default/off corpus is **25,461 pass / 2,702 fail / 12,491 skip / 0 crash**, or
**25,461 / 28,163 = 90.405852%**: 114 above target. The monotonic pass-list gain is +410 from dev.5
and +2,818 from the frozen 22,643-row Phase-25b entry list, with **1,817 Phase-25b / 885 Phase-37**
residuals. Three incidental `Promise.prototype.finally` passes
result from the required base PromiseResolve correction and its exposed species/order/object fix.
The suspended-start `return`/`throw` path completes and unregisters its underlying coroutine without
spawning a thread; regressions cover return, throw, repetition, completed-state behavior, and nil-thread
cleanup.

The m6 default/off and eager ledgers are byte-identical. Eager mode compiled **1,030,545** forms, classified
**56,018** as ineligible, and used zero fallback. The regenerated **25,461**-row monotonic pass list is
**+410** from dev.5, and digest `A742D885346DA23C` binds the exact conformance artifacts. Parse is green at
**23,713 total / 17,699 pass / 976 fail / 5,038 skip / 0 crash**; Lisp is green at **3,234 pass /
0 fail / 0 skip**. The local build, full-test, purity, security, public-claim, roadmap, installer,
conformance, and visual gates are green. Only committed-range SemVer, exact `master` CI and Documentation
runs, release assets, Pages deployment, and hosted-installer verification remain before dev.6 may change
from a local candidate into a published release.
