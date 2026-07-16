# Phase 27: Compatibility Evidence and Release Documentation

## 1. Objective and boundary

Phase 27 makes the current landing-page compatibility and release claims reproducible from checked-in
structured data and executable evidence. It establishes the seed ledger and the public-document gate used by
later phases. It does not implement a new runtime API, promote a compatibility claim, refresh an upstream
baseline, execute Bun differentials, or publish a cross-runtime performance claim.

The implementation has five deliverables:

1. a canonical 30-row compatibility ledger with stable IDs and phase ownership;
2. a shipped-binary evidence runner for the current positive claims;
3. deterministic README, site, and release-note generation;
4. checked-in benchmark workload and metric manifests for later performance work; and
5. a four-target compatibility workflow that produces deterministic receipts and does not deploy Pages.

The canonical GitHub Phase 27 issue remains the live source of truth for status, SemVer disposition,
blockers, decisions, and publication evidence. `PLAN.md` is the technical contract, `STATE.md` is the local
resume checklist, and the checked-in `compat/` tables are the deterministic public-claim input. Offline checks
validate the repository state; `make roadmap-verify-live` separately checks the live issue contract.

## 2. Frozen upstream identities

Public comparison copy and engineering references use different, explicitly named baselines:

| Baseline ID | Purpose | Version/ref | Exact commit |
|---|---|---|---|
| `bun-stable-1.3.14` | Public comparison and future executable differential baseline | `bun-v1.3.14` | `0d9b296af33f2b851fcbf4df3e9ec89751734ba4` |
| `bun-engineering-c1076ce95e` | Forward source, types, docs, and test inventory | `1.4.0-dev` / `c1076ce95e` | `c1076ce95effb909bfe9f596919b5dba5567d550` |
| `node-current-26.5.0` | Landing-page comparison and primary-repository provenance | `v26.5.0` | `bebd1b8d92bf4cc917844d6335ed1ecf9c2a75fb` |
| `deno-stable-2.9.3` | Landing-page comparison and primary-repository provenance | `v2.9.3` | `f39575ecd50602a5b42b1ba8e93849460de9fcf4` |

The comparison snapshot date is the checked-in `checked_on` field, not the current clock. A later refresh is
an explicit ledger and generated-document change.

`compat/upstream-assets.tsv` pins one Bun 1.3.14 archive for each release target. The x64 entries use the
baseline builds to avoid an accidental AVX-level requirement:

| Target | Bun 1.3.14 asset | SHA-256 |
|---|---|---|
| `linux-x64` | `bun-linux-x64-baseline.zip` | `a063908ae08b7852ca10939bbdc6ceed3ddabce8fb9402dce83d65d73b36e6c7` |
| `linux-arm64` | `bun-linux-aarch64.zip` | `a27ffb63a8310375836e0d6f668ae17fa8d8d18b88c37c821c65331973a19a3b` |
| `darwin-x64` | `bun-darwin-x64-baseline.zip` | `3e35ad6f53971a9834bf9e6786e2adf72b5f1921cc9a9c5fde073d2972944076` |
| `darwin-arm64` | `bun-darwin-aarch64.zip` | `d8b96221828ad6f97ac7ac0ab7e95872341af763001e8803e8267652c2652620` |

Phase 27 records and validates the asset metadata but does not download or run these archives. A checked path
reference is not executable evidence, and an API-presence probe would prove only the behavior it exercises.

## 3. Exact landing-matrix inventory

The Phase 27 seed contains exactly 30 ordered summary rows: zero `Yes`, six `Partial`, and 24 `No`. The
primary owner and integration owners are stored directly in `compat/features.tsv`.

