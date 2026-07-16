#!/bin/sh

set -eu

tool_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
repo_root=${CLUN_COMPAT_ROOT:-$tool_root}
TAB=$(printf '\t')
export LC_ALL=C

fail() {
  printf 'compat: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: %s validate|generate|check|run [feature-id|all]|canonical\n' "$0" >&2
  exit 2
}

required_files='docs/roadmap.tsv
STATE.md
compat/baselines.tsv
compat/features.tsv
compat/evidence.tsv
compat/platforms.tsv
compat/references.tsv
compat/release.tsv
compat/upstream-assets.tsv
compat/benchmarks/workloads.tsv
compat/benchmarks/metrics.tsv
src/version.lisp
clun.asd
site/install
README.md
site/index.html
docs/releases/current.md'

require_inputs() {
  printf '%s\n' "$required_files" | while IFS= read -r path; do
    [ -f "$repo_root/$path" ] || fail "required input is missing: $path"
  done
}

source_version() {
  versions=$(sed -n 's/^(defparameter \*clun-version\* "\([^"]*\)".*/\1/p' \
    "$repo_root/src/version.lisp")
  [ "$(printf '%s\n' "$versions" | awk 'NF { n++ } END { print n + 0 }')" -eq 1 ] ||
    fail 'src/version.lisp must contain exactly one *clun-version*'
  printf '%s\n' "$versions"
}

asdf_version() {
  versions=$(sed -n 's/^[[:space:]]*:version "\([^"]*\)".*/\1/p' "$repo_root/clun.asd")
  [ "$(printf '%s\n' "$versions" | awk 'NF { n++ } END { print n + 0 }')" -eq 1 ] ||
    fail 'clun.asd must contain exactly one :version'
  printf '%s\n' "$versions"
}

installer_version() {
  # shellcheck disable=SC2016 # Match the literal parameter-expansion syntax in the installer.
  versions=$(sed -n 's/^requested_version=${CLUN_VERSION:-v\([^}]*\)}$/\1/p' "$repo_root/site/install")
  [ "$(printf '%s\n' "$versions" | awk 'NF { n++ } END { print n + 0 }')" -eq 1 ] ||
    fail 'site/install must contain exactly one default CLUN_VERSION'
  printf '%s\n' "$versions"
}

sha256_file() {
  path=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$path" | awk '{print $NF}'
  else
    fail 'sha256sum, shasum, or openssl is required'
  fi
}

check_repo_path() {
  path=$1
  label=$2
  case "$path" in
    -) return 0 ;;
    ''|/*|../*|*/../*|*/..|*//*|*"$TAB"*) fail "$label has an unsafe path: $path" ;;
  esac
  [ -f "$repo_root/$path" ] || fail "$label path does not exist: $path"
}

check_declared_path() {
  path=$1
  label=$2
  case "$path" in
    -) return 0 ;;
    ''|/*|../*|*/../*|*/..|*//*|*"$TAB"*) fail "$label has an unsafe path: $path" ;;
  esac
}

validate_paths_and_hashes() {
  tail -n +2 "$repo_root/compat/evidence.tsv" |
    while IFS="$TAB" read -r evidence_id _feature _kind command executable fixture expected _targets _assertion; do
      [ -n "$evidence_id" ] || fail 'blank evidence row'
      if [ "$command" = clun-fixture ]; then
        check_declared_path "$executable" "$evidence_id executable"
        check_repo_path "$fixture" "$evidence_id fixture"
        check_repo_path "$expected" "$evidence_id expected"
      elif [ "$command" = checked-script ]; then
        check_declared_path "$executable" "$evidence_id executable"
        check_repo_path "$fixture" "$evidence_id script"
        [ "$expected" = - ] || fail "$evidence_id checked script must use - expected path"
      else
        [ "$executable" = - ] || check_declared_path "$executable" "$evidence_id executable"
        [ "$fixture" = - ] || check_repo_path "$fixture" "$evidence_id fixture"
        [ "$expected" = - ] || check_repo_path "$expected" "$evidence_id expected"
      fi
    done

  tail -n +2 "$repo_root/compat/benchmarks/workloads.tsv" |
    while IFS="$TAB" read -r workload_id _scope _phase fixture fixture_sha runner runner_sha \
      _mode _iterations _warmups _repetitions _signal _immutable; do
      [ "$fixture" = - ] || check_repo_path "$fixture" "$workload_id fixture"
      check_repo_path "$runner" "$workload_id runner"
      if [ "$fixture" != - ]; then
        actual=$(sha256_file "$repo_root/$fixture")
        [ "$actual" = "$fixture_sha" ] ||
          fail "$workload_id fixture digest drift: expected $fixture_sha, got $actual"
      fi
      actual=$(sha256_file "$repo_root/$runner")
      [ "$actual" = "$runner_sha" ] ||
        fail "$workload_id runner digest drift: expected $runner_sha, got $actual"
    done
}

