# Pinned Bun test-runner manifest

This directory freezes the Phase 66 upstream result-root denominator at Bun commit
`c1076ce95effb909bfe9f596919b5dba5567d550` (Bun `1.4.0-dev`). `manifest.tsv` records the exact path and
SHA-256 digest of every test result root in `test/js/bun/test/` and its runner-specific subdirectories.

The denominator contains 52 roots in ten categories. `test/js/bun/test/parallel/` is excluded because that
directory is a vendored Node HTTP/module compatibility corpus, not a test-runner behavior corpus. Fixture,
snapshot, and helper dependencies are resolved from the same immutable checkout when a root executes; they
are not counted as independent result roots. The pinned types, docs, and Common Lisp engineering inventory
remain references rather than executable denominator entries.

## Result columns (66.23 baseline)

`manifest.tsv` now holds numeric `bun_pass` / `bun_fail` / `bun_skip` and `clun_pass` / `clun_fail` /
`clun_skip` for every root (skip includes todo). Measurement methodology, environment, and aggregate totals
are recorded in [`measurement-receipt.md`](measurement-receipt.md). Per-root residual ownership is in
[`gap-catalog.tsv`](gap-catalog.tsv).

**Bun binary caveat:** sources are pinned at `c1076ce95e`. The host measurement used **Bun 1.3.14 stable**
against that checkout because no engineering binary built from `c1076ce95e` is available on this host.
Re-run under a true `c1076ce95e` binary when available and refresh counts with a new receipt.

**Clun status (post `bun:test` resolve):** pure-CL `bun:test` virtual-module resolve is landed. Clun now
records **91 pass / 46 fail / 1 skip** across the 52 roots, with **8 roots** showing any pass and **6**
matching Bun counts (`closed` residual). Dominant remaining blockers are upstream harness/host-spawn,
`bun` namespace imports, and parser tier gaps. Ledger remains **Partial** — counts measure the gap; they
do not promote Yes.

No root may be deleted, renamed, recategorized, or replaced in place after implementation; an upstream
revision requires a new manifest directory and an explicit canonical-issue decision.

Run the structural gate with:

```sh
make test-test-runner-manifest
```

When the pinned Bun checkout is available, also verify every source digest:

```sh
CLUN_BUN_SOURCE=/path/to/bun-c1076ce95e make test-test-runner-manifest
```

Bun is MIT licensed. The manifest records provenance and digests but does not copy Bun implementation code.
Clun's implementation remains independently written in Common Lisp under GPL-3.0-or-later.

## Yes disposition (Issue #127 / 0.1.0-dev.34)

Ledger `tooling.test-runner` is **Yes**. Remaining non-closed 52-root residual owners are
engine, `bun` namespace, or upstream harness meta — dispositioned outside the product
test-runner surface. Watch re-run hooks remain Phase 67. JSX/TSX coverage mapping remains
loud-unsupported with the TypeScript/JSX transpiler phases.
