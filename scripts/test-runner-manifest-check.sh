#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
manifest="$repo_root/tests/compat/tooling.test-runner/upstream/bun-c1076ce95effb909bfe9f596919b5dba5567d550/manifest.tsv"

fail() {
  printf 'test-runner-manifest-check: %s\n' "$*" >&2
  exit 1
}

[ -f "$manifest" ] || fail "missing $manifest"

TAB=$(printf '\t')
header="category${TAB}source_path${TAB}sha256${TAB}bun_pass${TAB}bun_fail${TAB}bun_skip${TAB}clun_pass${TAB}clun_fail${TAB}clun_skip"
[ "$(sed -n '1p' "$manifest")" = "$header" ] || fail 'unexpected manifest header'

awk -F '\t' '
  NR == 1 { next }
  NF != 9 { printf "line %d has %d fields\n", NR, NF > "/dev/stderr"; bad = 1; next }
  $1 !~ /^(cli-output|concurrency|core|custom-matchers|expect|lifecycle|mocks|parameterization|setup|snapshots|timers)$/ {
    printf "line %d has invalid category %s\n", NR, $1 > "/dev/stderr"; bad = 1
  }
  $2 !~ /^test\/js\/bun\/test\// || $2 ~ /\/parallel\// {
    printf "line %d has out-of-scope path %s\n", NR, $2 > "/dev/stderr"; bad = 1
  }
  length($3) != 64 || $3 !~ /^[0-9a-f]+$/ {
    printf "line %d has invalid sha256\n", NR > "/dev/stderr"; bad = 1
  }
  seen[$2]++ { printf "duplicate path %s\n", $2 > "/dev/stderr"; bad = 1 }
  previous != "" && $2 <= previous {
    printf "paths are not strictly sorted at %s\n", $2 > "/dev/stderr"; bad = 1
  }
  {
    previous = $2
    for (i = 4; i <= 9; i++) {
      if ($i != "pending" && $i !~ /^[0-9]+$/) {
        printf "line %d has invalid result field %s\n", NR, $i > "/dev/stderr"; bad = 1
      }
    }
    for (i = 4; i <= 9; i += 3) {
      pending = ($i == "pending") + ($(i + 1) == "pending") + ($(i + 2) == "pending")
      if (pending != 0 && pending != 3) {
        printf "line %d mixes pending and numeric results\n", NR > "/dev/stderr"; bad = 1
      }
    }
    count++
  }
  END {
    if (count != 52) {
      printf "expected 52 roots, found %d\n", count > "/dev/stderr"; bad = 1
    }
    exit bad
  }
' "$manifest" || fail 'manifest structure failed validation'

if [ -n "${CLUN_BUN_SOURCE:-}" ]; then
  [ -d "$CLUN_BUN_SOURCE/.git" ] || fail 'CLUN_BUN_SOURCE is not a Git checkout'
  actual_commit=$(git -C "$CLUN_BUN_SOURCE" rev-parse HEAD)
  [ "$actual_commit" = c1076ce95effb909bfe9f596919b5dba5567d550 ] ||
    fail "expected Bun c1076ce95effb909bfe9f596919b5dba5567d550, got $actual_commit"

  tail -n +2 "$manifest" | while IFS="$TAB" read -r category source digest rest; do
    : "$category" "$rest"
    [ -f "$CLUN_BUN_SOURCE/$source" ] || fail "missing pinned source $source"
    actual=$(sha256sum "$CLUN_BUN_SOURCE/$source" | awk '{print $1}')
    [ "$actual" = "$digest" ] || fail "digest mismatch for $source"
  done
fi

printf 'test-runner-manifest-check: 52 immutable Bun result roots validated\n'
