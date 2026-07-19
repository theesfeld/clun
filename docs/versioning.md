# Release Versioning

Clun uses [Semantic Versioning 2.0.0](https://semver.org/) for every published source version,
tag, archive, installer default, and public release claim. Version selection is based on the actual
completed unit of work, not the number of commits or pushes.

## Impact classification

Classify the completed unit before it is merged:

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
0.1.0-dev.7
0.1.0-dev.8
0.1.0-dev.9
0.1.0-dev.10
0.1.0-dev.11
0.1.0-dev.12
0.1.0-dev.13
0.1.0-dev.14
0.1.0-dev.15
0.1.0-dev.16
0.1.0-dev.17
0.1.0-dev.18
0.1.0-dev.19
0.1.0-dev.20
0.1.0-dev.21
0.1.0-dev.22
0.1.0-dev.23
0.1.0-dev.24
0.1.0-dev.25
0.1.0-dev.26
0.1.0-dev.27
0.1.0-dev.28
0.1.0-dev.31
0.1.0-dev.32
0.1.0-dev.33
0.1.0-dev.41
0.1.0-dev.35
0.1.0-dev.36
0.1.0-dev.41
0.1.0-dev.38
0.1.0-dev.39
0.1.0-dev.41
0.1.0-dev.30
```

Phase 25b is the compatibility program for the planned `0.1.0` release. Its first behavioral
milestone is `0.1.0-dev.1`; later Phase 25b release-bearing milestones advance the `dev.N`
sequence. Phase 26 is deferred until after Phase 82; its final version and tag are assigned from the
then-current release train and actual completed impact rather than the former `0.1.0` assumption.
Phase 27 continues the selected train with the compatibility evidence and generated-release tooling
unit recorded as `0.1.0-dev.7` / `v0.1.0-dev.7`.
Phase 29 adds the first public compatibility-ledger `Yes`: the Bun-compatible two-method
`Clun.semver` API over the existing shared installer engine. This backward-compatible public API is
published as immutable prerelease `0.1.0-dev.8` / `v0.1.0-dev.8`; the ASDF core remains `0.1.0`.
The annotated tag peels to `db56bee7540bfc84c5e730d2ab23a886c65dd160`, whose exact-master CI,
Documentation, and four-target Compatibility workflows passed before release run `29515697679` built and
published the four native archives plus `checksums.txt`. The evidence-only ledger reconciliation retains
dev.8 and creates no tag; Pages and hosted-installer success are recorded only after their own live gates.
Phase 35 adds the second public compatibility-ledger `Yes`, the backward-compatible `Clun.CSRF` API,
published as immutable prerelease `0.1.0-dev.9` / `v0.1.0-dev.9`; the ASDF core remains `0.1.0`.
The annotated tag peels to `5d3da6f49898cf93fba7cc24534655278964f35d`, whose exact-master CI,
Documentation, and four-target Compatibility workflows passed before release run `29522601664` built and
published the four native archives plus `checksums.txt`. This evidence-only reconciliation retains dev.9
and creates no tag; Pages and hosted-installer success are recorded only after their live gates pass.
Phase 33 adds the third public compatibility-ledger `Yes`, the backward-compatible `Clun.stringWidth` API,
published as immutable prerelease `0.1.0-dev.10` / `v0.1.0-dev.10`; the ASDF core remains `0.1.0`.
The annotated tag peels to `3e169ed25f8818621fd383678b313dfd0af71323`, whose exact-master CI,
Documentation, and four-target Compatibility workflows passed before release run `29529147937` built and
published the four native archives plus `checksums.txt`. This evidence-only reconciliation retains dev.10
and creates no tag; Pages and hosted-installer success are recorded only after their live gates pass.
Phase 32 implemented the fourth public compatibility-ledger `Yes`: backward-compatible `Clun.Cookie` and
`Clun.CookieMap` APIs plus request/response cookie integration. Exact master CI, Documentation,
Compatibility, and candidate Pages passed for dev.11, but the immutable tag's release matrix exposed
geometric CookieMap allocation growth on both arm64 builders. No dev.11 GitHub release or assets were
published, and the tag is immutable. The production pre-sizing correction is therefore combined with
Phase 30's backward-compatible `Clun.Glob` API was merged for `0.1.0-dev.12` / `v0.1.0-dev.12`, with
ASDF core `0.1.0`. Exact-master gates passed, but the immutable tag's release run exposed
allocator-region-sensitive single-sample accounting in the unchanged CookieMap linearity test on both
arm64 builders. No dev.12 GitHub release or assets were published, and the tag is immutable. Issues #6 and
#4 retain those exact receipts.
Phase 34 adds the sixth public compatibility-ledger `Yes`, the backward-compatible `Clun.color` parsing,
conversion, CSS, packed, object, tuple, hex, and ANSI output surface. It targets immutable prerelease
`0.1.0-dev.13` / `v0.1.0-dev.13`, with ASDF core `0.1.0`; that release also republishes the accepted Glob
surface and uses aggregate allocation accounting without weakening its 2.75x threshold. Issue #8 owns the
active release evidence and exact four-target receipts, while issue #4 remains the canonical Glob record.
Phase 36 adds the seventh public compatibility-ledger `Yes` with `Clun.password` and `Clun.hash` sync/async
APIs. The password/hash surface is a backward-compatible public addition published as SemVer `minor` at
`0.1.0-dev.14` / `v0.1.0-dev.14`; the ASDF core remains `0.1.0`. Issue #10 owns the immutable dev.14
release receipts.
Phase 31 completes bounded `Clun.YAML` parsing/stringification and YAML module loading at 402 / 402 cases in
the exact pinned Bun-generated parser corpus, converting YAML to the eighth public compatibility-ledger
`Yes`. The first backward-compatible candidate advanced the prerelease train to `0.1.0-dev.15` /
`v0.1.0-dev.15`, with ASDF core `0.1.0`, but its release workflow stopped before builds or assets because
the path-filtered Documentation workflow had no exact-SHA master run. That immutable tag is not reused and
the published installer remains dev.14. The dispatchable-gate recovery advances exactly once to
`0.1.0-dev.16` / `v0.1.0-dev.16`; Issue #5 owns its behavior, target receipts, publication, and
hosted-installer evidence. The same candidate includes Phase 37 milestone 1's reviewed modern built-ins,
but Phase 37 and Issue #11 remain in progress and make no full language-parity claim.
Phase 50 stages `0.1.0-dev.17` / `v0.1.0-dev.17` under Issue #24 (router PR #85) and is published on
master. Phase 65 stages `0.1.0-dev.18` / `v0.1.0-dev.18` under Issue #39 (shell PR #86; published).
Phase 66 stages `0.1.0-dev.19` / `v0.1.0-dev.19` under Issue #40 (test-runner PR #88 on master).
Phase 28 stages `0.1.0-dev.20` / `v0.1.0-dev.20` under Issue #2. Phase 37 milestone 2 stages
`0.1.0-dev.21` / `v0.1.0-dev.21` under Issue #11 (PR #96). Phase 65 inventory burn-down under Issue #39 (PR #111) is an unpublished correction of master candidate `0.1.0-dev.26` / `v0.1.0-dev.26` after later parallel landings (unmatched-glob failure policy; `tooling.shell` remains Partial; no new prerelease slot); its SemVer impact is `patch`. This Phase 66 concurrent-scheduling residual stages the next free slot `0.1.0-dev.27` / `v0.1.0-dev.27` under Issue #40 (PR #110). Concurrent/serial test scheduling is a backward-compatible test-runner API addition and therefore its SemVer impact is `minor` within the selected `0.1.0` core. The compatibility row remains `Partial` (not Yes). This Phase 47 node:path.win32 residual stages free `0.1.0-dev.28` / `v0.1.0-dev.28` under Issue #108 (PR #114). Pure-CL path.win32 is a backward-compatible Node compatibility residual and therefore its SemVer impact is `minor` within the selected `0.1.0` core. The `runtime.node-compatibility` row remains `Partial` (not Yes). Parallel topic branches claim unpublished `0.1.0-dev.22`–`0.1.0-dev.25`. Phase 58
constitutional secrets checkpoint stages free `0.1.0-dev.26` / `v0.1.0-dev.26` under Issue #32. Version-transition allows multi-step
prerelease advances only while every skipped intermediate remains unpublished, so parallel drafts
may allocate later slots without claiming each other's tags. Phase 37 m2 adds backward-compatible
`Array.fromAsync` and supporting lexer/parser admissions and therefore its SemVer impact is `minor`
within the selected `0.1.0` core. Until gates complete, the installer and immutable published
boundary remain dev.18; Phase 37 remains open and makes no full language-parity or matrix Yes claim.
Phase 51 M0 (WebSocket constitutional checkpoint, Issue #25 / PR #107) retained unpublished
`0.1.0-dev.21` / `v0.1.0-dev.21` as a release-bearing correction: fail-closed `Clun.serve` refusal of
WebSocket options/APIs with SemVer impact is `minor`; ledger `server.websocket` remained No and no new
prerelease slot was allocated.
Phase 51 M1 (WebSocket handshake + framing, Issue #121) stages free `0.1.0-dev.31` / `v0.1.0-dev.31`:
first Partial `server.websocket` capability (RFC 6455 handshake/framing + upgrade/echo); SemVer impact
is `minor`.

Phase 51 Partial→Yes (Issue #129) stages free `0.1.0-dev.38` / `v0.1.0-dev.38`: Pub/Sub
(`server.publish`/`subscriberCount`/`ws.subscribe`), fragmentation reassembly, permessage-deflate
via chipz, browser-shaped `WebSocket` client (`ws:`), Autobahn-style + e2e suite evidence, and
four-target `supported` receipts. SemVer impact is `minor`. Parent #25 remains open for residual
stress/Autobahn corpus quality stretch. Master tip after cron #146 is `0.1.0-dev.41`; this unit
takes the next free unpublished slot.

Phase 46 residual Issue #104 stages `0.1.0-dev.31` / `v0.1.0-dev.31` for the Phase 24 spawn residual (object form,
AbortSignal, timeout/killSignal, killed, ref/unref). SemVer impact is `minor`. Spawn remains
honest Partial (no IPC, ReadableStream stdout, #61 loop ownership). Master tip was `0.1.0-dev.28`
after path.win32 #114; this unit takes free `0.1.0-dev.31` under the unpublished-intermediate gap policy.

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

For a release-bearing unit, all of these must agree before the PR is merged:

- `src/version.lisp` full SemVer;
- `clun.asd` SemVer core;
- version assertions in the test suite;
- `site/install` default tag;
- `compat/release.tsv` publication state and exact tagged commit once published;
- `README.md` and `site/index.html` release claims;
- generated conformance evidence and the canonical issue.

Before every release-bearing merge, run
`BASE_SHA=<comparison-base> HEAD_SHA=<candidate-head> make version-transition-check`, with the two
commits bounding exactly the completed unit being published. The checker compares the base and
candidate source versions, changed-path impact, and canonical issue disposition, and rejects reuse
of a version already published by a local tag, remote tag, or GitHub release. In CI, `HEAD_SHA`
defaults to `GITHUB_SHA`, but `BASE_SHA` is required.

Run `make public-claims-check` and `make roadmap-verify-live` to enforce the remaining local and live
portions of this contract. A candidate Pages run validates claims but does not deploy. Once the ledger is
published, Pages must confirm that the matching tag peels to the recorded release commit and that all five
required assets exist before deploying an installer that targets the version.

## Publication order

Process constitution: `~/.config/agents/AGENTS.md` (branch → PR → squash-merge into `master`).
Do not land release-bearing work by pushing a feature commit straight to `origin/master`.

1. Complete the bounded milestone and every required test, conformance, review, and public-claim
   gate on a **topic branch**.
2. Open a PR into `master`. Wait for exact-commit CI, Documentation, and Compatibility workflows on
   the PR head (and again on the merge commit as required). Candidate Pages runs validate without
   deploying and are not a tag prerequisite. Squash-merge only when gates are green.
3. Create a new immutable annotated `v<version>` tag on the **merge commit** on `master` and push it.
   Never move or reuse a tag. The release workflow independently requires those three successful
   exact-SHA master runs. Repository-level GitHub release immutability is enabled; `gh release create`
   creates a draft, attaches every asset, and publishes only after upload. Publication locks the
   release assets and associated tag. Active no-bypass ruleset `19048471` separately permits initial
   `refs/tags/v*` creation but rejects every update, non-fast-forward move, and deletion, including
   during the build-to-publication window.
4. Wait for the release workflow to publish all four native archives and `checksums.txt`, and require GitHub
   to report the resulting release as immutable.
5. Change the release ledger from `candidate`/`pending` to `published` plus the exact tagged commit, regenerate
   README/site/release notes, record this evidence-only transition, and land it via PR (or a follow-up
   PR) without changing the version.
6. Wait for Pages to verify that exact tag commit and its assets, then deploy the matching site/installer.
7. Verify checksums and run `https://clun.sh/install` against the published release on a supported
   system.
8. Record commit, workflow, tag, assets, checksum, installer, and Pages evidence in the canonical
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
`v0.1.0-dev.6` within the existing `0.1.0` train, while the ASDF core remains `0.1.0`. That candidate is now
published as the dev.6 prerelease. The focused release gate is **407 m6 pass / 7 m11 fail / 95 Phase-37 fail /
0 skip / 0 timeout / 0 crash**.
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
conformance, and visual gates are green. Candidate commit `4d2b714c1a459264ca9e77f5f25979bb41b50c76`
passed CI `29488866153` and Documentation `29488866083`; annotated tag `v0.1.0-dev.6` peels to that exact
commit. Release run `29489277258` passed all four native builders and published dev.6 as a prerelease. Fresh
downloads matched `checksums.txt`: darwin-arm64
`1df087c75a9b335172371196a3553ab568cd85ff0b89921e35c98b467e137f1d`, darwin-x64
`8588ee870948ad1de7fd3c3a86e66de58a3e00945897a90a4ad06e83fa978ffc`, linux-arm64
`4eaa6c94f1364f7a07318d52e80e01dc538cbdc489e993353049c195401f5a31`, and linux-x64
`243dfc96bd5a163707c982bfe61d6054a784fe9bbd52bb72b6436d4ba9774935`. Pages `29488866091` succeeded
for the exact candidate, and an isolated hosted installation reported `clun 0.1.0-dev.6`. The
post-publication handoff has impact `none`; source and installer remain dev.6 and no new tag is created.
The handoff commit's CI, Documentation, and Pages runs passed; issue #57 is closed and Phase 27 is current.
Phase 26 is deferred until after Phase 82 and will be re-baselined at entry.

Phase 27 adds backward-compatible project tooling: a canonical compatibility/evidence ledger, stable feature
IDs and ownership, shipped-binary evidence commands, deterministic README/site/release-note generation,
immutable benchmark manifests, and a four-platform compatibility workflow. Its impact is `minor` because
these are new supported developer and release interfaces within the selected
`0.1.0` prerelease train. Squash-merge commit
`7144a33d383c1c3ff7942cd80a6bd2647e6d00f5` passed exact-commit CI, Documentation, four-target
Compatibility, and receipt verification. Release run `29506579486` published annotated tag
`v0.1.0-dev.7`, which peels to that commit, with four native archives plus `checksums.txt`; GitHub reports
the prerelease immutable. The ASDF core remains `0.1.0`. The non-release-bearing publication handoff keeps
`0.1.0-dev.7` unchanged and creates no new tag; release-gated Pages and hosted-installer verification are
the remaining closeout evidence.

Phase 65 shell Partial→Yes (#120) stages `0.1.0-dev.33` / `v0.1.0-dev.33` with zero pending corpus sites and four-target supported receipts.
Phase 76 cron scheduling (#50) stages free `0.1.0-dev.41` / `v0.1.0-dev.35`: pure-CL `Clun.cron` parse + in-process jobs (OS-level fail-closed); SemVer impact is `minor`.

Phase 74 archive/compression pure-CL APIs (#134) stages `0.1.0-dev.35` / `v0.1.0-dev.35` without a 31st features.tsv row (matrix locked at 30).
Phase 38 runtime.web-standard-apis Partial→Yes (#130) stages `0.1.0-dev.38` / `v0.1.0-dev.38` with Writable/Transform/BYOB streams, proxy object options, hermetic stress, and four-target supported receipts; SemVer impact is `minor`.

Phase 75 Markdown + HTMLRewriter pure-CL (#135) stages `0.1.0-dev.39` / `v0.1.0-dev.39` without expanding the frozen 30-row summary ledger. SemVer impact is `minor`.

Phase 39 language.typescript Partial→Yes (#133) stages `0.1.0-dev.41` / `v0.1.0-dev.41` with enum, runtime namespace, and parameter-property transforms plus four-target supported receipts.


0.1.0-dev.41
Phase 49 server.http Partial→Yes (#128) stages `0.1.0-dev.41` / `v0.1.0-dev.41`.
Phase 49 server.http Partial→Yes (#128) stages free `0.1.0-dev.43` / `v0.1.0-dev.43` with streaming HTTP/1.1 four-target receipts; SemVer impact is `minor`.
Phase 66 test-runner Partial→Yes (#127) stages `0.1.0-dev.36` / `v0.1.0-dev.36` after master archive Yes landed as `.35`. Multi-file `--parallel`, concurrent evidence, exotic snapshots, 52-root disposition, four-target supported, gap cleared.

Phase 59 package-manager.npm Partial→Yes (#131) stages `0.1.0-dev.41` / `v0.1.0-dev.41` with dependency-spec breadth (registry, npm: aliases, file:/link:, optional soft-fail), hermetic four-target install receipts, and platforms supported.

Phase 59 package-manager.npm Partial→Yes (#131) stages `0.1.0-dev.44` / `v0.1.0-dev.44` with dependency-spec breadth and four-target install receipts.

Phase 47 selected Node surface Partial→Yes (#132) stages `0.1.0-dev.45` / `v0.1.0-dev.45` with four-target supported receipts (not full Node/V8 parity).

Phase 40 language.jsx No→Yes (#186) stages `0.1.0-dev.47` / `v0.1.0-dev.47` with four-target supported receipts and pure-CL classic/automatic runtimes (offline helpers exceed Bun).
Phase 60 package-manager.monorepo No→Yes (#182) stages `0.1.0-dev.48` / `v0.1.0-dev.48` with workspaces, filters, catalog: protocols, live symlink packages, topological concurrent script waves, and four-target monorepo receipts; SemVer impact is `minor`.

Phase 58 secrets FULL PORT (#179) stages free `0.1.0-dev.49` / `v0.1.0-dev.49`; SemVer impact is `minor`.

Phase 41 runtime.loader-plugins FULL PORT (#187) stages free `0.1.0-dev.53` / `v0.1.0-dev.53` with pure-CL `Clun.plugin` (Bun.plugin-compatible onResolve/onLoad/module/clearAll plus exceed list/clear/priority/registerHooks); SemVer impact is `minor`.
Phase 54 Redis FULL PORT (#184) stages free `0.1.0-dev.51` / `v0.1.0-dev.51`; SemVer impact is `minor`.
Phase 67 hot-reload FULL PORT (#188) stages free `0.1.0-dev.52` / `v0.1.0-dev.52`; SemVer impact is `minor`.
Phase 67 hot-reload FULL PORT (#188) stages free `0.1.0-dev.52` / `v0.1.0-dev.52`; SemVer impact is `minor`.
Phase 53 cloud.s3 FULL PORT (#185) stages free `0.1.0-dev.53` / `v0.1.0-dev.53` with pure-CL AWS SigV4 S3 client (list/get/put/delete/presign/multipart, path-style); SemVer impact is `minor`.
Phase 53 S3 FULL PORT (#185) stages free `0.1.0-dev.53` / `v0.1.0-dev.53`; SemVer impact is `minor`.
Phase 55–57 SQL drivers FULL PORT (#183) stages free `0.1.0-dev.50` / `v0.1.0-dev.50` with pure-CL PostgreSQL+MySQL wire protocols, embedded SQLite engine, unified Clun.SQL exceeding Bun.SQL (inspect/stats/export/queryLog), and four-target supported receipts; SemVer impact is `minor`.
Phase 55-57 SQL FULL PORT (#183) stages free `0.1.0-dev.54` / `v0.1.0-dev.54`; SemVer impact is `minor`.

Phase 62 tooling.bundler FULL PORT (#180) stages free `0.1.0-dev.53` / `v0.1.0-dev.53` with pure-CL Clun.build (entry/split/minify/loaders/assets) exceeding Bun.build; SemVer impact is `minor`.
Phase 62 bundler FULL PORT (#180) stages free `0.1.0-dev.55` / `v0.1.0-dev.55`; SemVer impact is `minor`.

Phase 68 frontend-dev-server FULL PORT (#189) stages free `0.1.0-dev.54` / `v0.1.0-dev.54`; SemVer impact is `minor`.
Phase 69 frontend-dev FULL PORT (#189) stages free `0.1.0-dev.56` / `v0.1.0-dev.56`; SemVer impact is `minor`.

Phase 37 milestone 4 (keyed Promise combinators, Issue #11) stages free `0.1.0-dev.63` / `v0.1.0-dev.63`: pure-CL `Promise.allKeyed` / `Promise.allSettledKeyed` converting 74 frozen Test262 failures. SemVer impact is `minor`. No matrix Yes; Phase 37 remains open.

Phase 48 runtime.native-addons FULL PORT (#178 / canonical #22) stages free `0.1.0-dev.66` / `v0.1.0-dev.66` after Phase 37 m4 `0.1.0-dev.63`; SemVer impact is `minor`.
