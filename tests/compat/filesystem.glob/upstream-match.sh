#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
case_dir=$repo_root/tests/compat/filesystem.glob
source_dir=$case_dir/upstream
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}

[ -x "$clun" ] || {
  printf 'filesystem.glob upstream matcher: %s is missing\n' "$clun" >&2
  exit 2
}

tmp_base=${TMPDIR:-$repo_root/tmp-test}
mkdir -p "$tmp_base"
work=$(mktemp -d "$tmp_base/clun-glob-upstream.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

run_baseline() {
  baseline=$1
  expected=$2
  transformed=$work/$baseline-body.ts
  program=$work/$baseline.ts

  sed \
    -e '/^import /d' \
    -e 's#join(import.meta.dir, "..", "..", "..", "fixtures", "glob", #join(process.env.CLUN_GLOB_UPSTREAM_FIXTURES, #g' \
    -e 's/40_000/40000/g' \
    "$source_dir/$baseline/match.test.ts" > "$transformed"

  {
    sed -n '1,$p' "$case_dir/upstream-match-harness.js"
    sed -n '1,$p' "$transformed"
    sed -n '1,$p' "$case_dir/upstream-match-footer.js"
  } > "$program"

  actual=$(
    cd "$case_dir"
    CLUN_GLOB_UPSTREAM_FIXTURES=$source_dir/fixtures/glob "$clun" "$program"
  )
  [ "$actual" = "$expected" ] || {
    printf 'filesystem.glob upstream matcher: %s mismatch\nexpected: %s\nactual:   %s\n' \
      "$baseline" "$expected" "$actual" >&2
    exit 1
  }
  printf 'filesystem.glob upstream matcher: %s passed (%s)\n' "$baseline" "$actual"
}

run_baseline stable 'upstream-match 24 tests 1471 assertions failures 0'
run_baseline engineering 'upstream-match 26 tests 1483 assertions failures 0'
