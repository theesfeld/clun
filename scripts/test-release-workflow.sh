#!/bin/sh
# shellcheck disable=SC2016 # Workflow-contract anchors intentionally match literal variables.

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp_parent=${TMPDIR:-/tmp}
if [ ! -d "$tmp_parent" ]; then
  tmp_parent=.
fi
work_dir=$(mktemp -d "$tmp_parent/clun-release-workflow-test.XXXXXX")
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

expected_sha=0123456789abcdef0123456789abcdef01234567
runs_tsv=$work_dir/runs.tsv
{
  printf '101\tCI\t.github/workflows/ci.yml\t%s\tmaster\tpush\tcompleted\tsuccess\n' "$expected_sha"
  printf '102\tDocumentation\t.github/workflows/docs.yml\t%s\tmaster\tpush\tcompleted\tsuccess\n' "$expected_sha"
  printf '103\tCompatibility\t.github/workflows/compat.yml\t%s\tmaster\tpush\tcompleted\tsuccess\n' "$expected_sha"
  # Pages may be present in the dump but is not required for the pre-tag exact-SHA gate.
  printf '104\tPages\t.github/workflows/pages.yml\t%s\tmaster\tpush\tcompleted\tsuccess\n' "$expected_sha"
  printf '90\tPages\t.github/workflows/pages.yml\tffffffffffffffffffffffffffffffffffffffff\tmaster\tpush\tcompleted\tsuccess\n'
} >"$runs_tsv"

sh "$repo_root/scripts/release/verify-exact-sha-runs.sh" \
  "$runs_tsv" "$expected_sha" >/dev/null

# Missing Pages must still pass (Pages is post-assets).
awk -F '\t' '$3 != ".github/workflows/pages.yml"' \
  "$runs_tsv" >"$work_dir/missing-pages.tsv"
sh "$repo_root/scripts/release/verify-exact-sha-runs.sh" \
  "$work_dir/missing-pages.tsv" "$expected_sha" >/dev/null

expect_run_failure() {
  fixture=$1
  label=$2
  if sh "$repo_root/scripts/release/verify-exact-sha-runs.sh" \
      "$fixture" "$expected_sha" >/dev/null 2>&1; then
    printf 'release-workflow fixture: %s unexpectedly passed\n' "$label" >&2
    exit 1
  fi
}

awk -F '\t' -v OFS='\t' '
  $2 == "Compatibility" { $5 = "topic" }
  { print }
' "$runs_tsv" >"$work_dir/topic-compatibility.tsv"
expect_run_failure "$work_dir/topic-compatibility.tsv" 'topic-branch Compatibility run'

awk -F '\t' -v OFS='\t' '
  $3 == ".github/workflows/docs.yml" { $2 = "Docs" }
  { print }
' "$runs_tsv" >"$work_dir/wrong-name.tsv"
expect_run_failure "$work_dir/wrong-name.tsv" 'wrong workflow name at the expected path'

awk -F '\t' -v OFS='\t' '
  $3 == ".github/workflows/ci.yml" { $3 = ".github/workflows/not-ci.yml" }
  { print }
' "$runs_tsv" >"$work_dir/wrong-path.tsv"
expect_run_failure "$work_dir/wrong-path.tsv" 'wrong workflow path despite the expected name'

awk -F '\t' -v OFS='\t' '
  $3 == ".github/workflows/docs.yml" { $7 = "in_progress"; $8 = "" }
  { print }
' "$runs_tsv" >"$work_dir/in-progress.tsv"
expect_run_failure "$work_dir/in-progress.tsv" 'newest Documentation run still in progress'

awk -F '\t' -v OFS='\t' '
  $3 == ".github/workflows/compat.yml" { $8 = "failure" }
  { print }
' "$runs_tsv" >"$work_dir/failed-conclusion.tsv"
expect_run_failure "$work_dir/failed-conclusion.tsv" 'failed Compatibility conclusion'

awk -F '\t' -v OFS='\t' '
  $3 == ".github/workflows/compat.yml" { $4 = "ffffffffffffffffffffffffffffffffffffffff" }
  { print }
' "$runs_tsv" >"$work_dir/wrong-sha.tsv"
expect_run_failure "$work_dir/wrong-sha.tsv" 'wrong Compatibility head SHA'

# Missing Compatibility must fail.
awk -F '\t' '$3 != ".github/workflows/compat.yml"' \
  "$runs_tsv" >"$work_dir/missing-compat.tsv"
expect_run_failure "$work_dir/missing-compat.tsv" 'missing exact-path Compatibility run'

duplicate_id=$work_dir/duplicate-id.tsv
cp "$runs_tsv" "$duplicate_id"
printf '104\tPages\t.github/workflows/pages.yml\t%s\tmaster\tpush\tcompleted\tsuccess\n' \
  "$expected_sha" >>"$duplicate_id"
expect_run_failure "$duplicate_id" 'duplicate workflow run id'

# release.yml must invoke the helper once and must not require Pages in its success message.
[ "$(grep -Fxc '          sh scripts/release/verify-exact-sha-runs.sh "$master_runs" "$tagged_commit"' \
  "$repo_root/.github/workflows/release.yml")" -eq 1 ] || {
  printf 'release-workflow fixture: claims job does not use the exact-SHA helper once\n' >&2
  exit 1
}

printf 'release-workflow fixture: exact-SHA gate (CI+Docs+Compat; Pages optional) ok\n'
