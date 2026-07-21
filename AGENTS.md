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

## Permanent product law (NEVER FORGET — user 2026-07-19)

**Epic:** [#177](https://github.com/theesfeld/clun/issues/177) FULL PORT.

1. **Prime directive:** Exceed Bun. Exceed npm. Exceed every comparison cell. Pure Common Lisp.
2. **There is no ledger `No` as a destination.** Every matrix row is a full-port target until **Yes**.
3. **Purity = implementation language is Common Lisp** (no CFFI / native libs / shell-outs as product implementation shortcuts). Purity is **never** a license to skip features, fail closed forever, or mark a row `No`.
4. **Qualified Yes is a No.** Soft ledger detail is forbidden:
   - banned while `clun_state=Yes`: "selected surface", "not full", "out of scope", "not included in v0.1", "excluded by purity", "Yes but", "remain incomplete"
   - if the port is incomplete, state is **Partial** (or **No** only while not started) — never a sugar-coated **Yes**
5. Agents must re-read this section every session on this repo.


---

## Keyword: `phase` / `phase NN`

Convenience only — **not** a second constitution and **not** a separate prompt file.

When the user message is exactly `phase` or `phase NN`:

1. **Select work** — `phase NN` → that phase (after dependency check from Issue / derived `PLAN.md`/`STATE.md`); else active phase from the canonical Issue (and derived `STATE.md`), or first unblocked phase if blocked. Prefer milestones on the phase Issue when split.
2. **Survey gate** — if this is a **new plan phase** never approved under the user standard, survey first (mandatory even under yolo / always-approve). Already-approved phases/milestones run autonomously.
3. **Issue first** → **branch** `feat/issue-<n>-…` off `master` → execute scope from Issue + derived `PLAN.md` + `docs/design/` → **verify** with § Gates → **PR** with `Closes #N` / `Refs #N` → squash-merge when green.
4. **Release** only if release-bearing: tag merge SHA per `docs/versioning.md`, verify assets + installer, evidence on Issue.
5. **Sync** Issue, README, `site/`, and derived `STATE.md`/`PLAN.md` in the same unit. Continue to the next unblocked milestone/phase without waiting for another `phase` message (unless a new phase needs survey).

Do not ask the user to paste a long phase prompt. Execute with maximum effort; keep merge gates under primary-agent ownership.

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

- **Man page (hard rule):** `man clun` content must always match actual current CLI functionality.
  Source of truth is `src/cli/catalog.lisp` (shared with `clun --help`). Regenerate with `make man`;
  `make man-check` (CI + release packaging) fails on drift. Never hand-edit `docs/man/clun.1` except via `make man`.


- Pure Common Lisp only: no CFFI, native libraries, implementation JS/TS, or shell-outs as implementation shortcuts.
- **Exceed Bun** (and npm/Node/Deno matrix peers) for every shipped surface. Do not invent parity exceptions or purity exclusions.
- Performance claims need reproducible same-host measurements; prefer measured exceedance, never silent under-delivery.
- Record architectural decisions in `DECISIONS.md` and on the Issue.
- Soft / qualified ledger **Yes** is forbidden — see Permanent product law above.

---

## Gates (Clun-specific)

Before merge of a phase/unit:

- Phase acceptance commands exactly as written in `PLAN.md` / Issue
- `make build`, `make test`, `make purity`
- **`make man-check`** whenever CLI surface or man generation changes (hard rule: man matches live CLI)
- Required conformance / portability / security / stress / benchmark gates for that unit
- When public docs/roadmap change: `make public-claims-check` and `make roadmap-check` (or live roadmap verify)
- Release-bearing:
  `BASE_SHA=<base> HEAD_SHA=<head> make version-transition-check`
  (bounds exactly this unit; must match Issue SemVer disposition)

Version files when behavior/claims change (same unit): `src/version.lisp`, ASDF core, version tests, installer default, README, site. Details: [`docs/versioning.md`](docs/versioning.md).

Publication evidence order (after squash-merge to `master`): tag → release assets + checksums → ledger/README/site → Pages → `https://clun.sh/install` smoke → Issue comments. Never move/reuse tags.

Historical train notes (keep accurate via Issues): active `0.1.0-dev.N` work; Phase 26 deferred until after Phase 82.
