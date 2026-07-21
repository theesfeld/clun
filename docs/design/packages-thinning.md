# Thinning `src/packages.lisp` (ElonOptimizer P3 / Issue #318)

## Goal
Keep the package graph readable as the codebase grows. `src/packages.lisp` is the
historical single file of every `defpackage`; it is not a process constitution.

## Rules
1. New subsystems land as `src/packages/<name>.lisp` (or a dedicated subsystem
   file under their own module) rather than growing the monolith.
2. Each extract is a pure move of an existing `defpackage` form — no API change.
3. ASDF `clun` remains `:serial t` for the packages layer so load order is
   deterministic.
4. Do not invent second process playbooks here; ship path stays Issue → branch → PR.

## Done (first cuts)
| Package | File |
|---------|------|
| `clun.csrf` | `src/packages/csrf.lisp` |
| `clun.color` | `src/packages/color.lisp` |

## Next candidates (easiest → largest export surface)
1. `clun.password` / `clun.hash` / `clun.text.string-width`
2. `clun.glob` / `clun.semver`-related if split further
3. Large surfaces (`clun.engine`, `clun.net`, `clun.runtime`) last — they couple
   to many files; extract only with a dedicated Issue.

## Non-goals
- Relicense or restructure public symbols
- One mega-PR that rewrites the whole packages graph
