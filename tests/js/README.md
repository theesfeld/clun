# tests/js — stdout/exit-code fixture harness

Black-box fixtures that run a source file through the built `build/clun` binary and assert on its
**stdout, stderr, and exit code**. This harness covers behavior the parachute (in-image) suites
can't reach naturally: process exit codes, uncaught-error rendering, and micro/macrotask ordering
where byte-exact output is the assertion.

**Design and format:** see `docs/design/phase-00.md` § "tests/js harness".

**Status:** the runner is *designed* in Phase 00 but activated in **Phase 08**, once `clun run`/`-e`
can actually execute JavaScript. Until then this directory holds only the format spec. Fixtures are
authored alongside the phases that make them runnable; ordering-sensitive cases stay here even after
the Phase 15 migration of expect-style suites onto `clun test`.
