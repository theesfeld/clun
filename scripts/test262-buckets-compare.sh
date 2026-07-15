#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

if [ "$#" -ne 2 ]; then
  printf 'usage: %s GENERATED_GAPS GENERATED_REPORT\n' "$0" >&2
  exit 2
fi

generated_gaps=$1
generated_report=$2
canonical_gaps=tests/conformance/exec-gaps.tsv
canonical_report=docs/conformance/test262-execution.md

for path in "$generated_gaps" "$generated_report" "$canonical_gaps" "$canonical_report"; do
  [ -f "$path" ] || {
    printf 'test262-buckets-compare: missing file: %s\n' "$path" >&2
    exit 2
  }
done

source_revision() {
  sed -n \
    -e 's/^# source-revision: //p' \
    -e 's/^| source-revision | `\([^`]*\)` |$/\1/p' \
    "$1"
}

for path in "$generated_gaps" "$generated_report" "$canonical_gaps" "$canonical_report"; do
  revision=$(source_revision "$path")
  printf '%s\n' "$revision" | grep -Eq '^(working-tree@)?[0-9a-f]{40}$' || {
    printf 'test262-buckets-compare: invalid source revision in %s: %s\n' \
      "$path" "${revision:-<missing>}" >&2
    exit 2
  }
done

scratch_parent=${TMPDIR:-/tmp}
mkdir -p "$scratch_parent"
scratch_dir=$(mktemp -d "$scratch_parent/clun-test262-compare.XXXXXX")
trap 'rm -rf "$scratch_dir"' 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

normalize_gaps() {
  sed \
    -e '/^# source-revision: /d' \
    -e '/^# classification-ledger: /d' \
    "$1"
}

normalize_report() {
  sed \
    -e '/^| source-revision | /d' \
    -e '/^| classification-ledger | /d' \
    "$1"
}

normalize_gaps "$canonical_gaps" >"$scratch_dir/canonical-gaps"
normalize_gaps "$generated_gaps" >"$scratch_dir/generated-gaps"
normalize_report "$canonical_report" >"$scratch_dir/canonical-report"
normalize_report "$generated_report" >"$scratch_dir/generated-report"

if ! cmp -s "$scratch_dir/canonical-gaps" "$scratch_dir/generated-gaps"; then
  diff -u "$scratch_dir/canonical-gaps" "$scratch_dir/generated-gaps" >&2 || :
  printf '%s\n' 'test262-buckets-compare: checked-in gap snapshot is stale' >&2
  exit 1
fi

if ! cmp -s "$scratch_dir/canonical-report" "$scratch_dir/generated-report"; then
  diff -u "$scratch_dir/canonical-report" "$scratch_dir/generated-report" >&2 || :
  printf '%s\n' 'test262-buckets-compare: checked-in execution report is stale' >&2
  exit 1
fi

printf '%s\n' 'test262-buckets-compare: live ledger matches checked-in inventory'
