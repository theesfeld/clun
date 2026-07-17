#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
case_dir=$repo_root/tests/compat/tooling.shell
upstream=$case_dir/upstream
manifest=$case_dir/upstream-corpus.tsv
coverage=$case_dir/upstream-coverage.tsv
TAB=$(printf '\t')

emit_file() {
  baseline=$1
  commit=$2
  source=$3
  file=$upstream/$baseline/$source

  awk -v FS="$TAB" -v OFS="$TAB" -v baseline="$baseline" \
    -v commit="$commit" -v source="$source" '
    function owner(path, name) {
      if (path ~ /\/commands\//) {
        name = path
        sub(/^.*\/commands\//, "", name)
        sub(/[.]test[.]ts$/, "", name)
        return "builtin:" name
      }
      if (path ~ /brace[.]test[.]ts$/) return "expansion"
      if (path ~ /assignments-in-pipeline/) return "assignments"
      if (path ~ /env[.]positionals/) return "environment"
      if (path ~ /lex[.]test|parse[.]test/) return "parser"
      if (path ~ /pipeline_stack|epipe|blocking-pipe/) return "pipeline"
      if (path ~ /leak|load|hang|fault|sentinel/) return "lifecycle"
      if (path ~ /file-io/) return "io-api"
      if (path ~ /instance|default|shelloutput|throw|lazy|yield|exec/) return "public-api"
      if (path ~ /bunshell/) return "shell-language"
      return "shell-core"
    }
    function emit(kind, occurrence, token, original, id, upstream_state, disposition, note) {
      id = source
      gsub(/[^[:alnum:]]/, "_", id)
      id = baseline "." id ".L" NR "." occurrence "." kind
      upstream_state = "active-or-generated"
      disposition = "pending"
      note = "frozen lexical site; observable equivalent must be executed or explicitly dispositioned"
      if (original ~ /^[[:space:]]*\/\//) {
        upstream_state = "inactive-comment"
        disposition = "not-applicable"
        note = "commented source is not executable at the pinned revision"
      } else if (tolower(token) ~ /todo/) {
        upstream_state = "upstream-todo"
        disposition = "not-applicable"
        note = "site is explicitly todo at the pinned revision"
      }
      print id, baseline, commit, source, NR, occurrence, kind, upstream_state, \
        disposition, "-", owner(source), note
    }
    {
      original = $0
      rest = original
      occurrence = 0
      while (match(rest, /(^|[^[:alnum:]_])(test|it)([.][[:alnum:]_]+)*[[:space:]]*[(]/)) {
        occurrence++
        token = substr(rest, RSTART, RLENGTH)
        emit("test-call", occurrence, token, original)
        rest = substr(rest, RSTART + RLENGTH)
      }

      rest = original
      occurrence = 0
      while (match(rest, /[.]runAsTest(Todo)?[[:space:]]*[(]/)) {
        occurrence++
        token = substr(rest, RSTART, RLENGTH)
        emit("builder-test", occurrence, token, original)
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
  ' "$file"
}

generate_base() {
  printf 'inventory_id\tbaseline\texact_commit\tupstream_source\tsource_line\toccurrence\tsite_kind\tupstream_state\tclun_disposition\tevidence\towner\tnote\n'
  for baseline in engineering stable; do
    case $baseline in
      engineering) commit=c1076ce95effb909bfe9f596919b5dba5567d550 ;;
      stable) commit=0d9b296af33f2b851fcbf4df3e9ec89751734ba4 ;;
    esac
    find "$upstream/$baseline/test/js/bun/shell" -type f -name '*.test.ts' -print |
      LC_ALL=C sort | while IFS= read -r file; do
        source=${file#"$upstream/$baseline/"}
        emit_file "$baseline" "$commit" "$source"
      done
  done
}

generate() {
  [ -f "$coverage" ] || {
    printf 'shell upstream corpus: missing coverage overlay: %s\n' "$coverage" >&2
    return 1
  }
  base=$(mktemp "${TMPDIR:-$repo_root/tmp-test}/clun-shell-corpus-base.XXXXXX")
  generate_base > "$base"
  status=0
  awk -F "$TAB" -v OFS="$TAB" '
    NR == FNR {
      if (FNR == 1) {
        if ($0 != "inventory_id\tclun_disposition\tevidence\tnote") {
          print "shell upstream corpus: invalid coverage overlay header" > "/dev/stderr"
          invalid = 1
        }
        next
      }
      if ($1 == "" || $2 != "covered" || $3 == "-" || $4 == "" || ($1 in disposition)) {
        print "shell upstream corpus: invalid or duplicate coverage row: " $1 > "/dev/stderr"
        invalid = 1
        next
      }
      disposition[$1] = $2
      evidence[$1] = $3
      note[$1] = $4
      next
    }
    FNR == 1 { print; next }
    {
      if ($1 in disposition) {
        $9 = disposition[$1]
        $10 = evidence[$1]
        $12 = note[$1]
        seen[$1] = 1
      }
      print
    }
    END {
      for (id in disposition) {
        if (!(id in seen)) {
          print "shell upstream corpus: coverage ID is absent from frozen corpus: " id > "/dev/stderr"
          invalid = 1
        }
      }
      exit invalid
    }
  ' "$coverage" "$base" || status=$?
  rm -f "$base"
  return "$status"
}

count_baseline() {
  baseline=$1
  expected=$2
  actual=$(awk -F "$TAB" -v baseline="$baseline" \
    'NR > 1 && $2 == baseline { count++ } END { print count + 0 }' "$manifest")
  [ "$actual" -eq "$expected" ] || {
    printf 'shell upstream corpus: %s expected %s sites, got %s\n' \
      "$baseline" "$expected" "$actual" >&2
    exit 1
  }
}

check() {
  sh "$repo_root/scripts/shell-upstream-inventory-check.sh"
  generated=$(mktemp "${TMPDIR:-$repo_root/tmp-test}/clun-shell-corpus.XXXXXX")
  trap 'rm -f "$generated"' EXIT HUP INT TERM
  generate > "$generated"
  cmp "$generated" "$manifest" || {
    printf 'shell upstream corpus: regenerate upstream-corpus.tsv with --generate\n' >&2
    exit 1
  }

  count_baseline stable 787
  count_baseline engineering 843
  awk -F "$TAB" -v root="$repo_root" '
    NR == 1 { next }
    $9 != "pending" && $9 != "covered" && $9 != "not-applicable" { exit 1 }
    $9 == "covered" && ($10 == "-" || system("test -f \"" root "/" $10 "\"") != 0) { exit 1 }
    $9 != "covered" && $10 != "-" { exit 1 }
    $9 == "not-applicable" && $8 != "upstream-todo" && $8 != "inactive-comment" { exit 1 }
    { if (seen[$1]++) exit 1 }
  ' "$manifest" || {
    printf 'shell upstream corpus: invalid disposition, evidence, or duplicate ID\n' >&2
    exit 1
  }

  pending=$(awk -F "$TAB" 'NR > 1 && $9 == "pending" { count++ } END { print count + 0 }' "$manifest")
  covered=$(awk -F "$TAB" 'NR > 1 && $9 == "covered" { count++ } END { print count + 0 }' "$manifest")
  inactive=$(awk -F "$TAB" 'NR > 1 && $9 == "not-applicable" { count++ } END { print count + 0 }' "$manifest")
  printf 'tooling.shell corpus: 1630 pinned sites = %s covered / %s pending / %s upstream-inactive\n' \
    "$covered" "$pending" "$inactive"
}

yes_gate() {
  check
  pending=$(awk -F "$TAB" 'NR > 1 && $9 == "pending" { count++ } END { print count + 0 }' "$manifest")
  [ "$pending" -eq 0 ] || {
    printf 'shell upstream corpus: Yes blocked by %s pending pinned sites\n' "$pending" >&2
    exit 1
  }
  awk -F "$TAB" '
    NR > 1 && $1 == "tooling.shell" {
      targets++
      if ($3 != "supported") bad++
    }
    END { exit !(targets == 4 && bad == 0) }
  ' "$repo_root/compat/platforms.tsv" || {
    printf 'shell upstream corpus: Yes requires supported receipts on all four targets\n' >&2
    exit 1
  }
  printf 'tooling.shell Yes gate: complete pinned corpus and four target receipts verified\n'
}

case ${1:-check} in
  --generate) generate ;;
  check) check ;;
  --yes) yes_gate ;;
  *) printf 'usage: %s [check|--generate|--yes]\n' "$0" >&2; exit 2 ;;
esac
