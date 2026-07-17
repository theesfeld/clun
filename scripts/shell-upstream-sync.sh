#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
upstream=$repo_root/tests/compat/tooling.shell/upstream
repo=oven-sh/bun

require() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'shell upstream sync: %s is required\n' "$1" >&2
    exit 2
  }
}

require gh
require base64

fetch_blob() (
  sha=$1
  destination=$2
  mkdir -p "$(dirname -- "$destination")"
  gh api "repos/$repo/git/blobs/$sha" --jq .content |
    tr -d '\n' | base64 -d > "$destination"
)

fetch_tree() (
  tree=$1
  destination=$2
  prefix=$3
  listing=$(mktemp "${TMPDIR:-$repo_root/tmp-test}/clun-shell-tree.XXXXXX")
  trap 'rm -f "$listing"' EXIT HUP INT TERM
  gh api "repos/$repo/git/trees/$tree?recursive=1" \
    --jq 'if .truncated then error("truncated tree") else .tree[] | select(.type == "blob") | [.path, .sha] | @tsv end' > "$listing"
  while IFS="$(printf '\t')" read -r path sha; do
    fetch_blob "$sha" "$destination/$prefix/$path"
  done < "$listing"
  rm -f "$listing"
  trap - EXIT HUP INT TERM
)

sync_baseline() (
  baseline=$1
  commit=$2
  license_blob=$3
  docs_blob=$4
  types_blob=$5
  tests_tree=$6
  runtime_tree=$7
  runtime_path=$8
  parser_tree=$9
  shift 9

  destination=$upstream/$baseline
  rm -rf "$destination"
  mkdir -p "$destination"
  printf '%s\n' "$commit" > "$destination/COMMIT"
  fetch_blob "$license_blob" "$destination/LICENSE.md"
  fetch_blob "$docs_blob" "$destination/docs/runtime/shell.mdx"
  fetch_blob "$types_blob" "$destination/packages/bun-types/shell.d.ts"
  fetch_tree "$tests_tree" "$destination" test/js/bun/shell
  fetch_tree "$runtime_tree" "$destination" "$runtime_path"
  fetch_tree "$parser_tree" "$destination" src/shell_parser

  while [ "$#" -gt 0 ]; do
    path=$1
    blob=$2
    shift 2
    fetch_blob "$blob" "$destination/$path"
  done
)

sync_baseline stable \
  0d9b296af33f2b851fcbf4df3e9ec89751734ba4 \
  81069ee8d3b84f21ee32b2a9766643e1de114863 \
  c4cc47901c789cce56d79412ef5e0039a433f86e \
  41c198edd22c14874fdcf3662c8e305c340c7e0d \
  efe64727227598249e7fc56141152f2ff7a5f7cc \
  47cd21a8fff209d4fb4b519d70dd782c02453e36 src/shell \
  db3feac277b71101006dcb6328fdb712ec512333 \
  src/js/builtins/shell.ts f1d19bb84acd5d5cbd6eef66c39b920aaa36436b \
  src/jsc/bindings/ShellBindings.cpp f015c9280b4a54c79a70da5613c9b9641cbb5257 \
  src/runtime/api/Shell.classes.ts c806f045930338260d113ed0c8dba20ddfac6596

sync_baseline engineering \
  c1076ce95effb909bfe9f596919b5dba5567d550 \
  a7fcf0503086963dd1146a3f3ee2db3ccfa891e7 \
  153df9860f9a77591a9079b9ccb366a830bfc4b5 \
  6f7d33e9597321018655e518b21d03c0dee0d759 \
  d60575ccbb5fc7dd7843c0cf407d2da30a03a074 \
  304bb8eccd4d20f7c04b9a7eb3411fd30895af4b src/runtime/shell \
  fd6d9fac85f661bcf373e9efde7cfee9f790c5f4 \
  src/js/builtins/shell.ts f1d19bb84acd5d5cbd6eef66c39b920aaa36436b \
  src/jsc/bindings/ShellBindings.cpp f015c9280b4a54c79a70da5613c9b9641cbb5257 \
  src/runtime/api/Shell.classes.ts 695472608b291bb64a437148736f9dc41dd500e1

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$upstream" && find stable engineering -type f ! -name SHA256SUMS -print0 |
    sort -z | xargs -0 sha256sum) > "$upstream/SHA256SUMS"
else
  (cd "$upstream" && find stable engineering -type f ! -name SHA256SUMS -print |
    sort | while IFS= read -r file; do shasum -a 256 "$file"; done) > "$upstream/SHA256SUMS"
fi

printf 'shell upstream sync: materialized exact stable and engineering snapshots\n'
