# Phase 00 — Scaffold, toolchain, purity gate

Objective: an empty-but-real project where every later gate has rails. This doc records the build
system's shape and the design of the `tests/js` harness (whose runner is deferred to Phase 08).

## Toolchain

- **SBCL 2.6.4** on `PATH` (pinned; poll-backed serve-event, `:sb-thread`, `clock-gettime` all
  verified — PLAN.md Appendix C). ASDF 3.3.1 via `(require :asdf)`; `uiop` present.
- **GNU Make 4.4.1** — required by every phase gate (`make build|test|purity`). Not present by
  default on the NixOS host; installed into the user profile (`nix profile add nixpkgs#gnumake`).
  Recorded in DECISIONS.md.
- **No quicklisp.** All CL dependencies are vendored + pinned under `vendor/` and located by
  `scripts/registry.lisp`, which pushes the repo root (holding `clun.asd`) and every `vendor/*/`
  directory onto `asdf:*central-registry*`. This deliberately avoids an ASDF source-registry
  `:tree` scan so the big `vendor-data/` corpora (test262 etc., added later) never get walked.

## Build system

```
clun.asd                system "clun" (src/) and "clun/tests" (tests/lisp + parachute)
scripts/registry.lisp   central-registry setup; defines *clun-root*
scripts/build.lisp      load :clun, stamp git revision, save-lisp-and-die -> build/clun
scripts/test.lisp       load :clun/tests, run (parachute:test :clun-test), exit 0/1
scripts/purity-scan.lisp  the purity gate (below)
Makefile                build | test | purity | clean
src/packages.lisp       one package per subsystem (PLAN.md §3.7), :use :cl only
src/version.lisp        *clun-version* = "0.0.1-dev", *clun-revision*
src/main.lisp           toplevel: argv dispatch for --version/--revision/--help
```

Key decisions:

- **Binary via `save-lisp-and-die`** with `:executable t :toplevel #'clun:main
  :save-runtime-options t`. The last option is essential: without it, the saved runtime would parse
  `--version`/`--help` itself instead of passing them to `clun:main`.
- **ASDF `:version` is `"0.0.1"`** (dotted integers, ASDF's grammar); the user-facing string lives
  only in `src/version.lisp` as `"0.0.1-dev"` — the two are intentionally distinct.
- **Hermetic Make**: `--non-interactive --no-userinit --no-sysinit` so no user/system CL init leaks
  in. Build tooling scripts run in `CL-USER` (no in-package) and share `*clun-root*`.
- **Revision stamping** is optional build metadata (`git rev-parse --short HEAD`, `ignore-errors`);
  absence yields `"unknown"`. This is build tooling, not a runtime crutch — the §6 no-bare-
  `ignore-errors` rule targets the runtime condition bridge, not the build script.

## Purity gate (`scripts/purity-scan.lisp`)

Per PLAN.md §1.1, no CFFI/foreign code is allowed outside SBCL itself. The scan covers "the full
ASDF load plan and all vendored sources". Design:

- **Union of the load plan and an on-disk scan.** (1) The load plan: `asdf:required-components` for
  `clun` and `clun/tests` with `:other-systems t` — every `cl-source-file` actually compiled into
  the image, including vendored deps. (2) An on-disk scan of `src/`, `tests/`, and `vendor/` (plus
  root `*.asd`) — which additionally catches files a library ships but loads only conditionally
  (e.g. pure-tls's win/darwin CFFI files before Phase 19 strips them) that the plan omits. The union
  is a superset of the load plan by construction. (The first cut scanned only `src/` + `vendor/` and
  missed `tests/lisp/*` — caught and fixed in the Phase 00 review panel.)
- **Forbidden tokens** (case-insensitive substrings): `cffi`, `foreign-funcall`, `sb-alien`,
  `define-alien`, `make-alien`, `alien-funcall`, `load-shared-object`, `load-foreign`, `%foreign`.
- **`scripts/` is not scanned** — it is build tooling (not load-plan / not vendored), and this file
  necessarily contains the tokens as its own search patterns.
- Reads files as `latin-1` so any byte decodes without error (we only match ASCII).
- Exit 0 + a "clean — N files scanned" line, or exit 1 listing every `path:line: token`.
- **Verified both ways**: clean tree → exit 0; a planted `cffi:foreign-funcall` under `src/` →
  nonzero with the violation reported (negative test run during Phase 00, per §6).

## tests/js harness (design; runner deferred to Phase 08)

The in-image parachute suites cannot naturally assert process exit codes, uncaught-error rendering,
or byte-exact micro/macrotask ordering. The `tests/js` harness fills that gap by running fixtures
through the built `build/clun` binary as a black box.

**Fixture format** (one directory per case, or a flat file + sibling manifest):

```
tests/js/<group>/<case>.js            # the source to execute (also .mjs/.cjs/.ts/…)
tests/js/<group>/<case>.expected      # expectation manifest (see below)
```

The `.expected` manifest is a small key/value block, e.g.:

```
argv: run <case>.js            # how to invoke (default: run the sibling source file)
exit: 0                        # expected exit code
stdout: |
  hello
  world
stderr:                        # empty unless specified
```

**Runner (Phase 08)**: a CL script (`scripts/run-js-fixtures.lisp`, driven by a `make` target and
by `make test`) that, for each fixture, spawns `build/clun` via `sb-ext:run-program`, captures
stdout/stderr/exit, and compares against the manifest — exact string match for stdout/stderr, `=`
for exit. Cleanup (`unwind-protect`), ephemeral temp dirs, no order dependence (§6). Ordering-
sensitive cases (Phase 06/14) live here permanently; expect-style cases migrate onto `clun test` in
Phase 15 but keep a thin meta-fixture asserting the runner's own output/exit codes.

Deferred because the harness can only assert on a binary that executes JavaScript, which does not
exist until `clun run`/`-e` land in Phase 08. Phase 00 ships the format spec and the directory.
