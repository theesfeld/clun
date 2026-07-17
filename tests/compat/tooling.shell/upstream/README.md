# Pinned Bun shell evidence

This directory contains read-only evidence snapshots for Phase 65. `stable` is Bun 1.3.14 at
`0d9b296af33f2b851fcbf4df3e9ec89751734ba4`; `engineering` is Bun 1.4.0-dev at
`c1076ce95effb909bfe9f596919b5dba5567d550`.

Each snapshot includes the complete `test/js/bun/shell` tree, shell documentation and public types,
the runtime/parser source trees used at that revision, the JavaScript/native public bridge files, and
the exact upstream license. `SHA256SUMS` and `../upstream-files.tsv` make the normal verification path
offline and fail closed. `scripts/shell-upstream-sync.sh` is only for deliberate regeneration from the
pinned Git objects; it must not be run as a CI dependency.

`../upstream-corpus.tsv` enumerates every lexical `test`, `it`, and test-builder site in those exact
snapshots. Each row is independently `covered`, `pending`, or `not-applicable` only when the pinned source
marks it inactive. `make shell-upstream-yes-check` is deliberately red until no pending site remains and
all four supported-target receipts are registered.

Bun source and tests retain their upstream MIT license as recorded in each baseline's `LICENSE.md`.