validate_active_state() {
  release_phase=$(awk -F "$TAB" 'NR == 2 { print $8 }' "$repo_root/compat/release.tsv")
  release_issue=$(awk -F "$TAB" 'NR == 2 { print $9 }' "$repo_root/compat/release.tsv")
  state_phases=$(sed -n 's/^## Current phase: \*\*\([0-9][0-9]*\) .*/\1/p' "$repo_root/STATE.md")
  state_issues=$(sed -n 's|^\*\*Canonical issue:\*\* https://github.com/theesfeld/clun/issues/\([0-9][0-9]*\)$|\1|p' \
    "$repo_root/STATE.md")
  [ "$(printf '%s\n' "$state_phases" | awk 'NF { n++ } END { print n + 0 }')" -eq 1 ] ||
    fail 'STATE.md must contain exactly one parseable current phase'
  [ "$(printf '%s\n' "$state_issues" | awk 'NF { n++ } END { print n + 0 }')" -eq 1 ] ||
    fail 'STATE.md must contain exactly one parseable canonical issue'
  [ "$state_phases" = "$release_phase" ] ||
    fail "STATE.md current phase $state_phases disagrees with release ledger phase $release_phase"
  [ "$state_issues" = "$release_issue" ] ||
    fail "STATE.md canonical issue #$state_issues disagrees with release ledger issue #$release_issue"
}

validate() {
  require_inputs
  version=$(source_version)
  asdf=$(asdf_version)
  installer=$(installer_version)
  awk -v FS="$TAB" -v source_version="$version" -v asdf_version="$asdf" \
    -v installer_version="$installer" -f "$tool_root/scripts/compat-validate.awk" \
    "$repo_root/docs/roadmap.tsv" \
    "$repo_root/compat/baselines.tsv" \
    "$repo_root/compat/features.tsv" \
    "$repo_root/compat/evidence.tsv" \
    "$repo_root/compat/platforms.tsv" \
    "$repo_root/compat/references.tsv" \
    "$repo_root/compat/release.tsv" \
    "$repo_root/compat/upstream-assets.tsv" \
    "$repo_root/compat/benchmarks/workloads.tsv" \
    "$repo_root/compat/benchmarks/metrics.tsv"
  validate_paths_and_hashes
  validate_active_state
  if grep -Eiq '(faster|better|stronger)[[:space:]]+than[[:space:]]+(Bun|Node(\.js)?|Deno)' \
      "$repo_root/README.md" "$repo_root/site/index.html" "$repo_root/docs/releases/current.md"; then
    fail 'public documents contain an unqualified cross-runtime superlative'
  fi
}

render() {
  format=$1
  output=$2
  awk -v FS="$TAB" -v format="$format" -f "$tool_root/scripts/compat-render.awk" \
    "$repo_root/docs/roadmap.tsv" \
    "$repo_root/compat/baselines.tsv" \
    "$repo_root/compat/release.tsv" \
    "$repo_root/compat/features.tsv" > "$output"
}

replace_block() {
  file=$1
  name=$2
  content=$3
  output=$4
  begin="<!-- clun-generated:$name:begin -->"
  end="<!-- clun-generated:$name:end -->"
  awk -v begin="$begin" -v end="$end" -v content="$content" '
    $0 == begin {
      begins++
      if (inside) bad = 1
      print
      while ((getline line < content) > 0) print line
      close(content)
      inside = 1
      next
    }
    $0 == end {
      ends++
      if (!inside) bad = 1
      inside = 0
      print
      next
    }
    !inside { print }
    END {
      if (begins != 1 || ends != 1 || inside || bad) exit 4
    }
  ' "$file" > "$output" || fail "$file has invalid $name markers"
}

