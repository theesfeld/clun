# Phase 29: Public SemVer API

## 1. Objective and boundary

Phase 29 converts the existing `utility.semver` compatibility row from an honest `No` into a
shipped, evidence-backed `Yes`. Clun already uses one pure Common Lisp SemVer implementation for
package installation. This phase exposes the Bun-compatible public surface over that same engine;
it does not add a second parser, broaden the API beyond Bun's two public operations, or reinterpret
installer-only Common Lisp helpers as public JavaScript support.

The public contract is:

```js
Clun.semver.satisfies(version, range) // boolean
Clun.semver.order(a, b)               // -1 | 0 | 1
```

`Bun.semver` is the upstream behavioral shape. Clun exposes the object on its existing `Clun`
global; this phase does not introduce a `Bun` global or a `bun` module alias. Documentation and
compatibility claims must say that `Clun.semver` implements the Bun SemVer contract, not that every
unrelated Bun global or module import exists.

The canonical GitHub issue is [#3](https://github.com/theesfeld/clun/issues/3). It owns live status,
decisions, review findings, target receipts, publication, and closeout evidence. `PLAN.md` is the
derived technical contract, `STATE.md` is the derived resume cache, and `compat/` is the canonical
machine-readable public-claim input.

## 2. Survey and frozen references

The implementation is based on the already-pinned Phase 27 baselines:

| Role | Version/ref | Exact commit | Relevant paths |
|---|---|---|---|
| Public Bun baseline | Bun 1.3.14 | `0d9b296af33f2b851fcbf4df3e9ec89751734ba4` | `docs/runtime/semver.mdx`, `packages/bun-types/bun.d.ts`, `src/semver_jsc/SemverObject.zig` |
| Engineering inventory | Bun 1.4.0-dev | `c1076ce95effb909bfe9f596919b5dba5567d550` | `docs/runtime/semver.mdx`, `packages/bun-types/bun.d.ts`, `src/semver_jsc/SemverObject.rs` |
| Shared Clun engine | Phase 21 | current tree | `src/install/semver.lisp` |
| Node SemVer corpus | vendored Phase 21 pin | current tree | `tests/fixtures/semver/` |

The pinned Bun docs and types define exactly two public functions. Direct execution of the pinned
Bun 1.3.14 `linux-x64-baseline` asset (SHA-256
`a063908ae08b7852ca10939bbdc6ceed3ddabce8fb9402dce83d65d73b36e6c7`) and the pinned engineering
bridge add observable edge behavior not spelled out by the docs: both functions reject fewer than two
arguments before coercion; `satisfies` string-coerces both arguments and returns false for an invalid
version, range, or non-ASCII input; `order` string-coerces both arguments, returns `-1`, `0`, or `1`,
throws a generic JavaScript `Error` for an invalid ASCII version, and returns `0` if either coerced
string contains a non-ASCII code unit. Stable Bun executable probes are kept as review evidence on
issue #3; checked-in fixtures cover every behavior relied on by the public claim without copying Bun
implementation code.

The stable Bun executable is deliberately more permissive than its own docs and node-semver for some
malformed ranges and versions. Phase 29 follows the documented promise that invalid input to `satisfies`
returns false and retains Clun's node-semver-compatible strict engine instead of copying those parser bugs.
The issue records this as a correctness improvement and preserves exact Bun differential cases for valid
input, coercion, argument-count errors, non-ASCII behavior, ordering, and invalid `order` errors.

The existing Clun engine is a pure Common Lisp port of the pinned node-semver grammar and behavior.
It already covers strict versions, prerelease precedence, build metadata, exact/comparator/caret/
tilde/hyphen/x/star/OR ranges, loose parsing options used internally, range intersection, and the
vendored node-semver fixtures. Phase 29 keeps those installer semantics intact.

## 3. Runtime architecture

### 3.1 One SemVer engine

`src/install/semver.lisp` remains the only version/range parser and comparator. The runtime bridge
calls its exported `version-satisfies` and `version-compare` operations directly. No grammar,
regular expression, range expansion, precedence rule, or validity rule is duplicated under
`src/runtime/`.

Because the SemVer implementation is engine-free install substrate, `clun.asd` loads the install
module before the JavaScript engine/runtime rather than relying on a late-bound symbol lookup. This
also makes the existing layering explicit: system/network/install substrate may be consumed by the
engine-facing runtime, while the install substrate never depends on JavaScript objects.

### 3.2 JavaScript bridge

`src/runtime/clun-semver.lisp` builds a plain object with two enumerable, writable, configurable native
function properties. This matches Bun's observable `Object.keys` and method descriptor shape rather than
the non-enumerable convention used by many prototype methods:

- Both methods first require two supplied arguments and otherwise throw a catchable JavaScript
  `Error` with Bun's `Expected two arguments` message.
- `satisfies(version, range)` then performs JavaScript `ToString` left-to-right, applies the same
  narrow single-`=` version-prefix option, and calls `clun.install:version-satisfies`; invalid
  version/range or non-ASCII inputs return the JavaScript boolean `false`.
- `order(a, b)` then performs JavaScript `ToString` left-to-right, accepts Bun's observed single
  optional `=` prefix through an explicit parser option, and otherwise uses the strict shared
  parser before `clun.install:version-compare`; the integer result is returned as a JavaScript number. An
  `invalid-version` condition is translated to a catchable JavaScript `Error` rather than escaping
  as a host Common Lisp condition. If either coerced string is non-ASCII, the method returns `0`
  before parsing, matching the pinned Bun bridge.

The bridge coerces the Common Lisp comparison integer to `double-float`; returning the host integer
directly would expose a JavaScript BigInt in Clun's value model. Fixtures assert both the values and
`typeof result === "number"`.

Normal JavaScript coercion failures, including a throwing user-defined `toString`, propagate as the
original JavaScript exception. Build metadata does not affect precedence.
The narrow `=` option does not enable loose numeric identifiers or partial versions; those remain
documented correctness improvements over the pinned Bun binary and are executable matrix cases.

`src/runtime/clun-global.lisp` attaches one bridge object as `Clun.semver` when a runtime realm is
installed. Matching the pinned Bun namespace descriptor, the `semver` property itself is enumerable,
non-writable, and non-configurable; its two method properties retain the writable/enumerable/configurable
shape above. The executable fixture checks the descriptors and proves the namespace cannot be replaced or
deleted through `Reflect`.

## 4. Correctness corpus

The phase uses four complementary layers:

1. The existing Lisp SemVer suite continues to run every applicable vendored node-semver fixture
   against the shared engine. This is the full parser/range regression layer and remains part of
   `make test`.
2. Runtime tests evaluate JavaScript in a real Clun realm. They cover object/method presence,
   argument-count checks, left-to-right string coercion, invalid/non-ASCII behavior, error
   catchability, prerelease precedence, ignored build metadata, and representative exact/caret/
   tilde/hyphen/x/star/OR ranges.
3. `tests/compat/utility.semver/basic.js` crosses the built `build/clun` process boundary and checks
   the pinned Bun public shape, valid behavior, coercion, errors, and measured strict divergences with
   exact output.
4. `tests/compat/utility.semver/corpus.js` drives every applicable strict public `satisfies`/`order`
   row from the vendored node-semver fixtures through `build/clun`. Rows requiring the non-public
   `loose` or `includePrerelease` options are explicitly outside Bun's two-method API. The full
   15-file engine corpus, including increment/truncate/outside/intersection operations that Bun does
   not expose here, remains mandatory under `make test`.

`compat/evidence.tsv` registers the public, Bun-edge, and node-corpus executable fixtures for all four
release targets and a static trace to the full engine suite.
`tests/compat/utility.semver/bun-1.3.14-edge-matrix.tsv` records every measured malformed/edge probe and
every additional Bun divergence found while replaying the 261-row public corpus,
including matched behavior, both upstream and Clun outcomes, and the explicit disposition;
`edge-matrix.js` executes all of those intended Clun outcomes through the shipped binary.

Static trace evidence may point to the full Lisp/node-semver corpus, but it cannot satisfy a target
support claim by itself. Every supported target must execute the public shipped-binary fixture.

## 5. Compatibility-ledger transition

The row may change only as one atomic green unit:

| Field | Before | Candidate after evidence |
|---|---|---|
| `clun_state` | `No` | `Yes` |
| `clun_detail` | `installer-internal only` | `` `Clun.semver` satisfies and order `` |
| `gap` | public API absent | `-` |
| Four platform states | `unsupported` | `supported` |
| Target evidence | `-` | public shipped-binary evidence ID |

The canonical gate uses the stable feature ID:

```sh
make compat FEATURE=utility.semver
```

The obsolete shorthand `FEATURE=semver` is not a ledger ID and is corrected in `PLAN.md` and the
generated issue contract. A `Yes` is invalid unless `compat-validate` can prove target-scoped
executable evidence for Linux and macOS on x64 and arm64.

Generated README, landing page, and release notes must come only from the updated ledger. `compat/README.md`
also changes from seed-only wording to the live support-state rules. Public files are
not edited to claim support before the evidence registration and gates are green.

## 6. Release and synchronization

This is backward-compatible public functionality, so issue #3 records SemVer impact `minor`. Within
the current unpublished `0.1.0` prerelease train, the candidate is `0.1.0-dev.8` under immutable tag
`v0.1.0-dev.8`; the ASDF core remains `0.1.0`.

The candidate unit synchronizes:

- `src/version.lisp`, version assertions, and `site/install`;
- `compat/release.tsv` as `candidate` / `pending`, active Phase 29, issue #3;
- `compat/features.tsv`, `compat/evidence.tsv`, and `compat/platforms.tsv`;
- generated `README.md`, `site/index.html`, and `docs/releases/current.md`;
- `PLAN.md`, `STATE.md`, `DECISIONS.md`, and the technical-contract block/live evidence on issue #3.

Publication follows `docs/versioning.md`: topic PR to `master`, exact-commit gates, squash merge,
annotated immutable tag on the merge commit, native archives and checksums, published-ledger
reconciliation, release-gated Pages, hosted installer smoke, then issue closeout. A docs-only
reconciliation/deployment does not rebuild native release artifacts.

## 7. Acceptance gates

The implementation is complete only when all of the following are true:

1. `make compat FEATURE=utility.semver` passes the pinned Bun public differential and every applicable
   strict public node-semver row through `build/clun`.
2. The complete existing 15-file installer/node-semver engine suite passes with no regression under
   `make test`.
3. `make build`, `make test`, and `make purity` pass.
4. `make docs-check`, `make public-claims-check`, and roadmap checks pass.
5. `BASE_SHA=<phase-base> HEAD_SHA=<candidate> make version-transition-check` accepts the exact
   `minor` dev.7-to-dev.8 transition recorded on issue #3.
6. Compatibility CI executes the public fixture successfully on `linux-x64`, `linux-arm64`,
   `darwin-x64`, and `darwin-arm64`, producing receipts tied to the exact candidate commit.
7. Review confirms that invalid inputs cannot escape as host conditions, the runtime does not fork
   the parser, and the ledger does not overclaim a `Bun` global/module alias.

## 8. Explicit non-goals and handoff

Phase 29 does not add npm publishing, TLS interoperability, globbing, cookies, hashing, routing,
TypeScript transforms, or broad Node/Bun compatibility. Those rows remain unchanged.

After Phase 29 is published, the compatibility-ledger program continues from easiest to hardest
among dependency-ready rows. Current cost order after SemVer is CSRF, cookies, terminal string
width, then CSS color; each remains subject to its canonical phase issue, mandatory survey/design,
real core implementation, executable target evidence, and synchronized public claims. Phase 26
remains deferred until after Phase 82 and will be re-baselined against the state that exists then.
