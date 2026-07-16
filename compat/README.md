# Compatibility ledger

This directory is the canonical, machine-readable seed for Clun compatibility claims. The
landing matrix is a 30-row summary, not an exhaustive claim of Bun parity. Bun 1.3.14 stable is
the public comparison baseline; Bun 1.4.0-dev at `c1076ce95e` is a separate engineering inventory.
The two Bun baseline roles must never be substituted for one another. Node.js 26.5.0 is pinned at
`bebd1b8d92bf4cc917844d6335ed1ecf9c2a75fb`, and Deno 2.9.3 is pinned at
`f39575ecd50602a5b42b1ba8e93849460de9fcf4`.

All `.tsv` files use UTF-8, one header row, literal tabs as delimiters, and `-` as the only empty
field sentinel. Values may not contain literal tabs or newlines. Rows sort by their first stable ID
and then by the next identity column. Comma-separated fields are sorted and contain no spaces.
Stable feature, evidence, workload, and metric IDs are permanent; a semantic change to an immutable
workload or metric requires a new `.vN` ID.

## Tables

- `baselines.tsv` pins the four selected runtime/channel roles with strict versions, full revisions,
  coherent tags, semantic snapshot dates, revision-pinned sources, and upstream licenses.
- `features.tsv` owns every shared README/site matrix field and the primary/integration phase map.
- `platforms.tsv` records all four release targets for every feature. `unverified` is not support.
- `evidence.tsv` references existing shipped-binary fixtures, checked end-to-end scripts, and static
  suites. A `clun-fixture` row compares exact process output; a `checked-script` row must prove its
  own binary-level assertions and exit successfully. A `static` row is supporting seed evidence,
  not a passing platform attestation.
- `references.tsv` maps each summary feature independently to stable and engineering Bun sources plus
  pinned Node.js and Deno primary-repository sources. Comparison assertions exactly snapshot each
  runtime's `state: detail` fields from `features.tsv`.
- `release.tsv` reconciles the current Clun version, ASDF core, installer default, tag, publication
  state, canonical STATE phase/issue, and exact tagged commit once published.
- `upstream-assets.tsv` pins the four Bun 1.3.14 release binaries used by later stable probes.
- `benchmarks/workloads.tsv` and `benchmarks/metrics.tsv` freeze the four existing Phase 25
  self-relative workloads. They contain no Clun-versus-Bun performance claim.

Feature states are `Yes`, `Partial`, `No`, or `Separate`. Platform support states are `supported`,
`unverified`, `unsupported`, and `not-applicable`. The validator rejects a Clun `Yes` unless
shipped-binary evidence is registered for every required target, and keeps a feature partial when any
required platform remains unverified. A public promotion updates the feature, evidence, four platform
rows, active release, generated documents, and canonical issue as one reviewed unit.

Display-group keys are `core`, `apis`, `tooling`, and `utilities`; renderers own their human-facing
labels. Evidence kinds are `fixture`, `suite`, `report`, `decision`, and `benchmark`. Evidence runner
tokens are `clun-fixture`, `checked-script`, and `static`. Executable rows declare their intended
four-target scope; `-` denotes supporting evidence without an independent platform attestation.

The compatibility metadata in this directory is part of Clun and is distributed under
GPL-3.0-or-later. Upstream paths, URLs, release hashes, names, and factual assertions are references,
not copied Bun, Node.js, or Deno implementation code. Their source repositories retain the licenses
recorded in `baselines.tsv`. The existing benchmark sources are referenced by path and digest rather
than copied into this directory; their source headers and `docs/benchmarks.md` remain the provenance
record for those fixtures.