| Order | Stable feature ID | Group | Current Clun claim | Primary owner | Integration owners |
|---:|---|---|---|---:|---|
| 1 | `runtime.node-compatibility` | core | `Partial`: selected globals and module subsets | 47 | 42, 43, 44, 45, 46 |
| 2 | `runtime.web-standard-apis` | core | `Partial`: buffered fetch and a scoped Web API surface | 38 | none |
| 3 | `runtime.native-addons` | core | `No`: excluded by the current purity contract | 48 | none |
| 4 | `language.typescript` | core | `Partial`: erasable syntax stripping only | 39 | none |
| 5 | `language.jsx` | core | `No`: not included in the v0.1 scope | 40 | none |
| 6 | `runtime.loader-plugins` | core | `No`: fixed loader surface | 41 | none |
| 7 | `database.sql-drivers` | APIs | `No` | 55 | 56, 57 |
| 8 | `cloud.s3` | APIs | `No` | 53 | none |
| 9 | `database.redis` | APIs | `No` | 54 | none |
| 10 | `server.websocket` | APIs | `No`: no WebSocket implementation | 51 | none |
| 11 | `server.http` | APIs | `Partial`: HTTP/1.1 with buffered bodies | 49 | none |
| 12 | `server.router` | APIs | `No`: supply one in the handler | 50 | none |
| 13 | `tooling.single-file-executables` | APIs | `No`: Clun ships a runtime executable only | 52 | 77 |
| 14 | `data.yaml` | APIs | `No` | 31 | none |
| 15 | `web.cookies` | APIs | `No` | 32 | none |
| 16 | `security.encrypted-secrets` | APIs | `No` | 58 | none |
| 17 | `package-manager.npm` | tooling | `Partial`: fixture-tested; public npm is blocked by TLS interop | 59 | 28, 60, 61 |
| 18 | `tooling.bundler` | tooling | `No`: not included in the v0.1 scope | 62 | 63, 64, 77 |
| 19 | `tooling.shell` | tooling | `No`: spawn and package scripts only | 65 | none |
| 20 | `tooling.test-runner` | tooling | `Partial`: 22 matchers; no snapshots, coverage, mocks, or concurrency | 66 | none |
| 21 | `tooling.hot-reload` | tooling | `No` | 67 | none |
| 22 | `package-manager.monorepo` | tooling | `No`: workspaces are unsupported | 60 | none |
| 23 | `tooling.frontend-dev-server` | tooling | `No` | 68 | none |
| 24 | `tooling.formatter-linter` | tooling | `No` | 69 | 70 |
| 25 | `security.password-hashing` | utilities | `No`: randomness APIs only | 36 | none |
| 26 | `text.string-width` | utilities | `No` | 33 | none |
| 27 | `filesystem.glob` | utilities | `No` | 30 | none |
| 28 | `utility.semver` | utilities | `No`: installer-internal only | 29 | none |
| 29 | `web.css-color` | utilities | `No` | 34 | none |
| 30 | `web.csrf` | utilities | `No` | 35 | none |

These rows are the landing-page summary, not the final parity boundary. The current schema does not contain
child records for individual exports, commands, flags, loaders, protocols, globals, or observable behaviors.
Later feature phases must add the finer-grained evidence contract needed by their scope. Phase 73 remains the
one-time exhaustive stable-versus-engineering surface freeze; it must not reinterpret this 30-row seed as the
complete Bun surface.

## 4. Checked-in file layout

The implementation uses these files:

```text
compat/
  README.md
  baselines.tsv
  evidence.tsv
  features.tsv
  platforms.tsv
  references.tsv
  release.tsv
  upstream-assets.tsv
  benchmarks/
    metrics.tsv
    workloads.tsv
docs/releases/
  current.md
scripts/
  compat.sh
  compat-validate.awk
  compat-render.awk
  test-compat-tools.sh
tests/compat/
  runtime.web-standard-apis/
    basic.js
    basic.out
  server.http/
    run.sh
    server.js
```

There is no `owners.tsv`, child-feature manifest, result-envelope schema, release-evidence table, upstream
blob map, or copied Bun fixture tree. Ownership lives in `features.tsv`; the active release is the single row
in `release.tsv`; repository evidence is registered directly in `evidence.tsv`; and CI receipts are generated
by `.github/workflows/compat.yml`.

Every table has one exact tab-separated header. The validator rejects the wrong field count, CRLF endings,
blank records, duplicate keys, and non-strict key ordering. `-` is the sentinel for an absent optional value.
Stable IDs match a restricted lowercase identifier form.

