# Phase 62 — Bundler core (FULL PORT #180 / epic #177)

## Decision

Ship a pure Common Lisp production bundler that meets and exceeds `Bun.build` for
the `tooling.bundler` ledger row. Soft or qualified Yes is forbidden.

## Surface

| API | Role |
|-----|------|
| `Clun.build(config)` | Async Bun.build-compatible build |
| `Clun.buildSync(config)` | Synchronous build (**exceed**) |
| `Clun.build.analyze(config)` | Graph-only analysis (**exceed**) |
| `clun build <entry…>` | CLI production bundle |

### Config (Bun-aligned)

- entrypoints, outdir, outfile, root, target, format (`esm`/`cjs`/`iife`)
- splitting, minify (bool or granular), loader map
- external, packages (`bundle`/`external`), define, publicPath
- naming templates (`[name]`, `[hash]`, `[ext]`)
- sourcemap (`none`/`inline`/`linked`/`external`), banner, footer
- drop, features, env inlining, files (virtual), metafile
- treeShaking, throw, conditions

### Loaders

`js`, `ts`, `tsx`, `jsx`, `json`, `text`, `file`, `dataurl`, `css`, `html`

### Exceed Bun

1. `Clun.build.analyze` — dependency graph without writing outputs
2. `Clun.buildSync` — sync path for tooling/scripts
3. Content-hashed assets by default for the file loader
4. Hermetic virtual `files` map for offline/test bundles

## Implementation

- Package `clun.bundler` (`src/bundler/core.lisp`)
- JS boundary `src/runtime/clun-build.lisp`
- Reuses pure-CL resolver, TypeScript strip, JSX transform
- No CFFI / native bundler process

## Evidence

- Lisp suite: `tests/lisp/bundler/bundler-tests.lisp`
- Public fixture: `tests/compat/tooling.bundler/basic.js`
- Ledger: `features.tsv` Yes, platforms ×4 supported
