# Clun — repository overlay

**Inherits:** `~/.config/agents/AGENTS.md` (sole process constitution for all owned work).
This file is **project facts only** — language, paths, gates, and the `phase` shortcut.
It does **not** redefine process. On conflict, the user standard wins. **No legacy process standards.**

| Fact | Value |
|------|--------|
| Class | **Product** (CLI) |
| Default branch | `master` (do not rename; PR base only) |
| License | GPL-3.0-or-later |
| Language | Pure Common Lisp (not Rust — no cargo-dist; **same release outcomes** as user standard §0.1 / §8) |
| Install | `https://clun.sh/install` / Pages installer |
| Bun reference | `/home/glenda/Projects/bun` — **read-only upstream**; never modify; never copy license-incompatible code |

Ship path: user standard **§5.0** (Issue → branch `…/issue-N-…` → PR → squash-merge into `master`). No direct push to `master` as the ship path.

---

## Keyword: `phase` / `phase NN`

Convenience only — **not** a second constitution and **not** a separate prompt file.

When the user message is exactly `phase` or `phase NN`:

1. **Select work** — `phase NN` → that phase (after dependency check from Issue / derived `PLAN.md`/`STATE.md`); else active phase from the canonical Issue (and derived `STATE.md`), or first unblocked phase if blocked. Prefer milestones on the phase Issue when split.
2. **Survey gate** — if this is a **new plan phase** never approved under the user standard, survey first (mandatory even under yolo / always-approve). Already-approved phases/milestones run autonomously.
3. **Issue first** → **branch** `feat/issue-<n>-…` off `master` → execute scope from Issue + derived `PLAN.md` + `docs/design/` → **verify** with § Gates → **PR** with `Closes #N` / `Refs #N` → squash-merge when green.
4. **Release** only if release-bearing: tag merge SHA per `docs/versioning.md`, verify assets + installer, evidence on Issue.
5. **Sync** Issue, README, `site/`, and derived `STATE.md`/`PLAN.md` in the same unit. Continue to the next unblocked milestone/phase without waiting for another `phase` message (unless a new phase needs survey).

Do not ask the user to paste a long phase prompt. Always spawn multiple subagents for bounded work, use
maximum reasoning effort, and keep merge gates under primary-agent ownership.

---

## Tracking surfaces

| Surface | Role |
|---------|------|
| **GitHub Issues** | Live SoT |
| `PLAN.md` | Technical notebook (phase specs) — **derived**; repair if it disagrees with Issues |
| `STATE.md` | Resume checklist — **derived** |
| `DECISIONS.md` | Decision log — mirror material decisions on the Issue |
| `README.md` + `site/` | Public claims; no publication gap vs Issue |

---

## Implementation constraints

- Pure Common Lisp only: no CFFI, native libraries, implementation JS/TS, or shell-outs as implementation shortcuts.
- Match or exceed frozen Bun behavior where constitutionally compatible; do not weaken tests or invent parity exceptions.
- Performance claims need reproducible same-host measurements. No unqualified “faster than Bun” claims.
- Record architectural decisions in `DECISIONS.md` and on the Issue.

---

## Gates (Clun-specific)

Before merge of a phase/unit:

- Phase acceptance commands exactly as written in `PLAN.md` / Issue
- `make build`, `make test`, `make purity`
- Required conformance / portability / security / stress / benchmark gates for that unit
- When public docs/roadmap change: `make public-claims-check` and `make roadmap-check` (or live roadmap verify)
- Release-bearing:
  `BASE_SHA=<base> HEAD_SHA=<head> make version-transition-check`
  (bounds exactly this unit; must match Issue SemVer disposition)

Version files when behavior/claims change (same unit): `src/version.lisp`, ASDF core, version tests, installer default, README, site. Details: [`docs/versioning.md`](docs/versioning.md).

Publication evidence order (after squash-merge to `master`): tag → release assets + checksums → ledger/README/site → Pages → `https://clun.sh/install` smoke → Issue comments. Never move/reuse tags.

Historical train notes (keep accurate via Issues): active `0.1.0-dev.N` work; Phase 26 deferred until after Phase 82.

---

## Multi-agent PM loop (Clun facts)

Process law remains `~/.config/agents/AGENTS.md`. This section is **how to staff Clun**, not a second constitution.

### Parallel issue trains (mandatory rule)

**Multiple Issues run at once.** Under-staffing is a process failure.

| Rule | Requirement |
|------|-------------|
| **Min open trains** | Keep **≥3 concurrent open issue trains** whenever unblocked Issues or ready Partial/Yes work exists (each train = Issue + worktree + `feat/issue-N-…` branch + PR when code exists) |
| **Team per train** | Each train has its own small agent team: implementer, gates/tests, **CI babysitter for that PR only**, adversarial review before any ledger `Yes` |
| **PM never waits alone** | The primary agent must not block the session on one babysitter or one CI poll. Empty slots → spawn the next train |
| **Actions vs agents** | **GitHub Actions** verify (CI / Compatibility / Docs / Pages / Release). **Agents implement.** Do not invent a mega Actions job that codes features |
| **Parallel impl, ordered merge** | Implementation is parallel. Release-bearing prerelease slots (`0.1.0-dev.N`) may open in parallel under unpublished-gap policy, but **merge/publish order** follows the SemVer train so later slots do not land before earlier ones without re-slotting |
| **Cap** | Prefer **3–5** open trains so rebases stay sane; raise only when independence is clear |

Slamming ledger rows means parallel **implementation** of independent features/phases. Ledger **`Yes`** still requires four-target receipts and adversarial review per unit—no promotion spam.

### Never-stall rule

The primary (PM) agent **must not** block the session on a single long waiter (CI, builds, one subagent). If a lane is waiting, spawn or resume another lane. The parallel-train minimum above supersedes any weaker “≥2 lanes” habit.

### Roles

| Role | Job |
|------|-----|
| **PM (primary)** | Issue selection, spawn trains, merge when gates green, SemVer disposition, refuse silent scope expansion |
| **Issue controller** | Labels, evidence comments, status flips, queue next Issue from roadmap/ledger cost order |
| **Lane implementer** | One Issue → one worktree → one branch → code/tests/local gates |
| **CI babysitter** | Per open PR: watch checks, fetch failure logs, fix reds on that branch only |
| **Surface sync** | When claims/version/status change: Issue + `README.md` + `site/` in the **same unit** |
| **Adversarial review** | Before any ledger `Yes` promotion; force `Partial` if evidence is weak |

### Worktree isolation (mandatory)

```
clun/                            # PM only: default branch, status, no long impl
clun-worktrees/<lane>/           # one Issue branch per worktree
```

Implementers set `cwd` to their worktree. **Never** `git checkout` another Issue branch in a shared tree mid-session.

### Yes queue discipline

Prefer dependency-ready ledger conversions easiest→hardest. Do not promote `Yes` without four-target receipts and review. Partial checkpoints may merge when honest (and release-bearing when SemVer policy requires a prerelease advance).

### Issue controller cadence

After each lane report: comment evidence (SHA, CI runs, gate output), update `status:*` labels, close only with acceptance proof. Do not invent a second tracker outside GitHub Issues.