## 5. Actual table schemas

### 5.1 Baselines

`compat/baselines.tsv`:

```text
baseline_id runtime version channel revision tag checked_on purpose source_url license
```

Allowed channels are `stable-executable`, `engineering-source`, and `comparison-release`. The active ledger
contains exactly four runtime/channel roles: stable Bun, engineering Bun, Node.js comparison, and Deno
comparison. Every row requires strict SemVer, a full 40-character commit, a source URL containing that exact
revision, a real calendar date, a nonempty purpose, and the expected upstream MIT license. Stable and
comparison rows require coherent release tags; all four rows share one explicit snapshot date.

### 5.2 Flat matrix and ownership

`compat/features.tsv`:

```text
feature_id display_order display_group capability summary clun_state clun_detail gap bun_state bun_detail node_state node_detail deno_state deno_detail primary_phase integration_phases
```

The file has exactly one row for each of the 30 landing capabilities. It stores the Clun and comparison states
directly; those states are not derived from a child graph. Clun states are `Yes`, `Partial`, or `No`.
Comparison states additionally allow `Separate`. Display groups are `core`, `apis`, `tooling`, and
`utilities`. Every primary or integration phase must exist in `docs/roadmap.tsv`; integration phases are a
sorted comma-separated list or `-`.

### 5.3 Evidence and platform declarations

`compat/evidence.tsv`:

```text
evidence_id feature_id kind command executable_path fixture_path expected_path platform_scope assertion
```

Evidence kinds are `fixture`, `suite`, `report`, `decision`, and `benchmark`. Runner commands are:

- `clun-fixture`: run `build/clun` against a registered JS/TS fixture and compare exact stdout, expected exit,
  optional stderr, and optional argv sidecars;
- `checked-script`: run a repository shell script that performs its own shipped-binary assertions; the runner
  passes the absolute declared executable as `CLUN_COMPAT_EXECUTABLE`; and
- `static`: validate the referenced repository path and print a trace without executing that suite.

`compat/platforms.tsv`:

```text
feature_id target support_state evidence_ids note
```

Each feature has exactly one row for each of `darwin-arm64`, `darwin-x64`, `linux-arm64`, and `linux-x64`.
Support states are `supported`, `unverified`, `unsupported`, and `not-applicable`. Evidence IDs must belong to
the same feature. Executable evidence must declare at least one target; static evidence must use `-` platform
scope. A platform reference to executable evidence is valid only when that evidence declares the same target.
In the Phase 27 seed, the six `Partial` rows are `unverified` on all targets and the 24 `No` rows are
`unsupported`; no row is yet `supported`.

### 5.4 References and upstream assets

`compat/references.tsv`:

```text
reference_id feature_id baseline_id kind paths assertion
```

Every feature currently has exactly one reference for each selected role: `stable-map` for Bun stable,
`engineering-map` for Bun engineering, and `comparison-page` for both Node.js and Deno. Baseline roles are
selected by runtime and channel rather than hardcoded IDs. Node.js and Deno assertions exactly equal the
corresponding `state: detail` pair in `features.tsv`. `paths` is a sorted comma-separated list of safe,
repository-relative upstream paths. The validator checks role/kind agreement, assertion agreement, ownership,
sort order, and path syntax. It does not contact GitHub, resolve a path at its commit, or store Git blob IDs.
Remote path existence therefore requires a separate review and is not proven by `make compat-validate`.

`compat/upstream-assets.tsv`:

```text
baseline_id target asset_name sha256 source_url
```

It contains exactly four Bun stable rows. The validator checks target uniqueness, SHA-256 shape, HTTPS URLs,
baseline existence, and the four-row count. It does not download or hash the remote asset.

### 5.5 Active release

`compat/release.tsv`:

```text
release_id version asdf_core installer_default tag publication_state license active_phase issue semver_impact previous_version version_source asdf_source installer_source release_commit
```

