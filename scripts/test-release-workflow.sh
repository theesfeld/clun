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
  printf '104\tPages\t.github/workflows/pages.yml\t%s\tmaster\tpush\tcompleted\tsuccess\n' "$expected_sha"
  printf '90\tPages\t.github/workflows/pages.yml\tffffffffffffffffffffffffffffffffffffffff\tmaster\tpush\tcompleted\tsuccess\n'
} >"$runs_tsv"

sh "$repo_root/scripts/release/verify-exact-sha-runs.sh" \
  "$runs_tsv" "$expected_sha" >/dev/null

expect_run_failure() {
  fixture=$1
  label=$2
  if sh "$repo_root/scripts/release/verify-exact-sha-runs.sh" \
      "$fixture" "$expected_sha" >/dev/null 2>&1; then
    printf 'release-workflow fixture: %s unexpectedly passed\n' "$label" >&2
    exit 1
  fi
}

awk -F '\t' '$3 != ".github/workflows/pages.yml"' \
  "$runs_tsv" >"$work_dir/missing-pages.tsv"
expect_run_failure "$work_dir/missing-pages.tsv" 'missing exact-path Pages run'

awk -F '\t' -v OFS='\t' -v sha="$expected_sha" '
  $3 == ".github/workflows/pages.yml" && $4 == sha { $6 = "workflow_dispatch" }
  { print }
' "$runs_tsv" >"$work_dir/non-push-pages.tsv"
expect_run_failure "$work_dir/non-push-pages.tsv" 'non-push Pages run'

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

latest_failed=$work_dir/latest-failed.tsv
cp "$runs_tsv" "$latest_failed"
printf '999\tPages\t.github/workflows/pages.yml\t%s\tmaster\tpush\tcompleted\tfailure\n' \
  "$expected_sha" >>"$latest_failed"
expect_run_failure "$latest_failed" 'older Pages success followed by a newer failure'

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

duplicate_id=$work_dir/duplicate-id.tsv
cp "$runs_tsv" "$duplicate_id"
printf '104\tPages\t.github/workflows/pages.yml\t%s\tmaster\tpush\tcompleted\tsuccess\n' \
  "$expected_sha" >>"$duplicate_id"
expect_run_failure "$duplicate_id" 'duplicate workflow run id'

sh "$repo_root/scripts/release/verify-tagged-master.sh" \
  "$expected_sha" "$expected_sha" >/dev/null
if sh "$repo_root/scripts/release/verify-tagged-master.sh" \
    1123456789abcdef0123456789abcdef01234567 "$expected_sha" >/dev/null 2>&1; then
  printf 'release-workflow fixture: ancestor/non-tip tag unexpectedly passed\n' >&2
  exit 1
fi

valid_assets=$work_dir/valid-assets
mkdir "$valid_assets"
for target in linux-x64 linux-arm64 darwin-x64 darwin-arm64; do
  printf 'fixture archive for %s\n' "$target" >"$valid_assets/clun-$target.tar.gz"
done
(cd "$valid_assets" && sha256sum \
  clun-linux-x64.tar.gz \
  clun-linux-arm64.tar.gz \
  clun-darwin-x64.tar.gz \
  clun-darwin-arm64.tar.gz >checksums.txt)
sh "$repo_root/scripts/release/verify-assets.sh" "$valid_assets" >/dev/null

expect_asset_failure() {
  fixture=$1
  label=$2
  if sh "$repo_root/scripts/release/verify-assets.sh" "$fixture" >/dev/null 2>&1; then
    printf 'release-workflow fixture: %s unexpectedly passed\n' "$label" >&2
    exit 1
  fi
}

extra_assets=$work_dir/extra-assets
cp -R "$valid_assets" "$extra_assets"
printf 'unexpected\n' >"$extra_assets/source.zip"
expect_asset_failure "$extra_assets" 'a sixth asset'

wrong_name_assets=$work_dir/wrong-name-assets
cp -R "$valid_assets" "$wrong_name_assets"
mv "$wrong_name_assets/clun-darwin-arm64.tar.gz" "$wrong_name_assets/clun-windows-x64.zip"
expect_asset_failure "$wrong_name_assets" 'wrong five-asset set'

duplicate_checksum_assets=$work_dir/duplicate-checksum-assets
cp -R "$valid_assets" "$duplicate_checksum_assets"
sed -n '1p;1p;2p;3p' "$valid_assets/checksums.txt" \
  >"$duplicate_checksum_assets/checksums.txt"
expect_asset_failure "$duplicate_checksum_assets" 'duplicate checksum names'

malformed_checksum_assets=$work_dir/malformed-checksum-assets
cp -R "$valid_assets" "$malformed_checksum_assets"
awk 'NR == 1 { print "g" substr($1, 2) "  " $2; next } { print }' \
  "$valid_assets/checksums.txt" >"$malformed_checksum_assets/checksums.txt"
expect_asset_failure "$malformed_checksum_assets" 'same-length non-hex checksum'

