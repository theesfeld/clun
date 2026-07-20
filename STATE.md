# STATE

**Derived resume cache** — not process constitution.
**Wins on conflict:** `~/.config/agents/AGENTS.md`, then the canonical GitHub Issue.
Ship path: topic branch → PR → squash-merge into `master` (not direct push).

---

## Current phase: **82 - Purity-compatible Bun-surface final audit and release**

**Canonical issue:** https://github.com/theesfeld/clun/issues/56
**Published release:** `0.2.0-dev.11` / `v0.2.0-dev.11`
**Tag peel:** `2e1957c01ac54d55238963e24a5624a21316f11a`
**Release run:** https://github.com/theesfeld/clun/actions/runs/29772871785
**Installer default:** `verified_installer_tag=v0.2.0-dev.11`

## Phase 82 final audit (§1.5 evidence)

Audit branch: `chore/issue-56-phase82-audit` · host linux-x64 · freeze tooling restored this unit.

### Gate map (PLAN → executable)

| PLAN gate | Executable | Status |
|-----------|------------|--------|
| `make compat-freeze --check` | `sh scripts/compat-freeze-check.sh --check` (Makefile alias deferred: Makefile is release-bearing under published `v0.2.0-dev.11`) | PASS (30 Yes; digests stable) |
| `make compat-validate --frozen` | `make compat-validate` + freeze-check | PASS |
| `make compat FEATURE=all` | same | pending receipt |
| `make compat-bench FEATURE=full-surface --compare bun` | `make bench-check` (Bun compare via docs/benchmarks.md) | pending |
| `make docs-check` | same | PASS |
| `make build` | same | PASS |
| `make test` | same | CI skips perf (`CLUN_SKIP_PERFORMANCE_TESTS=1`); local quiet re-run pending |
| `make conformance-exec` | same | PASS — 26,018 pass-list hold, 0 crash |
| `make test-crypto` | same | PASS |
| `make test-tls` | same | PASS |
| `make purity` | same | PASS |

### §1.5 Definition of Done

1. **Feature-evidence gate:** 30/30 public matrix features `Yes` (`make compat-validate`).
2. **Primary owner + executable evidence:** every feature has roadmap `primary_phase`; evidence under `tests/compat/` and `compat/evidence.tsv`.
3. **Baselines not conflated:** Bun 1.3.14 stable `0d9b296af3…` for public compare; engineering pin `c1076ce95e` (Bun 1.4.0-dev) for forward inventory — both pinned in `compat/baselines.tsv` and asserted by `compat-freeze-check` (no baseline refresh).
4. **Four-platform ship:** published `v0.2.0-dev.11` Release assets (linux/mac × x64/arm64) + checksums; installer SHA-256 verified path.
5. **Performance honesty:** no blanket faster-than-Bun claims; workload evidence via `bench-check` / `docs/benchmarks.md`.
6. **Surfaces agree:** `make docs-check` + `make public-claims-check`; site redesign #287 preserves generator markers.
7. **Unsupported claims:** zero Partial/No on landing matrix. Explicit notes remain for experimental pure-CL TLS and user-native FFI boundary (`src/ffi/machine-boundary.lisp`, Issue #265).

### Freeze digest (compat-freeze-check)

Recorded when green: 30 features all Yes; baselines bun-stable-1.3.14 + bun-engineering-c1076ce95e pinned.

## Next

- Finish remaining Phase 82 receipts (`compat FEATURE=all`, quiet `make test`, `bench-check`).
- Close #56 only with green receipts + adversarial review note on the Issue.
- Phase 26 (#58) stays blocked until Phase 82 closes, then re-baseline design before implementation.