Exactly one active row is allowed. Its version must match `src/version.lisp`, its ASDF core must match
`clun.asd`, its installer default must match `site/install`, and its tag must be `v<version>`. Publication state
is `candidate` or `published`; the license is exactly `GPL-3.0-or-later`. A candidate uses `pending` for
`release_commit`; a published row must record the exact 40-character commit peeled from its immutable tag.
The Phase 27 candidate row records `0.1.0-dev.7`, `v0.1.0-dev.7`, issue `#1`, impact `minor`, and previous
version `0.1.0-dev.6`.

Publication runs, release asset checksums, Pages deployment, and hosted-installer results are recorded in the
canonical issue, not in a checked-in release-evidence table.

### 5.6 Benchmark seed

`compat/benchmarks/workloads.tsv`:

```text
workload_id coverage_scope owner_phase fixture_path fixture_sha256 runner_path runner_sha256 mode iterations warmups default_repetitions correctness_signal immutable_since
```

`compat/benchmarks/metrics.tsv`:

```text
metric_id workload_id metric unit direction aggregation required claim_scope immutable_since
```

The seed registers exactly four existing Phase 25 workloads: DeltaBlue, Richards, Splay, and empty-process
startup. Each has one required, lower-is-better elapsed-time metric with `clun-self-relative-only` claim scope.
Validation hashes each nonempty fixture and every runner, requires one metric per workload, and rejects a
missing workload row. The `immutable_since` field is currently declarative: the tools do not compare frozen
rows across Git history, and metric rows do not have their own content digest. No row authorizes a
Clun-versus-Bun performance claim.

## 6. Validation and state rules

`make compat-validate` runs `scripts/compat.sh validate`, which invokes the POSIX-AWK validator and then checks
repository paths, benchmark hashes, and public superlatives. It enforces:

- exact headers, field counts, sorted unique IDs, allowed values, and safe repository-relative paths;
- exactly four complete, uniquely selected baseline roles with strict versions, full revisions, coherent
  tags, revision-pinned source URLs, one semantic snapshot date, nonempty purposes, and upstream licenses;
- exactly 30 feature rows with unique display orders from 1 through 30;
- roadmap-backed primary and integration phases;
- exactly four platform rows for every feature;
- exactly one stable Bun, engineering Bun, Node.js, and Deno reference for every feature, with role/kind and
  Bun stable/Node.js/Deno assertion agreement;
- at least one evidence record for every `Partial` feature;
- target-scoped shipped-binary evidence plus `supported` platform evidence on all four targets before a stored
  `Yes` is accepted;
- nonempty platform scope for executable evidence, `-` scope for static evidence, and agreement between every
  platform evidence reference and the executable evidence's declared targets;
- the Phase 27 seed count of 0 `Yes`, 6 `Partial`, and 24 `No`;
- release/source/ASDF/installer/tag/license agreement plus exact active phase/issue agreement with `STATE.md`;
- four Bun stable asset records and valid digest syntax;
- four benchmark workloads, valid fixture/runner digests, and at least one metric per workload; and
- rejection of an unqualified `faster`, `better`, or `stronger than Bun`, Node.js, or Deno claim in README,
  site, or current release notes.

The validator does not derive a feature state from its evidence, execute evidence, verify upstream references
or asset bytes, aggregate child features, or consume CI receipts. A `Partial` row needs some evidence but not
necessarily executable evidence. A `static` record is supporting trace evidence, not a target attestation.

## 7. Executable evidence runner

`make compat FEATURE=<feature-id>` always rebuilds `build/clun` from the current checkout and then calls
`scripts/compat.sh run`. `FEATURE` defaults to `all` in the Makefile. Before evidence executes, every selected
executable must report the exact `clun <release.tsv version>` string; a stale binary fails closed. A named
feature must be one of the 30 matrix IDs and must have at least one registered evidence row. `FEATURE=all`
selects all eight current evidence rows.

The current registered evidence is:

