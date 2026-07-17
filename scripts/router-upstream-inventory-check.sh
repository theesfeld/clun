#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
case_dir=$repo_root/tests/compat/server.router
upstream=$case_dir/upstream
inventory=$case_dir/upstream-inventory.tsv
contracts=$case_dir/upstream-contracts.tsv
TAB=$(printf '\t')

source_path() {
  case $1 in
    filesystem_router) printf 'test/js/bun/util/filesystem_router.test.ts' ;;
    *) printf 'test/js/bun/http/%s.test.ts' "$1" ;;
  esac
}

emit_sites() {
  baseline=$1
  commit=$2
  suite=$3
  file=$upstream/$baseline/$suite.test.ts
  source=$(source_path "$suite")
  awk -v FS="$TAB" -v OFS="$TAB" \
    -v baseline="$baseline" -v commit="$commit" -v suite="$suite" \
    -v source="$source" '
    NR == FNR {
      if (FNR == 1) next
      contract = $1
      disposition = $2
      evidence = $3
      note = $8
      count = split($7, sites, ",")
      for (item = 1; item <= count; item++) {
        site = sites[item]
        mapped_disposition[site] = disposition
        mapped_contract[site] = contract
        mapped_evidence[site] = evidence
        mapped_note[site] = note
      }
      next
    }
    function emit(kind, occurrence, disposition, contract, evidence, note) {
      id = baseline "." suite "." kind ".L" source_line "." occurrence
      print id, baseline, commit, source, kind, source_line, occurrence, \
        disposition, contract, evidence, note
    }
    {
      source_line = FNR
      original = $0
      rest = original
      occurrence = 0
      while (match(rest, /(^|[^[:alnum:]_.])(test|it)([.][[:alpha:]][[:alnum:]_]*)?[[:space:]]*[(]/)) {
        occurrence++
        id = baseline "." suite ".test.L" source_line "." occurrence
        if (id in mapped_disposition) {
          current_disposition = mapped_disposition[id]
          current_contract = mapped_contract[id]
          current_evidence = mapped_evidence[id]
          current_note = mapped_note[id]
        } else {
          current_disposition = "unmapped"
          current_contract = "-"
          current_evidence = "-"
          current_note = "no explicit upstream contract selector"
        }
        emit("test", occurrence, current_disposition, current_contract,
             current_evidence, current_note)
        rest = substr(rest, RSTART + RLENGTH)
      }

      rest = original
      occurrence = 0
      while (match(rest, /expect[[:space:]]*[(]/)) {
        occurrence++
        if (original ~ /^[[:space:]]*\/\//) {
          disposition = "not-applicable"
          contract = "-"
          evidence = "-"
          note = "commented upstream lexical site is not executable"
        } else if (current_disposition == "") {
          disposition = "unmapped"
          contract = "-"
          evidence = "-"
          note = "assertion appears before any explicitly mapped test"
        } else {
          disposition = current_disposition
          contract = current_contract
          evidence = current_evidence
          note = current_note
        }
        emit("assertion", occurrence, disposition, contract, evidence, note)
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
  ' "$contracts" "$file"
}

generate() {
  printf 'inventory_id\tbaseline\texact_commit\tupstream_source\tkind\tsource_line\toccurrence\tdisposition\tcontract_id\tevidence\tnote\n'
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

verify_manifest() {
  awk -v FS="$TAB" '
    FNR == 1 {
      if ($0 != "contract_id\tdisposition\tevidence\tassertion_anchor\trunner\texecution_anchor\ttest_sites\tnote")
        exit 1
      next
    }
    NF != 8 || $1 == "" || $7 == "" || $8 == "" { exit 1 }
    $1 in contracts { exit 1 }
    {
      contracts[$1] = 1
      if ($2 != "contract-mapped" && $2 != "correctness-improvement" &&
          $2 != "not-applicable") exit 1
      count = split($7, selectors, ",")
      for (item = 1; item <= count; item++) {
        if (selectors[item] == "" || selectors[item] in sites) exit 1
        sites[selectors[item]] = 1
      }
      if ($2 == "not-applicable") {
        if ($3 != "-" || $4 != "-" || $5 != "-" || $6 != "-") exit 1
      } else {
        if ($3 == "-" || $4 == "-" || $5 == "-") exit 1
        anchor_key = $3 SUBSEP $4
        if (anchor_key in anchors) exit 1
        anchors[anchor_key] = $1
      }
    }
  ' "$contracts" || {
    printf 'server.router inventory: invalid or duplicate contract manifest row\n' >&2
    exit 1
  }

  tail -n +2 "$contracts" |
    while IFS="$TAB" read -r contract disposition evidence anchor runner execution sites note; do
      [ "$disposition" = not-applicable ] && continue
      [ -f "$repo_root/$evidence" ] && [ -f "$repo_root/$runner" ] || exit 1
      grep -F "$runner" "$repo_root/Makefile" >/dev/null || exit 1
      anchor_count=$(grep -F -c "$anchor" "$repo_root/$evidence" || true)
      [ "$anchor_count" -eq 1 ] || exit 1
      case $anchor in
        contract:*)
          grep -F "$anchor" "$repo_root/$evidence" |
            grep -E 'assert_body|assert\(|grep |^\[|\}\);' >/dev/null || exit 1
          ;;
      esac
      if [ "$evidence" = "$runner" ]; then
        [ "$execution" = - ] || exit 1
      else
        [ "$execution" != - ] || exit 1
        grep -F "$execution" "$repo_root/$runner" >/dev/null || exit 1
      fi
    done || {
      printf 'server.router inventory: contract evidence or execution anchor is not concrete\n' >&2
      exit 1
    }
}

verify_test_selectors() {
  awk -v FS="$TAB" '
    NR == FNR {
      if (FNR > 1 && $5 == "test") inventory[$1]++
      next
    }
    FNR == 1 { next }
    {
      count = split($7, selectors, ",")
      for (item = 1; item <= count; item++) manifest[selectors[item]]++
    }
    END {
      failed = 0
      inventory_count = 0
      manifest_count = 0
      for (site in inventory) {
        inventory_count++
        if (inventory[site] != 1 || manifest[site] != 1) {
          print "unmapped or duplicate upstream test: " site > "/dev/stderr"
          failed = 1
        }
      }
      for (site in manifest) {
        manifest_count++
        if (manifest[site] != 1 || inventory[site] != 1) {
          print "stale or duplicate contract selector: " site > "/dev/stderr"
          failed = 1
        }
      }
      if (inventory_count != 254 || manifest_count != 254) failed = 1
      exit failed
    }
  ' "$inventory" "$contracts" || {
    printf 'server.router inventory: exact per-test contract coverage failed\n' >&2
    exit 1
  }
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
  verify_manifest
  generated=$(mktemp "${TMPDIR:-$repo_root/tmp-test}/clun-router-inventory.XXXXXX")
  trap 'rm -f "$generated"' EXIT HUP INT TERM
  generate > "$generated"
  cmp "$generated" "$inventory" || {
    printf 'server.router inventory: regenerate with scripts/router-upstream-inventory-check.sh --generate\n' >&2
    exit 1
  }
  verify_test_selectors

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

  awk -F "$TAB" 'NR > 1 && $8 != "contract-mapped" &&
    $8 != "correctness-improvement" && $8 != "not-applicable" { exit 1 }' \
    "$inventory" || {
      printf 'server.router inventory: invalid disposition\n' >&2
      exit 1
    }
  tail -n +2 "$inventory" | while IFS="$TAB" read -r _ _ _ _ _ _ _ disposition contract evidence _; do
    if [ "$disposition" = not-applicable ]; then
      [ "$evidence" = - ] || exit 1
    else
      [ "$contract" != - ] && [ -f "$repo_root/$evidence" ] || exit 1
    fi
  done || {
    printf 'server.router inventory: missing or invalid evidence path\n' >&2
    exit 1
  }

  rows=$(awk 'END { print NR - 1 }' "$inventory")
  excluded=$(awk -F "$TAB" 'NR > 1 && $8 == "not-applicable" { n++ } END { print n + 0 }' "$inventory")
  tests=$(awk -F "$TAB" 'NR > 1 && $5 == "test" { n++ } END { print n + 0 }' "$inventory")
  contract_count=$(awk -F "$TAB" 'NR > 1 && $2 != "not-applicable" { n++ } END { print n + 0 }' "$contracts")
  improvements=$(awk -F "$TAB" 'NR > 1 && $5 == "test" && $8 == "correctness-improvement" { n++ } END { print n + 0 }' "$inventory")
  printf 'server.router inventory: %s pinned lexical sites; %s tests mapped to %s executable contracts (%s inactive/cross-feature, %s correctness improvements)\n' \
    "$rows" "$tests" "$contract_count" "$excluded" "$improvements"
}

case ${1:-check} in
  --generate) generate ;;
  check) check ;;
  *) printf 'usage: %s [check|--generate]\n' "$0" >&2; exit 2 ;;
esac
