# Pinned Bun Glob sources

This directory vendors the Glob test inventory from two immutable Bun commits:

- `stable/`: Bun 1.3.14, commit `0d9b296af33f2b851fcbf4df3e9ec89751734ba4`
- `engineering/`: Bun 1.4.0-dev, commit `c1076ce95effb909bfe9f596919b5dba5567d550`

The files under those directories are byte-for-byte `git show` exports from
`test/js/bun/glob/`, including the scan snapshot. The shared matcher fixtures are
the stable commit's `test/js/fixtures/glob/` files. `SHA256SUMS` pins every export
and `upstream-inventory.tsv` records a disposition for every lexical `test(` and
`expect(` site.

The source retains its upstream license headers. Bun itself is MIT licensed.
These files are test evidence only; Clun's implementation is independently
written in Common Lisp under GPL-3.0-or-later.

`upstream-match.sh` executes both complete `match.test.ts` bodies through the
shipped Clun binary. It mechanically removes Bun test-runner imports, injects the
checked harness and fixture directory, and rewrites engineering's `40_000` token
to the equivalent `40000` spelling because Clun does not yet parse numeric
separators. It does not rewrite patterns, candidates, or expected results.
