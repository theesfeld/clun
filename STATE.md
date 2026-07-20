# STATE

**Derived resume cache** — not process constitution.
**Wins on conflict:** `~/.config/agents/AGENTS.md`, then the canonical GitHub Issue.
Ship path: topic branch → PR → squash-merge into `master` (not direct push).

---

## Current phase: **82 - Purity-compatible Bun-surface final audit and release** *(audit complete pending merge)*

**Canonical issue:** https://github.com/theesfeld/clun/issues/56
**Published surface release:** `0.2.0-dev.11` / `v0.2.0-dev.11`
**Tag peel:** `2e1957c01ac54d55238963e24a5624a21316f11a`
**Release run:** https://github.com/theesfeld/clun/actions/runs/29772871785
**Installer default:** `verified_installer_tag=v0.2.0-dev.11`

## Phase 82 final audit — §1.5 evidence (2026-07-20)

**Audit host:** linux-x64 · exclusive sequential run (no concurrent builders)  
**Log:** `tmp-test/phase82-exclusive.log`  
**Window:** 2026-07-20T16:31:53 → 16:40:48 local

### Gate map (PLAN → executable)

| PLAN gate | Executable | Result |
|-----------|------------|--------|
| `make compat-freeze --check` | `sh scripts/compat-freeze-check.sh --check` | **PASS** — 30 Yes; freeze digest `02488b08178a4d6a5c1b22ecbfccdb70ddd5b42131b1355274e9de07bf89cae4` |
| `make compat-validate --frozen` | `make compat-validate` + freeze-check | **PASS** |
| `make compat FEATURE=all` | same | **PASS** — 137 executable evidence records + 47 static traces |
| `make compat-bench FEATURE=full-surface --compare bun` | `make bench-check` | **PASS** — off/eager checksums + compile-tier telemetry |
| `make docs-check` | same | **PASS** |
| `make build` | same | **PASS** |
| `make test` | `CLUN_SKIP_PERFORMANCE_TESTS=1 make test` (matches CI) | **PASS** — 19878 assertions, 0 fail |
| `make conformance-exec` | same (prior exclusive host run) | **PASS** — 26018 pass-list hold, 0 crash |
| `make test-crypto` | same (prior run) | **PASS** |
| `make test-tls` | same (prior run) | **PASS** |
| `make purity` | same | **PASS** — 865 sources, 0 violations |

### §1.5 Definition of Done

1. **Feature-evidence:** 30/30 public matrix features `Yes`.
2. **Primary owner + evidence:** every feature has roadmap `primary_phase`; 137 executable + 47 static evidence records green under `make compat FEATURE=all`.
3. **Baselines not conflated:** Bun 1.3.14 stable `0d9b296af3…` + engineering pin `c1076ce95e` asserted by freeze-check (no baseline refresh).
4. **Four-platform ship:** published `v0.2.0-dev.11` assets (linux/mac × x64/arm64) + checksums; CI Compatibility matrix on freeze PR.
5. **Performance honesty:** `bench-check` only (same-host off/eager identity); no blanket faster-than-Bun claims.
6. **Surfaces agree:** docs-check + public-claims-check; site redesign #287 preserved markers.
7. **Unsupported claims:** zero Partial/No. Explicit notes: pure-CL TLS experimental; user-native FFI boundary allowlisted (`src/ffi/machine-boundary.lisp`, #265).

### Surface release tag disposition

`v0.2.0-dev.11` is the purity-compatible surface prerelease tag. Phase 82 audit confirms §1.5 against that published boundary. Freeze-check tooling lands as non-release-bearing script + STATE (Makefile alias deferred until a release-bearing slot because Makefile is version-gated under a published tag).

## Next

- Merge freeze-check PR (#288) when CI green.
- Close #56 with evidence comment.
- Unblock Phase 26 (#58): re-inventory system, rewrite finite design/checklist/SemVer, then implement hardening (not start coding until design rebaseline is recorded on the Issue).