| Feature | Executed evidence | Supporting trace |
|---|---|---|
| `language.typescript` | exact-output TypeScript annotation fixture | none |
| `package-manager.npm` | hermetic local-registry install, offline reinstall, lock identity, and execution script | none |
| `runtime.node-compatibility` | exact-output Node module-alias fixture | none |
| `runtime.web-standard-apis` | exact-output URL/Headers/Response fixture | buffered-fetch Lisp suite path |
| `server.http` | loopback HTTP 200/header/body and 404 checked script | HTTP-server Lisp suite path |
| `tooling.test-runner` | exact-output matcher fixture | none |

`clun-fixture` runs the shipped binary with `CI=0` and compares files with `cmp`. `checked-script` executes the
script from the repository root with `CLUN_COMPAT_EXECUTABLE` set to the absolute registered executable path,
then trusts its exit status after the script's own assertions. Both current scripts consume that variable and
retain a direct-invocation fallback. Work files live under `tmp-test/compat/local` and are recreated for each
invocation.

The local runner emits one `(pass)` line for each executed `clun-fixture` or `checked-script`, one `(trace)`
line for each nonexecuted static record, and a summary with separate executable-pass and static-trace counts.
When `CLUN_COMPAT_TARGET` is set, executable rows are selected only when their declared scope contains that
exact release target; static traces remain target-independent. It does not write typed JSON/error/ordering
envelopes, run the pinned Bun binary, enforce per-record timeouts, or write a standalone machine-readable
receipt. Those are current implementation limits, not implied features.

## 8. Deterministic public-document generation

`make docs-generate` is the only compatibility target that rewrites public files. It validates first, renders
to a fresh scratch directory, and replaces one exact marker pair for each generated block.

README markers:

```text
release
compatibility
release-summary
```

Site markers:

```text
release
compatibility
compatibility-intro
version
phase-status
release-links
```

Release-note marker in `docs/releases/current.md`:

```text
release-notes
```

Each expands to `<!-- clun-generated:<name>:begin -->` and the matching `end` marker. Missing, duplicate,
reversed, or nested marker state causes replacement to fail. The renderer consumes `docs/roadmap.tsv`,
`compat/baselines.tsv`, `compat/release.tsv`, and `compat/features.tsv`; validation additionally consumes the
rest of the ledger and the source/ASDF/installer versions. Runtime/channel roles select baselines without
hardcoded IDs, and the site source note is generated inside the compatibility block. Rendering uses C-locale
ordering and no network, clock, random ID, or Git worktree state.

`make docs-check` is read-only. It validates, performs two independent scratch renders, compares every rendered
README, site, release note, and canonical TSV byte-for-byte, then compares the three checked-in documents with
the first render. README and site agree because both are generated from the same feature rows. `docs-check`
does not parse them back into records; the broader `public-claims-check` separately parses and compares their
capability, state, and phase anchors.

The release workflow calls `gh release create` with both `--generate-notes` and
`--notes-file docs/releases/current.md`, so the checked preamble accompanies GitHub's generated notes. The
workflow does not edit the checked-in release notes after publication. A tag build requires an annotated tag
whose commit is on `master` and successful exact-commit push runs named `CI`, `Documentation`, and
`Compatibility`; the tag workflow rechecks those runs through the GitHub API before building. Prereleases are
published with GitHub's Latest flag disabled, and the installer requests an explicit strict SemVer tag rather
than the unavailable `/releases/latest` alias. Repository-level GitHub release immutability is enabled. The
installed GitHub CLI creates a draft, attaches all assets, then publishes; the workflow and live release gate
both require GitHub to report the published release as immutable. Active tag ruleset `19048471` has no bypass
actors: it permits initial `refs/tags/v*` creation and blocks every update or deletion before and after release
publication. After assets publish, a no-version-bump follow-up changes only publication evidence and generated
surfaces before Pages deploys.

`scripts/public-claims-check.sh` invokes `scripts/compat.sh check` first, then performs the broader SemVer,
installer, conformance, benchmark, issue-link, and HTML integrity checks. Release version, state, phase, issue,
and previous version come from `compat/release.tsv` rather than a Phase 25b hardcoded value.

## 9. Deliberate-drift coverage

