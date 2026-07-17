#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
case_dir=$repo_root/tests/compat/tooling.shell
upstream=$case_dir/upstream
manifest=$case_dir/upstream-files.tsv
TAB=$(printf '\t')

generate() {
  printf 'baseline\texact_commit\tupstream_path\trole\tsha256\n'
  awk '
    function role(path) {
      if (path == "COMMIT") return "metadata"
      if (path == "LICENSE.md") return "license"
      if (path == "docs/runtime/shell.mdx") return "documentation"
      if (path == "packages/bun-types/shell.d.ts") return "types"
      if (path ~ /^test\/js\/bun\/shell\/.*[.]test[.]ts$/) return "test"
      if (path ~ /^test\/js\/bun\/shell\//) return "test-support"
      if (path ~ /^src\//) return "source"
      return "unknown"
    }
    {
      hash = $1
      full = $2
      baseline = full
      sub(/\/.*/, "", baseline)
      path = full
      sub(/^[^/]+\//, "", path)
      commit = baseline == "stable" \
        ? "0d9b296af33f2b851fcbf4df3e9ec89751734ba4" \
        : "c1076ce95effb909bfe9f596919b5dba5567d550"
      print baseline "\t" commit "\t" path "\t" role(path) "\t" hash
    }
  ' "$upstream/SHA256SUMS"
}

verify_hashes() {
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$upstream" && sha256sum -c SHA256SUMS >/dev/null)
  elif command -v shasum >/dev/null 2>&1; then
    (cd "$upstream" && shasum -a 256 -c SHA256SUMS >/dev/null)
  else
    printf 'shell upstream inventory: sha256sum or shasum is required\n' >&2
    exit 2
  fi
}

count() {
  baseline=$1
  role=$2
  expected=$3
  actual=$(awk -F "$TAB" -v baseline="$baseline" -v role="$role" '
    NR > 1 && $1 == baseline && (role == "*" || $4 == role) { count++ }
    END { print count + 0 }
  ' "$manifest")
  [ "$actual" -eq "$expected" ] || {
    printf 'shell upstream inventory: %s %s expected %s files, got %s\n' \
      "$baseline" "$role" "$expected" "$actual" >&2
    exit 1
  }
}

check() {
  verify_hashes
  generated=$(mktemp "${TMPDIR:-$repo_root/tmp-test}/clun-shell-files.XXXXXX")
  trap 'rm -f "$generated"' EXIT HUP INT TERM
  generate > "$generated"
  cmp "$generated" "$manifest" || {
    printf 'shell upstream inventory: regenerate upstream-files.tsv with --generate\n' >&2
    exit 1
  }

  [ "$(sed -n '1p' "$upstream/stable/COMMIT")" = \
      0d9b296af33f2b851fcbf4df3e9ec89751734ba4 ] || exit 1
  [ "$(sed -n '1p' "$upstream/engineering/COMMIT")" = \
      c1076ce95effb909bfe9f596919b5dba5567d550 ] || exit 1

  count stable '*' 102
  count stable test 38
  count stable test-support 11
  count stable source 49
  count stable documentation 1
  count stable types 1
  count stable license 1
  count stable metadata 1
  count engineering '*' 109
  count engineering test 40
  count engineering test-support 11
  count engineering source 54
  count engineering documentation 1
  count engineering types 1
  count engineering license 1
  count engineering metadata 1

  awk -F "$TAB" '
    NR == 1 { next }
    $1 != "stable" && $1 != "engineering" { exit 1 }
    $4 == "unknown" { exit 1 }
    $3 == "" || $3 ~ /^\// || $3 ~ /(^|\/)\.\.($|\/)/ { exit 1 }
    length($5) != 64 || $5 !~ /^[0-9a-f]+$/ { exit 1 }
    { key = $1 "\t" $3; if (seen[key]++) exit 1 }
  ' "$manifest" || {
    printf 'shell upstream inventory: malformed or duplicate manifest row\n' >&2
    exit 1
  }

  rows=$(awk 'END { print NR - 1 }' "$manifest")
  printf 'tooling.shell source inventory: %s exact files verified across two pinned Bun baselines\n' "$rows"
}

case ${1:-check} in
  --generate) generate ;;
  check) check ;;
  *) printf 'usage: %s [check|--generate]\n' "$0" >&2; exit 2 ;;
esac
