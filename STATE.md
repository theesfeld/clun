# STATE

**Derived resume cache** — not process constitution.
**Wins on conflict:** `~/.config/agents/AGENTS.md`, then the canonical GitHub Issue.
Ship path: topic branch → PR → squash-merge into `master` (not direct push).

---

## Current phase: **26 - Final hardening, docs, and release**

**Canonical issue:** https://github.com/theesfeld/clun/issues/58
**Prior phase:** Phase 82 (#56) **closed** — purity-compatible surface audit complete
**Published surface tip:** `0.2.0-dev.11` / `v0.2.0-dev.11`
**Tag peel:** `2e1957c01ac54d55238963e24a5624a21316f11a`
**Release run:** https://github.com/theesfeld/clun/actions/runs/29772871785
**Installer default:** `verified_installer_tag=v0.2.0-dev.11`

---

## Phase 26 rebaseline inventory (2026-07-20)

### Shipped surface (do not regress)

| Fact | Value |
|------|--------|
| Public matrix | 30 Yes / 0 Partial / 0 No |
| Baselines | Bun 1.3.14 stable + engineering `c1076ce95e` |
| test262 pass list | 26,018 frozen; rate 92.38% |
| Platforms | linux/mac × x64/arm64 release assets |
| Install | Pages `curl\|sh` → `~/.local/bin`; `clun --update` |
| CLI | Human errors, progress spinner, chromed install (dev.11) |
| TLS | Pure-CL stack; CI `make test-tls` / alerts / OpenSSL interop |
| Freeze gate | `sh scripts/compat-freeze-check.sh --check` |

### Open program after Phase 82

- Only **#58** (this phase) open as program work.
- No Partial/No matrix residuals.

### Dispositioned residuals (explicit, not silent)

| Item | Disposition |
|------|-------------|
| Local-time / TZif | Unassigned for this phase unless stress proves user-facing pain; keep UTC-correct core |
| Third-party WebPKI audit | Not claimed; CI TLS gates remain the shipping bar |
| HTTP/2 server | Out of matrix claim (honest “no HTTP/2 server” copy) |
| Throughput flake under load | CI skips host perf (`CLUN_SKIP_PERFORMANCE_TESTS=1`); quiet-host re-measure optional |
| Stable `0.2.0` | **Not** assumed — only after Phase 26 checklist green |

### SemVer train (provisional)

- **Impact class:** `minor` (hardening/docs/release; no intentional matrix expansion)
- **Core:** keep `0.2.0` until completed work forces otherwise
- **Slots:** continue prerelease `0.2.0-dev.N` for intermediate hardening releases
- **Stable tag:** only if final checklist warrants promoting out of `-dev` — decide at checklist close, not at entry

---

## Finite Phase 26 checklist

### A. Design & inventory

- [x] Re-inventory shipped surface and open findings (this file + Issue #58)
- [x] Finite checklist recorded (below)
- [ ] Issue #58 body rewritten to match this rebaseline (live SoT)

### B. Hardening

- [ ] User-reachable errors: resource, rejected value, constraint, remedy; no bare Lisp backtrace without `--backtrace`
- [ ] Resource-plateau stress (steady-state handles/RSS under repeated open/close)
- [ ] Interruption / cancel paths (install, serve, spawn)
- [ ] Partial-install recovery (failed mid-graph leaves tree consistent)
- [ ] Largest-fixture / long-run server smoke (bounded duration, documented)
- [ ] Platform matrix still green on four targets for any release-bearing unit

### C. Docs & surfaces

- [ ] README + site status track Phase 26 (#58); Phase 82 marked complete
- [ ] Security posture page/section honest: TLS **tested** in CI; third-party audit not claimed
- [ ] Release notes / CHANGELOG for final slot
- [ ] `make public-claims-check` + `make docs-check` green

### D. Release

- [ ] Version + CHANGELOG + installer default for chosen slot
- [ ] Tag immutable; four native assets + checksums
- [ ] Installer + `clun --update` smoke
- [ ] Evidence on Issue #58; close only when checklist complete

### Gates (every unit + final)

`make build` · `make test` · `make purity` · `make docs-check` · `make public-claims-check` ·  
`sh scripts/compat-freeze-check.sh --check` · `make compat FEATURE=all` (release-bearing) ·  
`make test-tls` · `make test-crypto` · four-platform Compatibility CI

---

## Phase 82 archive (§1.5)

See closed Issue #56 and prior STATE section retained in git history / Issue comments. Summary: exclusive gates green 2026-07-20; freeze-check restored; surface tag `v0.2.0-dev.11`.

## Next

1. Sync Issue #58 body + README status to Phase 26 active.
2. Execute checklist B–D on `feat/issue-58-…` trains (prefer error-path + stress first).
3. Publish only with evidence on #58.