`scripts/test-compat-tools.sh` copies all inputs into scratch space and leaves the real repository untouched.
It currently proves two pristine checks, three positive forward-render cases (published state, Phase 28, and
a complete baseline-ID/version/revision refresh), and 30 deliberate-drift cases. Those cases cover:

1. source, prior-release SemVer, active STATE/release disagreement, missing release-note, stale-binary, and
   generated feature-state drift;
2. evidence, reference, and platform ownership drift;
3. missing or misassigned Node/Deno references, wrong reference kind, unsafe path, Bun/Node/Deno assertion
   mismatch, incomplete baseline metadata, and pinned comparison-revision drift;
4. duplicate, reversed, and missing generated markers;
5. benchmark-row deletion and fixture digest drift;
6. an unqualified `faster than Bun` public claim;
7. `Yes` without executable or all-target evidence;
8. invalid executable/static scope, platform/evidence scope disagreement, and invalid target names.

Two-render byte identity is exercised by the pristine `docs-check`. There are not yet dedicated local mutation
cases for a remote reference/blob mismatch, receipt-file corruption, or history-level benchmark immutability.
Evidence rows do not currently carry content digests, so that specific mutation gate cannot exist without a
schema change. Independent review resolved all 60 Node/Deno references, spanning 66 paths, against complete
pinned GitHub trees.

## 10. Four-platform compatibility workflow

`.github/workflows/compat.yml` runs on relevant runtime, evidence, test, vendor, benchmark, build-tooling,
and compatibility-workflow changes pushed to `master`, on matching pull requests, and by manual dispatch.
Site, general documentation, and root-Markdown-only changes stay on the cheap CI/Documentation/Pages path and
do not start four native builds. Its target map is:

| Target | Runner | Required `uname -m` |
|---|---|---|
| `linux-x64` | `ubuntu-24.04` | `x86_64` |
| `linux-arm64` | `ubuntu-22.04-arm` | `aarch64` |
| `darwin-x64` | `macos-15-intel` | `x86_64` |
| `darwin-arm64` | `macos-15` | `arm64` |

Each matrix job checks the architecture, installs SBCL 2.6.4 from a checksummed binary or source archive,
builds Clun, runs `make compat-validate`, `make docs-check`, and target-scoped `scripts/compat.sh run all`, and uploads one
version-2 `receipt.tsv` with this schema:

```text
schema candidate_sha target binary_sha256 ledger_sha256 fixture_sha256 result_sha256 bun_asset_sha256 feature_ids executed_ids traced_ids pass_count fail_count trace_count
```

The ledger digest covers `docs/roadmap.tsv` and all nine compatibility tables. The fixture digest covers
`compat/evidence.tsv`, registered fixture/expected files, and present `.argv`, `.err`, or `.exit` sidecars.
`binary_sha256` hashes the exact `build/clun` used by the job. `result_sha256` hashes the canonical sorted
`pass`/`trace` outcome manifest for that target, which is compared with target-filtered command classification
in `compat/evidence.tsv` before the receipt is written. `feature_ids` contains all 30 sorted matrix IDs;
`executed_ids` and `traced_ids` contain the separately classified evidence IDs; the three counts record six
passes, zero failures, and two traces on each target for the Phase 27 seed. `bun_asset_sha256` is exactly `-`
because this phase does not execute Bun. A
checked script's transitive inputs are covered only when they are themselves present in the ledger/fixture
manifest.

The final job downloads exactly four receipts and requires the current candidate SHA, identical ledger and
fixture digests, each target's independently recomputed canonical result digest, all 30 feature IDs, the
target-specific and separately classified executed/traced ID sets and counts, a zero failure count, `-` for the unused Bun asset, four
distinct known targets, the v2 schema, and a SHA-256-shaped native binary digest in every receipt. It uses
Node-24-compatible action generations: `actions/checkout@v7`, `actions/upload-artifact@v7`, and
`actions/download-artifact@v8`.

The compatibility matrix deliberately does not repeat the full historical `make test` and `make purity`
suite. The ordinary CI workflow owns those gates for runtime-bearing changes. Tagged release builders run
the target-scoped runner against the already-built binary before packaging on all four targets.

