#!/bin/sh

set -eu

# Release tags require exact-master Compatibility (path-filtered) plus CI/Docs/Pages.

if [ "$#" -ne 2 ]; then
  printf 'usage: %s <workflow-runs.tsv> <full-commit-sha>\n' "$0" >&2
  exit 2
fi

runs_tsv=$1
expected_sha=$2

fail() {
  printf 'release-exact-sha-check: %s\n' "$*" >&2
  exit 1
}

[ -f "$runs_tsv" ] || fail "workflow-runs response does not exist: $runs_tsv"
printf '%s\n' "$expected_sha" | LC_ALL=C grep -Eq '^[0-9a-f]{40}$' ||
  fail 'expected commit must be a full lowercase SHA'

LC_ALL=C awk -F '\t' '
  NF != 8 || $1 !~ /^[1-9][0-9]*$/ { bad = 1 }
  seen[$1]++ { duplicate = 1 }
  END { exit (bad || duplicate) ? 1 : 0 }
' "$runs_tsv" ||
  fail 'workflow-runs input must contain unique positive run ids and exactly eight fields per row'

for workflow in CI Documentation Compatibility Pages; do
  case $workflow in
    CI) workflow_path=.github/workflows/ci.yml ;;
    Documentation) workflow_path=.github/workflows/docs.yml ;;
    Compatibility) workflow_path=.github/workflows/compat.yml ;;
    Pages) workflow_path=.github/workflows/pages.yml ;;
  esac

  newest_id=$(LC_ALL=C awk -F '\t' -v path="$workflow_path" '
    $3 == path { print $1 }
  ' "$runs_tsv" | LC_ALL=C sort -n | tail -n 1)
  [ -n "$newest_id" ] ||
    fail "$workflow has no run at exact path $workflow_path"

  LC_ALL=C awk -F '\t' -v id="$newest_id" -v workflow="$workflow" \
    -v path="$workflow_path" -v sha="$expected_sha" '
    $1 == id && $2 == workflow && $3 == path && $4 == sha &&
      $5 == "master" && $6 == "push" && $7 == "completed" &&
      $8 == "success" && NF == 8 { matches++ }
    END { exit matches == 1 ? 0 : 1 }
  ' "$runs_tsv" ||
    fail "$workflow newest run $newest_id is not the exact-path, exact-SHA successful master push"
done

printf 'release-exact-sha-check: CI, Documentation, Compatibility, and Pages passed for %s\n' \
  "$expected_sha"
