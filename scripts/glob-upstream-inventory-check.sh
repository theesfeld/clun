#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
case_dir=$repo_root/tests/compat/filesystem.glob
upstream=$case_dir/upstream
inventory=$case_dir/upstream-inventory.tsv
TAB=$(printf '\t')

emit_sites() {
  baseline=$1
  commit=$2
  suite=$3
  evidence=$4
  file=$upstream/$baseline/$suite.test.ts

  awk -v FS="$TAB" -v OFS="$TAB" \
    -v baseline="$baseline" -v commit="$commit" -v suite="$suite" \
    -v evidence="$evidence" '
    function emit(kind, occurrence, disposition, proof, note) {
      id = baseline "." suite "." kind ".L" NR "." occurrence
      source = "test/js/bun/glob/" suite ".test.ts"
      print id, baseline, commit, source, kind, NR, occurrence, disposition, proof, note
    }
    {
      original = $0
      rest = original
      occurrence = 0
      while (match(rest, /test([.]concurrent)?[[:space:]]*[(]/)) {
        occurrence++
        emit("test", occurrence,
             suite == "match" ? "executed" : "aggregate-mapped", evidence,
             suite == "match" ?
               "executed from exact pinned source through build/clun" :
               "lexical source site is associated with an aggregate suite; this row does not claim one-to-one execution")
        rest = substr(rest, RSTART + RLENGTH)
      }

      rest = original
      occurrence = 0
      while (match(rest, /expect[[:space:]]*[(]/)) {
        occurrence++
        if (original ~ /^[[:space:]]*\/\//) {
          emit("assertion", occurrence, "not-applicable", "-",
               "commented upstream assertion is not executable")
        } else if (suite == "match" &&
                   index(original, "a/c/d/one/two/three.test.ts")) {
          emit("assertion", occurrence, "not-applicable", "-",
               "upstream site calls expect without an assertion matcher")
        } else if (suite == "match" && index(original, "foo\\\\bar") &&
                   index(original, ".toBeTrue()")) {
          emit("assertion", occurrence, "not-applicable", "-",
               "Windows-only separator branch; Phase 30 supports macOS and Linux")
        } else {
          emit("assertion", occurrence,
               suite == "match" ? "executed" : "aggregate-mapped", evidence,
               suite == "match" ?
                 "executed from exact pinned source through build/clun" :
                 "associated with an aggregate suite; this row does not claim one-to-one execution")
        }
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
    emit_sites "$baseline" "$commit" leak tests/compat/filesystem.glob/stress.sh
    emit_sites "$baseline" "$commit" match tests/compat/filesystem.glob/upstream-match.sh
    emit_sites "$baseline" "$commit" path-length tests/compat/filesystem.glob/adversarial.sh
    emit_sites "$baseline" "$commit" proto tests/compat/filesystem.glob/api.js
    emit_sites "$baseline" "$commit" scan tests/compat/filesystem.glob/scan.sh
    emit_sites "$baseline" "$commit" stress tests/compat/filesystem.glob/stress.sh
    printf '%s.support.util\t%s\t%s\ttest/js/bun/glob/util.ts\tsupport\t0\t0\taggregate-mapped\ttests/compat/filesystem.glob/scan.sh\tupstream fixture helper is associated with the hermetic scanner suite; this row does not claim one-to-one execution\n' \
      "$baseline" "$baseline" "$commit"
    printf '%s.support.snapshot\t%s\t%s\ttest/js/bun/glob/__snapshots__/scan.test.ts.snap\tsupport\t0\t0\taggregate-mapped\ttests/compat/filesystem.glob/scan.sh\tupstream snapshot is associated with the scanner suite; this row does not claim one-to-one execution\n' \
      "$baseline" "$baseline" "$commit"
  done

  for fixture in filelist.txt matched-0.txt matched-1.txt matched-2.txt matched-3.txt \
                 matched-4.txt matched-5.txt matched-6.txt matched-7.txt matched-8.txt matched-9.txt
  do
    id=$(printf '%s' "$fixture" | tr '.-' '__')
    printf 'shared.fixture.%s\tstable\t0d9b296af33f2b851fcbf4df3e9ec89751734ba4\ttest/js/fixtures/glob/%s\tsupport\t0\t0\texecuted\ttests/compat/filesystem.glob/upstream-match.sh\tfixture is consumed by the exact pinned matcher source\n' \
      "$id" "$fixture"
  done
}

verify_hashes() {
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$upstream" && sha256sum -c SHA256SUMS >/dev/null)
  elif command -v shasum >/dev/null 2>&1; then
    (cd "$upstream" && shasum -a 256 -c SHA256SUMS >/dev/null)
  else
    printf 'filesystem.glob inventory: sha256sum or shasum is required\n' >&2
    exit 2
  fi
}

check_count() {
  baseline=$1
  suite=$2
  kind=$3
  expected=$4
  actual=$(awk -F "$TAB" -v b="$baseline" -v s="test/js/bun/glob/$suite.test.ts" -v k="$kind" \
    'NR > 1 && $2 == b && $4 == s && $5 == k { n++ } END { print n + 0 }' "$inventory")
  [ "$actual" -eq "$expected" ] || {
    printf 'filesystem.glob inventory: %s %s %s expected %s rows, got %s\n' \
      "$baseline" "$suite" "$kind" "$expected" "$actual" >&2
    exit 1
  }
}

check() {
  verify_hashes
  generated=$(mktemp "${TMPDIR:-$repo_root/tmp-test}/clun-glob-inventory.XXXXXX")
  trap 'rm -f "$generated"' EXIT HUP INT TERM
  generate > "$generated"
  cmp "$generated" "$inventory" || {
    printf 'filesystem.glob inventory: regenerate with scripts/glob-upstream-inventory-check.sh --generate\n' >&2
    exit 1
  }

  check_count stable match assertion 1519
  check_count stable scan assertion 54
  check_count stable proto assertion 4
  check_count stable path-length assertion 14
  check_count stable leak assertion 1
  check_count engineering match assertion 1531
  check_count engineering scan assertion 84
  check_count engineering proto assertion 4
  check_count engineering path-length assertion 18
  check_count engineering leak assertion 1
  check_count stable match test 24
  check_count stable scan test 36
  check_count stable stress test 2
  check_count engineering match test 26
  check_count engineering scan test 48
  check_count engineering stress test 2

  awk -F "$TAB" 'NR > 1 && $8 != "executed" && $8 != "aggregate-mapped" && $8 != "not-applicable" { exit 1 }' \
    "$inventory" || {
      printf 'filesystem.glob inventory: invalid disposition\n' >&2
      exit 1
    }
  tail -n +2 "$inventory" | while IFS="$TAB" read -r _ _ _ _ _ _ _ disposition evidence _; do
    if [ "$disposition" = not-applicable ]; then
      [ "$evidence" = - ] || exit 1
    else
      [ -f "$repo_root/$evidence" ] || exit 1
    fi
  done || {
    printf 'filesystem.glob inventory: missing or invalid evidence path\n' >&2
    exit 1
  }

  rows=$(awk 'END { print NR - 1 }' "$inventory")
  printf 'filesystem.glob inventory: %s pinned lexical sites have explicit coverage dispositions\n' "$rows"
}

case ${1:-check} in
  --generate) generate ;;
  check) check ;;
  *) printf 'usage: %s [check|--generate]\n' "$0" >&2; exit 2 ;;
esac