Pages remains site-only. A candidate row verifies public claims, live roadmap issues, and release-gate fixtures
without deploying. After GitHub assets exist, a follow-up row records `published` plus the exact tagged commit;
Pages verifies that commit and all assets before uploading `site/`. It never builds Clun, executes compatibility
evidence, or publishes receipt artifacts.

## 11. Purity, portability, and licensing

- The validator, renderer, and runner are POSIX shell and POSIX AWK. JavaScript and TypeScript appear only as
  shipped-runtime fixtures, not as implementation code.
- Clun does not link, load, or ship Bun, Node, Deno, CFFI, a foreign library, or a hidden JavaScript runtime.
- Repository paths are relative and validated against traversal. SHA-256 selection supports `sha256sum`,
  `shasum -a 256`, and `openssl`.
- The registered package and HTTP scripts use local peers and ephemeral ports. Compatibility evidence does not
  require the public network; workflow setup still uses network access for checkout, package installation, and
  pinned toolchain archives.
- The Bun archives are metadata-only in Phase 27 and are not downloaded into compatibility scratch space.
- `references.tsv` copies no upstream code. Any future copied fixture or corpus must record origin, exact
  commit, path, license, modifications, and notices, with GPL-3.0-or-later compatibility reviewed separately.

## 12. Current limitations and Phase 73 boundary

The checked-in implementation establishes a useful public-claim seed, but it is not yet the full universal
feature-evidence system described for all later phases. In particular:

- the matrix is a flat 30-row summary with no child/API/CLI inventory;
- stored states are constrained but not derived from executed receipts;
- the runner has no typed differential envelope and does not execute Bun;
- `static` rows remain trace-only and do not run the referenced Lisp suite;
- platform rows remain `unverified` until publication evidence is deliberately reconciled;
- upstream path and asset bytes are not verified by the offline validator;
- benchmark immutability is not enforced across Git history; and
- evidence rows do not carry their own content digest, and CI receipts are not consumed by offline validation.

These limits must not be hidden by promoting a cell or broadening copy. Later phases may extend the schema and
runner while preserving the 30 stable summary IDs and generated-surface contract. Phase 73 still owns the
finite exhaustive scan of both Bun baselines, resolution of docs/types/source disagreements, and assignment of
every remaining exported API, CLI command/flag, loader, protocol, global/module member, and observable
behavior. It does not move either baseline or turn the Phase 27 summary into an exhaustive manifest by fiat.

## 13. Implementation and closeout order

The Phase 27 unit is completed in this order:

1. keep issue `#1`, SemVer impact `minor`, target `0.1.0-dev.7`, design, and local state synchronized;
2. validate the exact 30-row ledger, frozen baselines, references, assets, release row, and benchmark seed;
3. run the eight evidence records through the built `0.1.0-dev.7` binary;
4. generate README, site, and release-note blocks and prove checked-in byte identity;
5. run deliberate-drift, claims, roadmap, shell portability, and workflow-lint checks;
6. run the full build, test, purity, and four-target compatibility gates; and
7. record exact commits, workflow runs, tag, assets, installer, Pages deployment, and remaining limitations in
   the canonical issue before closing it.

No known limitation is converted into a `Yes` claim. A future enhancement that is outside this bounded unit
stays explicit and receives its owning phase or defect issue.

## 14. Acceptance gates

Phase 27 is complete only when all of these commands are green on the exact candidate:

```text
make compat-validate
make test-compat-tools
make docs-check
make build
make test
make purity
make compat FEATURE=all
make public-claims-check
make roadmap-check
make roadmap-verify-live
```

Additionally:

- README, site, and issue `#1` describe the same release, counts, status, owners, and limitations;
- no current `Partial` claim is promoted without executable evidence and all-target support;
- the four-platform compatibility workflow and exact four-receipt aggregation pass;
- the release workflow retains the checked generated preamble and generated changelog notes;
- Pages remains site-only;
- the `0.1.0-dev.7` tag is created only after required `master` checks pass; and
- independent review finds no unsupported claim, owner gap, baseline conflation, portability defect, purity
  violation, or licensing omission.
