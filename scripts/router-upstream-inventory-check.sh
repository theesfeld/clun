#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
case_dir=$repo_root/tests/compat/server.router
upstream=$case_dir/upstream
inventory=$case_dir/upstream-inventory.tsv
TAB=$(printf '\t')

source_path() {
  case $1 in
    filesystem_router) printf 'test/js/bun/util/filesystem_router.test.ts' ;;
    *) printf 'test/js/bun/http/%s.test.ts' "$1" ;;
  esac
}

evidence_path() {
  case $1 in
    filesystem_router) printf 'tests/compat/server.router/filesystem.js' ;;
    *) printf 'tests/compat/server.router/run.sh' ;;
  esac
}

emit_sites() {
  baseline=$1
  commit=$2
  suite=$3
  file=$upstream/$baseline/$suite.test.ts
  source=$(source_path "$suite")
  evidence=$(evidence_path "$suite")

  awk -v FS="$TAB" -v OFS="$TAB" \
    -v baseline="$baseline" -v commit="$commit" -v suite="$suite" \
    -v source="$source" -v evidence="$evidence" '
    function is_todo(line) {
      if (suite != "bun-serve-file") return 0
      if (baseline == "stable")
        return (line >= 297 && line <= 326) || (line >= 397 && line <= 409)
      return (line >= 301 && line <= 330) || (line >= 472 && line <= 484)
    }
    function emit(kind, occurrence, disposition, proof, note) {
      id = baseline "." suite "." kind ".L" NR "." occurrence
      print id, baseline, commit, source, kind, NR, occurrence, disposition, proof, note
    }
    {
      original = $0
      disposition = "aggregate-mapped"
      proof = evidence
      note = "semantic cluster is exercised through shipped Clun fixtures; this row does not claim one-to-one source execution"
      if (is_todo(NR)) {
        disposition = "not-applicable"
        proof = "-"
        note = "upstream todo block or todo case is not executable"
      } else if (original ~ /^[[:space:]]*\/\//) {
        disposition = "not-applicable"
        proof = "-"
        note = "commented upstream site is not executable"
      } else if (suite == "filesystem_router" && NR >= 497 &&
                 ((baseline == "stable" && NR <= 537) ||
                  (baseline == "engineering" && NR <= 539))) {
        proof = "tests/compat/server.router/filesystem-stress.js"
        note = "exact 1000-warmup and 30000-match full-GC RSS gate enforces the upstream non-ASAN 20 MiB limit"
      } else if (suite == "bun-serve-file" &&
                 ((baseline == "stable" && NR >= 445 && NR <= 469) ||
                  (baseline == "engineering" && NR >= 520 && NR <= 546))) {
        note = "exact 5-warmup and 50-request full-GC server RSS gate enforces the upstream non-ASAN 100 MiB delta"
      } else if (suite == "bun-serve-static" && NR >= 106 && NR <= 168) {
        note = "large static responses run 50 measured cycles and enforce the upstream non-ASAN 4092 MiB RSS ceiling"
      } else if (suite == "filesystem_router" && NR == 475) {
        note = "Linux-only raw-filename case is exercised by filesystem-raw-filenames.js; macOS excludes the upstream case"
        proof = "tests/compat/server.router/filesystem-raw-filenames.js"
      } else if (suite == "bun-serve-file" && baseline == "engineering" && NR == 850) {
        disposition = "not-applicable"
        proof = "-"
        note = "pollable FIFO streaming is outside the regular-file router contract; Clun rejects special files fail-closed"
      } else if (suite == "bun-serve-file" && baseline == "engineering" && NR >= 988) {
        disposition = "not-applicable"
        proof = "-"
        note = "Clun parses the complete request body before dispatch and has no shared uWebSockets callback userdata lifetime"
      } else if (suite == "filesystem_router" && baseline == "engineering" && NR >= 755) {
        disposition = "not-applicable"
        proof = "-"
        note = "Bun.build directory-cache interaction belongs to the build API, not FileSystemRouter behavior"
      }

      rest = original
      occurrence = 0
      while (match(rest, /(^|[^[:alnum:]_.])(test|it)([.][[:alpha:]][[:alnum:]_]*)?[[:space:]]*[(]/)) {
        occurrence++
        emit("test", occurrence, disposition, proof, note)
        rest = substr(rest, RSTART + RLENGTH)
      }

      rest = original
      occurrence = 0
      while (match(rest, /expect[[:space:]]*[(]/)) {
        occurrence++
        emit("assertion", occurrence, disposition, proof, note)
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
  ' "$file"
}

generate() {
  printf 'inventory_id\tbaseline\texact_commit\tupstream_source\tkind\tsource_line\toccurrence\tdisposition\tevidence\tnote\n'
  for item in \
    'stable|0d9b296af33f2b851fcbf4df3e9ec89751734ba4' \
    'engineering|c1076ce95effb909bfe9f596919b5dba5567d550'
  do
    baseline=${item%%|*}
    commit=${item#*|}
    emit_sites "$baseline" "$commit" bun-serve-routes
    emit_sites "$baseline" "$commit" bun-serve-static
    emit_sites "$baseline" "$commit" bun-serve-file
    emit_sites "$baseline" "$commit" filesystem_router
  done
}

verify_hashes() {
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$upstream" && sha256sum -c SHA256SUMS >/dev/null)
  elif command -v shasum >/dev/null 2>&1; then
    (cd "$upstream" && shasum -a 256 -c SHA256SUMS >/dev/null)
  else
    printf 'server.router inventory: sha256sum or shasum is required\n' >&2
    exit 2
  fi
}

check_count() {
  baseline=$1
  suite=$2
  kind=$3
  expected=$4
  source=$(source_path "$suite")
  actual=$(awk -F "$TAB" -v b="$baseline" -v s="$source" -v k="$kind" \
    'NR > 1 && $2 == b && $4 == s && $5 == k { n++ } END { print n + 0 }' "$inventory")
  [ "$actual" -eq "$expected" ] || {
    printf 'server.router inventory: %s %s %s expected %s rows, got %s\n' \
      "$baseline" "$suite" "$kind" "$expected" "$actual" >&2
    exit 1
  }
}

check() {
  verify_hashes
  generated=$(mktemp "${TMPDIR:-$repo_root/tmp-test}/clun-router-inventory.XXXXXX")
  trap 'rm -f "$generated"' EXIT HUP INT TERM
  generate > "$generated"
  cmp "$generated" "$inventory" || {
    printf 'server.router inventory: regenerate with scripts/router-upstream-inventory-check.sh --generate\n' >&2
    exit 1
  }

  check_count stable bun-serve-routes test 34
  check_count stable bun-serve-static test 7
  check_count stable bun-serve-file test 51
  check_count stable filesystem_router test 20
  check_count engineering bun-serve-routes test 45
  check_count engineering bun-serve-static test 10
  check_count engineering bun-serve-file test 60
  check_count engineering filesystem_router test 27
  check_count stable bun-serve-routes assertion 91
  check_count stable bun-serve-static assertion 24
  check_count stable bun-serve-file assertion 137
  check_count stable filesystem_router assertion 60
  check_count engineering bun-serve-routes assertion 142
  check_count engineering bun-serve-static assertion 30
  check_count engineering bun-serve-file assertion 157
  check_count engineering filesystem_router assertion 86

  awk -F "$TAB" 'NR > 1 && $8 != "aggregate-mapped" && $8 != "not-applicable" { exit 1 }' \
    "$inventory" || {
      printf 'server.router inventory: invalid disposition\n' >&2
      exit 1
    }
  tail -n +2 "$inventory" | while IFS="$TAB" read -r _ _ _ _ _ _ _ disposition evidence _; do
    if [ "$disposition" = not-applicable ]; then
      [ "$evidence" = - ] || exit 1
    else
      [ -f "$repo_root/$evidence" ] || exit 1
    fi
  done || {
    printf 'server.router inventory: missing or invalid evidence path\n' >&2
    exit 1
  }

  rows=$(awk 'END { print NR - 1 }' "$inventory")
  excluded=$(awk -F "$TAB" 'NR > 1 && $8 == "not-applicable" { n++ } END { print n + 0 }' "$inventory")
  printf 'server.router inventory: %s pinned lexical sites mapped (%s upstream-inactive or cross-feature)\n' \
    "$rows" "$excluded"
}

case ${1:-check} in
  --generate) generate ;;
  check) check ;;
  *) printf 'usage: %s [check|--generate]\n' "$0" >&2; exit 2 ;;
esac
