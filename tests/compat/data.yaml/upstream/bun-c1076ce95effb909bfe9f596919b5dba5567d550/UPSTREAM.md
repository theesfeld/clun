# Pinned Bun YAML test corpus

This directory preserves Bun's generated YAML parser corpus at engineering
baseline commit
[`c1076ce95effb909bfe9f596919b5dba5567d550`](https://github.com/oven-sh/bun/blob/c1076ce95effb909bfe9f596919b5dba5567d550/test/js/bun/yaml/yaml-test-suite.test.ts).
The source header records the underlying `yaml-test-suite` revision as
[`6e6c296ae9c9d2d5c4134b4b64d01b29ac19ff6f`](https://github.com/yaml/yaml-test-suite/tree/6e6c296ae9c9d2d5c4134b4b64d01b29ac19ff6f).
Both projects identify their source as MIT-licensed. Bun's pinned license file
is preserved as `LICENSE.bun.md`.

`yaml-test-suite.upstream.test.ts` is byte-for-byte upstream source.
`yaml-test-suite.clun.test.ts` is a deterministic test-only translation that
removes Bun-specific imports and replaces `YAML.parse` with
`Clun.YAML.parse`. `run.sh` reproduces that translation, checks both pinned
digests, executes all 402 named cases through the shipped Clun binary, and
compares every result with `baseline.tsv`.

The baseline is a classification receipt, not a parity waiver. Run the current
receipt with:

```sh
make test-yaml-upstream
```

The completion gate is deliberately red until every case passes:

```sh
make test-yaml-upstream-full
```
