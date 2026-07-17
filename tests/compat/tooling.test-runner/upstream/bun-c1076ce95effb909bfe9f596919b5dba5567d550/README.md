# Pinned Bun test-runner manifest

This directory freezes the Phase 66 upstream result-root denominator at Bun commit
`c1076ce95effb909bfe9f596919b5dba5567d550` (Bun `1.4.0-dev`). `manifest.tsv` records the exact path and
SHA-256 digest of every test result root in `test/js/bun/test/` and its runner-specific subdirectories.

The denominator contains 52 roots in ten categories. `test/js/bun/test/parallel/` is excluded because that
directory is a vendored Node HTTP/module compatibility corpus, not a test-runner behavior corpus. Fixture,
snapshot, and helper dependencies are resolved from the same immutable checkout when a root executes; they
are not counted as independent result roots. The pinned types, docs, and Common Lisp engineering inventory
remain references rather than executable denominator entries.

The six result columns are deliberately `pending` until the exact pinned Bun engineering build and Clun run
that root. A root may be changed to numeric pass/fail/skip counts only with a reproducible receipt. No root
may be deleted, renamed, recategorized, or replaced in place after implementation; an upstream revision
requires a new manifest directory and an explicit canonical-issue decision.

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
