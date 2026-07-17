#!/bin/sh

set -eu

fixture_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$fixture_dir/../../../../.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
upstream=$fixture_dir/yaml-test-suite.upstream.test.ts
fixture=$fixture_dir/yaml-test-suite.clun.test.ts
baseline=$fixture_dir/baseline.tsv
work=$(mktemp -d "${TMPDIR:-$repo_root/tmp-test}/clun-yaml402.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{ print $1 }'
  else
    printf 'yaml-test-suite: sha256sum or shasum is required\n' >&2
    exit 2
  fi
}

require_digest() {
  path=$1
  expected=$2
  actual=$(sha256_file "$path")
  if [ "$actual" != "$expected" ]; then
    printf 'yaml-test-suite: digest mismatch for %s\nexpected %s\nactual   %s\n' \
      "$path" "$expected" "$actual" >&2
    exit 1
  fi
}

[ -x "$clun" ] || {
  printf 'yaml-test-suite: executable is missing: %s\n' "$clun" >&2
  exit 2
}

require_digest "$upstream" a83e700fe60bad508af2781dbf73bfb3bb87ef41c57993dfee98bae619ae0a53
require_digest "$fixture_dir/LICENSE.bun.md" 95d580cdb603fc08a95c971770f5f5c2b34dbfdceb8f05f809afc684a9edffe4

sed \
  -e '/^import { YAML } from "bun";$/d' \
  -e '/^import { expect, test } from "bun:test";$/d' \
  -e 's/YAML\.parse/Clun.YAML.parse/g' \
  "$upstream" > "$work/derived.test.ts"
if ! cmp -s "$fixture" "$work/derived.test.ts"; then
  printf 'yaml-test-suite: committed Clun fixture is not the deterministic upstream translation\n' >&2
  diff -u "$fixture" "$work/derived.test.ts" >&2 || :
  exit 1
fi

awk 'match($0, /^test\("yaml-test-suite\/[^"]+"/) {
       line = substr($0, RSTART, RLENGTH)
       sub(/^test\("yaml-test-suite\//, "", line)
       sub(/"$/, "", line)
       print line
     }' "$upstream" > "$work/source-cases.txt"
tail -n +2 "$baseline" | cut -f 1 > "$work/baseline-cases.txt"
if ! cmp -s "$work/source-cases.txt" "$work/baseline-cases.txt"; then
  printf 'yaml-test-suite: baseline case IDs differ from the pinned source\n' >&2
  diff -u "$work/source-cases.txt" "$work/baseline-cases.txt" >&2 || :
  exit 1
fi

case_count=$(wc -l < "$work/source-cases.txt" | tr -d ' ')
[ "$case_count" -eq 402 ] || {
  printf 'yaml-test-suite: expected 402 pinned cases, found %s\n' "$case_count" >&2
  exit 1
}

if TMPDIR=${TMPDIR:-$repo_root/tmp-test} "$clun" test "$fixture" > "$work/runner.out" 2>&1; then
  runner_status=0
else
  runner_status=$?
fi
[ "$runner_status" -le 1 ] || {
  cat "$work/runner.out" >&2
  printf 'yaml-test-suite: runner exited unexpectedly with status %s\n' "$runner_status" >&2
  exit 1
}

awk 'BEGIN { print "case_id\tstatus" }
     /^\(pass\) yaml-test-suite\// {
       line = $0
       sub(/^\(pass\) yaml-test-suite\//, "", line)
       print line "\tpass"
     }
     /^\(fail\) yaml-test-suite\// {
       line = $0
       sub(/^\(fail\) yaml-test-suite\//, "", line)
       print line "\tfail"
     }' "$work/runner.out" > "$work/actual.tsv"

if ! cmp -s "$baseline" "$work/actual.tsv"; then
  printf 'yaml-test-suite: shipped parser classifications differ from baseline\n' >&2
  diff -u "$baseline" "$work/actual.tsv" >&2 || :
  exit 1
fi

expected_pass=$(awk -F '\t' 'NR > 1 && $2 == "pass" { count++ } END { print count + 0 }' "$baseline")
expected_fail=$(awk -F '\t' 'NR > 1 && $2 == "fail" { count++ } END { print count + 0 }' "$baseline")
[ $((expected_pass + expected_fail)) -eq 402 ] || {
  printf 'yaml-test-suite: baseline does not classify exactly 402 cases\n' >&2
  exit 1
}

if [ "$expected_fail" -eq 0 ]; then
  [ "$runner_status" -eq 0 ] || {
    printf 'yaml-test-suite: all cases passed but runner status was %s\n' "$runner_status" >&2
    exit 1
  }
elif [ "$runner_status" -ne 1 ]; then
  printf 'yaml-test-suite: failing cases require runner status 1, got %s\n' "$runner_status" >&2
  exit 1
fi

grep -F "Ran 402 tests across 1 file." "$work/runner.out" >/dev/null || {
  printf 'yaml-test-suite: runner did not report the complete 402-case corpus\n' >&2
  exit 1
}

printf 'yaml-test-suite: %s pass / %s fail / 402 total (Bun c1076ce95e)\n' \
  "$expected_pass" "$expected_fail"

if [ "${CLUN_YAML_REQUIRE_ALL:-0}" = 1 ] && [ "$expected_fail" -ne 0 ]; then
  printf 'yaml-test-suite: full parity requires 402 pass / 0 fail\n' >&2
  exit 1
fi