render_all() {
  destination=$1
  mkdir -p "$destination/site" "$destination/docs/releases"

  render readme-release "$destination/readme-release"
  render readme-release-summary "$destination/readme-release-summary"
  render readme-compat "$destination/readme-compat"
  replace_block "$repo_root/README.md" release "$destination/readme-release" \
    "$destination/README.release"
  replace_block "$destination/README.release" compatibility "$destination/readme-compat" \
    "$destination/README.compatibility"
  replace_block "$destination/README.compatibility" release-summary \
    "$destination/readme-release-summary" "$destination/README.md"

  render site-release "$destination/site-release"
  render site-version "$destination/site-version"
  render site-phase-status "$destination/site-phase-status"
  render site-release-links "$destination/site-release-links"
  render site-compat-intro "$destination/site-compat-intro"
  render site-compat "$destination/site-compat"
  replace_block "$repo_root/site/index.html" release "$destination/site-release" \
    "$destination/site/index.release"
  replace_block "$destination/site/index.release" compatibility "$destination/site-compat" \
    "$destination/site/index.compatibility"
  replace_block "$destination/site/index.compatibility" compatibility-intro \
    "$destination/site-compat-intro" "$destination/site/index.compatibility-intro"
  replace_block "$destination/site/index.compatibility-intro" version "$destination/site-version" \
    "$destination/site/index.version"
  replace_block "$destination/site/index.version" phase-status "$destination/site-phase-status" \
    "$destination/site/index.phase-status"
  replace_block "$destination/site/index.phase-status" release-links "$destination/site-release-links" \
    "$destination/site/index.html"
  rm -f "$destination/README.release" "$destination/README.compatibility" \
    "$destination/site/index.release" "$destination/site/index.compatibility" \
    "$destination/site/index.compatibility-intro" \
    "$destination/site/index.version" "$destination/site/index.phase-status"

  render release-notes "$destination/release-notes"
  replace_block "$repo_root/docs/releases/current.md" release-notes "$destination/release-notes" \
    "$destination/docs/releases/current.md"
  render canonical "$destination/canonical.tsv"
}

generate() {
  validate
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/clun-docs-generate.XXXXXX") ||
    fail 'could not create generation scratch directory'
  trap 'rm -rf "$scratch"' 0 HUP INT TERM
  render_all "$scratch"
  cp "$scratch/README.md" "$repo_root/README.md"
  cp "$scratch/site/index.html" "$repo_root/site/index.html"
  cp "$scratch/docs/releases/current.md" "$repo_root/docs/releases/current.md"
  printf 'compat: generated README.md, site/index.html, and docs/releases/current.md\n'
}

check_docs() {
  validate
  first=$(mktemp -d "${TMPDIR:-/tmp}/clun-docs-check.XXXXXX") ||
    fail 'could not create first documentation scratch directory'
  second=$(mktemp -d "${TMPDIR:-/tmp}/clun-docs-check.XXXXXX") ||
    fail 'could not create second documentation scratch directory'
  trap 'rm -rf "$first" "$second"' 0 HUP INT TERM
  render_all "$first"
  render_all "$second"
  for path in README.md site/index.html docs/releases/current.md canonical.tsv; do
    cmp -s "$first/$path" "$second/$path" || fail "second render changed $path"
  done
  for path in README.md site/index.html docs/releases/current.md; do
    if ! cmp -s "$repo_root/$path" "$first/$path"; then
      diff -u "$repo_root/$path" "$first/$path" >&2 || :
      fail "$path has generated-document drift; run make docs-generate"
    fi
  done
  printf 'compat: generated documents are byte-idempotent and match the canonical ledger\n'
}

run_fixture() {
  evidence_id=$1
  executable=$2
  fixture=$3
  expected=$4
  work=$5

  fixture_dir=$(dirname -- "$repo_root/$fixture")
  fixture_name=$(basename -- "$fixture")
  expected_full="$repo_root/$expected"
  expected_base=${expected_full%.*}
  argv_file=$expected_base.argv
  exit_file=$expected_base.exit
  err_file=$expected_base.err
  expected_exit=0
  [ ! -f "$exit_file" ] || expected_exit=$(sed -n '1p' "$exit_file")

  set --
  if [ -f "$argv_file" ]; then
    while IFS= read -r argument || [ -n "$argument" ]; do
      [ -z "$argument" ] || set -- "$@" "$argument"
    done < "$argv_file"
  else
    set -- "$fixture_name"
  fi

  stdout="$work/$evidence_id.stdout"
  stderr="$work/$evidence_id.stderr"
  status=0
  (cd "$fixture_dir" && env CI=0 "$repo_root/$executable" "$@") \
    >"$stdout" 2>"$stderr" || status=$?
  [ "$status" -eq "$expected_exit" ] ||
    fail "$evidence_id exit mismatch: expected $expected_exit, got $status"
  cmp -s "$expected_full" "$stdout" || {
    diff -u "$expected_full" "$stdout" >&2 || :
    fail "$evidence_id stdout mismatch"
  }
  if [ -f "$err_file" ]; then
    cmp -s "$err_file" "$stderr" || {
      diff -u "$err_file" "$stderr" >&2 || :
      fail "$evidence_id stderr mismatch"
    }
  elif [ -s "$stderr" ]; then
    cat "$stderr" >&2 || :
    fail "$evidence_id wrote unexpected stderr"
  fi
  printf '  (pass) %s\n' "$evidence_id"
}

