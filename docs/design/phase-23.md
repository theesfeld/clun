# Phase 23 — Install: resolver, linker, lockfile, CLI

**Objective (PLAN §5/§3.5):** `clun install` / `add` / `remove` for real, hermetic-first against the
Phase-21 local registry fixture. Built on the Phase-21 registry client + semver, the Phase-22 tarball
extractor + content-addressed cache, and Phase-20 HTTPS. All CL-side under `src/install/`, package
`clun.installer` (semver stays `clun.install`; registry `clun.registry`; tarball `clun.tarball`).

**Gate:** a fixture-graph e2e — install → `clun run` an app importing the results → exact output; delete
`node_modules` → reinstall from the lock OFFLINE (fixture down) → byte-identical lock; `--frozen-lockfile`
drift errors; an opt-in logged live `clun add ms` smoke.

## Milestones (a ~4k-LOC phase; one committed-green milestone per iteration)

1. **Install engine** (this milestone): a JSON writer; the resolver; placement (hoist); the linker
   (download → cache → extract → link + bin); the lockfile; a top-level `install`; a hermetic CL-level e2e.
2. **CLI wiring**: `clun install`/`add`/`remove` dispatch, package.json editing (`-d/-D`, `-E`), flags
   (`--dry-run`/`--production`/`--no-save`/`--frozen-lockfile`), `clun run <app>` e2e, live smoke.

## 1. JSON writer (`src/sys/json.lisp`, +`write-json`)

The reader's representation (objects = order-preserving alists, arrays = vectors, numbers = doubles,
strings, and the `json-true/false/null` sentinels) round-trips back out: `write-json (value &key (indent 2)
sort-keys)` → a string. `sort-keys` gives the lockfile its deterministic key order; integers print without
a trailing `.0`. No new dependency (PLAN §3.5: one hand-rolled JSON file).

## 2. Resolver (`src/install/resolver.lisp`)

Breadth-first, highest-satisfying, cycle-safe, over the async registry client. `resolve-install (loop
root-deps &key registry on-ok on-err)`:
- `need-metadata name k` fetches `name`'s abbreviated metadata ONCE (cached per name; `fetch-metadata-async`)
  then calls `k`; a pending counter fires `on-ok` when every in-flight fetch has settled.
- `resolve-edge parent name range`: pick the highest version in the metadata satisfying `range`
  (`clun.install:version-satisfies` + `version-compare`; a `dist-tag` like `latest` resolves via
  `dist-tags`); record an `inst-node` (name, version, resolved deps, dist tarball+integrity, bin) keyed
  `name@version`; recurse into its deps. A `name@version` already resolved is reused (cycle-safe — the edge
  is still recorded for placement, but resolution does not recurse again).
- Output: `(values nodes edges)` — `nodes` = hash `name@version → inst-node`; `edges` = list of
  `(parent-key name version)` (parent-key is `:root` or a `name@version`).

## 3. Placement / hoist (`src/install/resolver.lisp`)

`plan-layout (nodes edges)` → a list of `(install-rel-dir . inst-node)`. Walk edges breadth-first from
`:root`; for each `parent → name@version`, place it at the SHALLOWEST `node_modules` with no conflicting
different version of `name`:
- try the root `node_modules` (`""`): if root has no `name`, or already has `name@version`, place at root;
- else (root has a different version) place NESTED under the parent: `<parent-dir>/node_modules/<name>`.
This hoists the BFS-first version to the top and nests genuine conflicts (the fixture's `shared@1.0.0` vs
`shared@2.0.0` diamond forces exactly one nesting). A hoist conflict that cannot be represented is an honest
error, never a silent wrong layout.

## 4. Linker (`src/install/linker.lisp`)

`link-package (node install-abs &key fetch-tarball)`: obtain the `.tgz` bytes — `clun.tarball:cache-fetch`
by integrity, else `fetch-tarball` (async http GET of `dist.tarball`) then `cache-store` (verifies) — and
`clun.tarball:extract-package` to `install-abs` with the package's `dist.integrity` (verify-then-commit).
After all packages are extracted, create `bin` symlinks: for each package with a `bin` map, symlink each bin
target into the nearest `node_modules/.bin` and `chmod +x` the target (PLAN §3.5). **Lifecycle scripts are
NEVER executed** — collected and logged at the end (stricter than Bun, documented loudly).

## 5. Lockfile (`src/install/lockfile.lisp`)

`clun.lock` = versioned JSON (`lockfileVersion`, and a `packages` object keyed by install path → `{version,
resolved (tarball URL), integrity, dependencies}`), deterministic key order (`write-json :sort-keys t`).
`write-lock (root plan)`; `read-lock (root)`; `lock-fresh-p (lock root-deps)` — the lock still satisfies the
root deps (used to skip re-resolution); `--frozen-lockfile` → `lock-drift-error` if resolution would change
the lock. The lock records enough to reinstall OFFLINE from the cache (resolved URL + integrity + deps).

## 6. Top-level install + e2e (this milestone)

`install (root-dir &key registry frozen production loop)`: read `root-dir/package.json` deps (+ devDeps
unless `production`); resolve → plan-layout → link (download/extract) → write-lock; return a summary.
Hermetic CL-level e2e (`tests/lisp/install/install-tests.lisp`): start the Phase-21 fixture registry, write
a root `package.json` depending on `@scope/widget` (→ `left-pad@^1.1.0`) and `conflict-a`+`conflict-b`
(→ the `shared` diamond) in a temp dir; `install`; assert the hoisted layout (`left-pad`, `shared@2` at
root; `shared@1` nested under `conflict-a`), that each `package.json` extracted, and integrity held; then
delete `node_modules`, stop the fixture, reinstall from the lock via the cache OFFLINE, and assert a
BYTE-IDENTICAL lock; assert `--frozen-lockfile` errors when a dep is bumped.

## 7. Risks / notes

- Async resolution is a pending-counter work loop over `fetch-metadata-async`; a single `run-loop` drives
  resolve + download. Extraction is blocking but fast (fixtures); it runs inline on the loop thread between
  downloads (acceptable for v1; a worker offload is post-v1).
- Placement is the subtle part; the diamond-conflict fixture is the gate's discriminator. A 3rd conflicting
  version (post-v1) would need deeper nesting — v1 handles one level of nesting per name honestly.
- The security-critical extraction is Phase 22 (already adversarially reviewed); this milestone's review
  focuses on resolution correctness, hoist correctness, offline-reinstall determinism, and lock drift.
