# STATE

**Derived resume cache** — not process constitution.
**Wins on conflict:** `~/.config/agents/AGENTS.md`, then the canonical GitHub Issue.
Ship path: topic branch → PR → squash-merge into `master` (not direct push).

---

## Current phase: **26 - Final hardening, docs, and release**

**Canonical issue:** https://github.com/theesfeld/clun/issues/58
**Prior phase:** Phase 82 (#56) **closed** — purity-compatible surface audit complete
******Published surface tip:** `0.2.0-beta.1` / `v0.2.0-beta.1`
**Tag peel:** `d8bd2a090bee1012ab59e60101d42a079c857a7f`
**Release run:** https://github.com/theesfeld/clun/actions/runs/29787884879
**Installer default:** `verified_installer_tag=v0.2.0-beta.1`
**Installer default:** `verified_installer_tag=v0.2.0-dev.11` until beta.1 assets publish
**SemVer impact:** `minor` (maturity promotion dev→beta + hardening; no intentional matrix expansion)

---

## Phase 26 rebaseline inventory (2026-07-20)

### Shipped surface (do not regress)

| Fact | Value |
|------|--------|
| Public matrix | 30 Yes / 0 Partial / 0 No |
| Baselines | Bun 1.3.14 stable + engineering `c1076ce95e` |
| test262 pass list | 26,018 frozen; rate 92.38% |
| Platforms | linux/mac × x64/arm64 release assets |
| Install | Pages `curl|sh` → `~/.local/bin`; `clun --update` |
| CLI | Human errors, progress spinner, chromed install (dev.11) |
| TLS | Pure-CL stack; CI `make test-tls` / alerts / OpenSSL interop |
| Freeze gate | `sh scripts/compat-freeze-check.sh --check` |
| Hardening gate | `make phase-26-gate` + `scripts/phase-26-hardening-smokes.sh` |

### Open program after Phase 82

- Only **#58** (this phase) open as program work until beta.1 closes it.
- No Partial/No matrix residuals.

### Dispositioned residuals (explicit, not silent)

| Item | Disposition |
|------|-------------|
| Local-time / TZif | Unassigned for this phase; keep UTC-correct core |
| Third-party WebPKI audit | Not claimed; CI TLS gates remain the shipping bar |
| HTTP/2 server | Out of matrix claim |
| Darwin long soak (historical #59) | Deterministic fix shipped; four-platform release CI is beta gate |
| Stable `0.2.0` | **Not** this unit — beta.1 only |

### SemVer train

- **Impact class:** `minor`
- **Core:** `0.2.0`
- **From:** published `0.2.0-dev.11`
- **To:** `0.2.0-beta.1` (maturity ladder `dev` → `beta` at `.1`)

---

## Finite Phase 26 checklist

### A. Design & inventory

- [x] Re-inventory shipped surface and open findings
- [x] Finite checklist recorded
- [x] Issue #58 body rewritten for beta.1
- [x] Design notebook `docs/design/phase-26.md`

### B. Hardening

- [x] User-reachable errors: no bare Lisp backtrace without `--backtrace` (hardening smoke)
- [x] Resource-plateau stress (400 write/read/unlink cycles)
- [x] Interruption / SIGINT cancel path (busy timer smoke)
- [x] Partial-install recovery (bogus `clun add` preserves package root)
- [x] Long-run server smoke (bounded ~1.2s serve+fetch)
- [ ] Platform matrix green on four targets for release-bearing unit (CI)

### C. Docs & surfaces

- [x] README + site track Phase 26 / beta.1 candidate; Phase 82 complete
- [x] Security posture honest: TLS tested in CI; third-party audit not claimed
- [x] CHANGELOG + release notes for `0.2.0-beta.1`
- [ ] `make public-claims-check` + `make docs-check` green (pre-merge)

### D. Release

- [x] Version surfaces staged `0.2.0-beta.1` / `v0.2.0-beta.1` (candidate; installer remains dev.11)
- [x] Tag immutable; four native assets + checksums
- [x] Installer + update path target published assets
- [ ] Close Issue #58 with evidence comment
- [ ] Installer + `clun --update` smoke on published assets
- [ ] Evidence on Issue #58; close when checklist complete

### Gates

`make phase-26-gate` · four-platform Compatibility + Release CI · exact-master Documentation

---

## Phase 82 archive (§1.5)

See closed Issue #56. Summary: exclusive gates green 2026-07-20; freeze-check restored; surface tag `v0.2.0-dev.11`.

## Next

1. Land release-bearing PR; exact-SHA CI/Docs/Compat green.
2. Annotated tag `v0.2.0-beta.1`; Release workflow assets.
3. Reconcile publication + installer default; close #58.