run_checked_script() {
  evidence_id=$1
  executable=$2
  fixture=$3
  work=$4
  stdout="$work/$evidence_id.stdout"
  stderr="$work/$evidence_id.stderr"
  if (cd "$repo_root" && \
      CLUN_COMPAT_EXECUTABLE="$repo_root/$executable" \
      TMPDIR="${TMPDIR:-/tmp}" sh "$repo_root/$fixture") \
      >"$stdout" 2>"$stderr"; then
    printf '  (pass) %s\n' "$evidence_id"
  else
    cat "$stdout" >&2 || :
    cat "$stderr" >&2 || :
    fail "$evidence_id checked script failed"
  fi
}

run_evidence() {
  selected=${1:-all}
  target=${CLUN_COMPAT_TARGET:-}
  validate
  case "$target" in
    ''|darwin-arm64|darwin-x64|linux-arm64|linux-x64) ;;
    *) fail "invalid CLUN_COMPAT_TARGET: $target" ;;
  esac
  if [ "$selected" != all ]; then
    awk -F "$TAB" -v id="$selected" 'NR > 1 && $1 == id { found = 1 } END { exit !found }' \
      "$repo_root/compat/features.tsv" || fail "unknown feature ID: $selected"
  fi
  work="$repo_root/tmp-test/compat/local"
  rm -rf "$work"
  mkdir -p "$work"
  selected_rows="$work/evidence.tsv"
  awk -F "$TAB" -v OFS="$TAB" -v selected="$selected" -v target="$target" '
    NR == 1 { next }
    selected != "all" && $2 != selected { next }
    target == "" || $4 == "static" || ("," $8 ",") ~ ("," target ",") { print }
  ' \
    "$repo_root/compat/evidence.tsv" > "$selected_rows"
  [ -s "$selected_rows" ] || fail "feature $selected has no registered evidence"

  expected_version=$(source_version)
  executables="$work/executables.txt"
  awk -F "$TAB" '$5 != "-" { print $5 }' "$selected_rows" | sort -u > "$executables"
  while IFS= read -r executable; do
    [ -x "$repo_root/$executable" ] || fail "registered executable is not executable: $executable"
    reported=$("$repo_root/$executable" --version 2>/dev/null || :)
    [ "$reported" = "clun $expected_version" ] ||
      fail "$executable version mismatch: expected clun $expected_version, got ${reported:-<empty>}"
  done < "$executables"
  passed=0
  traced=0
  while IFS="$TAB" read -r evidence_id _feature _kind command executable fixture expected \
    _targets _assertion; do
    case "$command" in
      clun-fixture)
        run_fixture "$evidence_id" "$executable" "$fixture" "$expected" "$work"
        passed=$((passed + 1))
        ;;
      checked-script)
        run_checked_script "$evidence_id" "$executable" "$fixture" "$work"
        passed=$((passed + 1))
        ;;
      static)
        printf '  (trace) %s\n' "$evidence_id"
        traced=$((traced + 1))
        ;;
      *) fail "unsupported evidence command: $command" ;;
    esac
  done < "$selected_rows"
  printf 'compat: %s executable evidence records passed and %s static records traced for %s\n' \
    "$passed" "$traced" "$selected"
}

command=${1:-}
case "$command" in
  validate) [ "$#" -eq 1 ] || usage; validate ;;
  generate) [ "$#" -eq 1 ] || usage; generate ;;
  check) [ "$#" -eq 1 ] || usage; check_docs ;;
  run) [ "$#" -le 2 ] || usage; run_evidence "${2:-all}" ;;
  canonical)
    [ "$#" -eq 1 ] || usage
    validate
    render canonical /dev/stdout
    ;;
  *) usage ;;
esac