path_traversal_assets=$work_dir/path-traversal-assets
cp -R "$valid_assets" "$path_traversal_assets"
awk 'NR == 1 { print $1 "  ../" $2; next } { print }' \
  "$valid_assets/checksums.txt" >"$path_traversal_assets/checksums.txt"
expect_asset_failure "$path_traversal_assets" 'checksum path traversal'

uppercase_checksum_assets=$work_dir/uppercase-checksum-assets
cp -R "$valid_assets" "$uppercase_checksum_assets"
awk 'NR == 1 { print "A" substr($1, 2) "  " $2; next } { print }' \
  "$valid_assets/checksums.txt" >"$uppercase_checksum_assets/checksums.txt"
expect_asset_failure "$uppercase_checksum_assets" 'uppercase checksum digit'

short_checksum_assets=$work_dir/short-checksum-assets
cp -R "$valid_assets" "$short_checksum_assets"
awk 'NR == 1 { print substr($1, 2) "  " $2; next } { print }' \
  "$valid_assets/checksums.txt" >"$short_checksum_assets/checksums.txt"
expect_asset_failure "$short_checksum_assets" 'wrong-length checksum'

extra_field_assets=$work_dir/extra-field-assets
cp -R "$valid_assets" "$extra_field_assets"
awk 'NR == 1 { print $0 " extra"; next } { print }' \
  "$valid_assets/checksums.txt" >"$extra_field_assets/checksums.txt"
expect_asset_failure "$extra_field_assets" 'checksum record with an extra field'

corrupt_assets=$work_dir/corrupt-assets
cp -R "$valid_assets" "$corrupt_assets"
printf 'corruption\n' >>"$corrupt_assets/clun-linux-x64.tar.gz"
expect_asset_failure "$corrupt_assets" 'corrupt archive under strict SHA-256'

release_workflow=$repo_root/.github/workflows/release.yml
[ "$(grep -Fxc '          sh scripts/release/verify-exact-sha-runs.sh "$master_runs" "$tagged_commit"' \
    "$release_workflow")" -eq 1 ] || {
  printf 'release-workflow fixture: claims job does not use the exact-SHA helper once\n' >&2
  exit 1
}
[ "$(grep -Fxc '          sh scripts/release/verify-tagged-master.sh "$tagged_commit" "$master_commit"' \
    "$release_workflow")" -eq 1 ] || {
  printf 'release-workflow fixture: tag must equal the fetched origin/master tip\n' >&2
  exit 1
}
if grep -Fq 'git merge-base --is-ancestor' "$release_workflow"; then
  printf 'release-workflow fixture: ancestor-only tag acceptance remains in the workflow\n' >&2
  exit 1
fi
[ "$(grep -Fc '.id, .name, .path, .head_sha, .head_branch, .event, .status, .conclusion' \
    "$release_workflow")" -eq 1 ] || {
  printf 'release-workflow fixture: workflow run identity/status serialization is incomplete\n' >&2
  exit 1
}
[ "$(grep -Fc 'sh scripts/release/verify-assets.sh' "$release_workflow")" -eq 3 ] || {
  printf 'release-workflow fixture: staged, existing, and fresh assets must all be verified\n' >&2
  exit 1
}
[ "$(grep -Fc 'gh release download "$GITHUB_REF_NAME"' "$release_workflow")" -eq 2 ] || {
  printf 'release-workflow fixture: existing and fresh publication must both redownload assets\n' >&2
  exit 1
}
create_line=$(grep -nF 'gh release create "$GITHUB_REF_NAME"' "$release_workflow" |
  cut -d: -f1)
checksum_line=$(grep -nF 'run: sha256sum clun-*.tar.gz > checksums.txt' "$release_workflow" |
  cut -d: -f1)
staged_verify_line=$(grep -nF 'run: sh scripts/release/verify-assets.sh dist' "$release_workflow" |
  cut -d: -f1)
[ -n "$checksum_line" ] && [ -n "$staged_verify_line" ] && [ -n "$create_line" ] &&
  [ "$checksum_line" -lt "$staged_verify_line" ] && [ "$staged_verify_line" -lt "$create_line" ] || {
  printf 'release-workflow fixture: staged assets are not verified after checksums and before create\n' >&2
  exit 1
}
last_download_line=$(grep -nF 'gh release download "$GITHUB_REF_NAME"' "$release_workflow" |
  tail -n 1 | cut -d: -f1)
last_verify_line=$(grep -nF 'sh scripts/release/verify-assets.sh' "$release_workflow" |
  tail -n 1 | cut -d: -f1)
[ -n "$create_line" ] && [ -n "$last_download_line" ] && [ -n "$last_verify_line" ] &&
  [ "$last_download_line" -gt "$create_line" ] && [ "$last_verify_line" -gt "$last_download_line" ] || {
  printf 'release-workflow fixture: fresh publication is not redownloaded and verified after create\n' >&2
  exit 1
}

printf 'release workflow and downloaded-asset fixtures passed\n'
