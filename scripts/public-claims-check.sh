#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

fail() {
  printf 'public-claims-check: %s\n' "$*" >&2
  exit 1
}

require_text() {
  file=$1
  expected=$2
  grep -Fq -- "$expected" "$file" ||
    fail "$file is missing expected text: $expected"
}

version=$(sed -n 's/^(defparameter \*clun-version\* "\([^"]*\)".*/\1/p' src/version.lisp)
[ -n "$version" ] || fail "could not read *clun-version* from src/version.lisp"

scratch_dir=$(mktemp -d "${TMPDIR:-/tmp}/clun-claims.XXXXXX") ||
  fail "could not create a claims-check scratch directory"
trap 'rm -rf "$scratch_dir"' 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
pass_entries="$scratch_dir/pass-entries"
readme_rows="$scratch_dir/readme-rows"
site_rows="$scratch_dir/site-rows"
readme_matrix="$scratch_dir/readme-matrix"
site_matrix="$scratch_dir/site-matrix"

awk '
  /^[[:space:]]*$/ { next }
  /^#/ { next }
  /^[[:space:]]/ { exit 2 }
  /[[:space:]]/ { exit 3 }
  { print }
' tests/conformance/exec-passlist.txt >"$pass_entries" ||
  fail "execution pass-list contains a malformed entry"

LC_ALL=C sort -c "$pass_entries" >/dev/null 2>&1 ||
  fail "execution pass-list is not sorted in C-locale order"
[ -z "$(LC_ALL=C sort "$pass_entries" | uniq -d | sed -n '1p')" ] ||
  fail "execution pass-list contains a duplicate entry"

test262_passes=$(wc -l <"$pass_entries" | tr -d ' ')
[ "$test262_passes" -gt 0 ] || fail "execution pass-list is empty"
header_passes=$(sed -n '2s/^# Regenerate: .*\. \([0-9][0-9]*\) entries\.$/\1/p' \
  tests/conformance/exec-passlist.txt)
[ "$header_passes" = "$test262_passes" ] ||
  fail "execution pass-list header count does not match its canonical entries"

while IFS= read -r entry; do
  case "$entry" in
    built-ins/*) test_path="vendor-data/test262/test/$entry" ;;
    *) test_path="vendor-data/test262/test/language/$entry" ;;
  esac
  case "$entry" in
    *.js) ;;
    *) fail "execution pass-list entry is not a JavaScript test: $entry" ;;
  esac
  case "/$entry/" in
    */../*|*//* ) fail "execution pass-list entry has an unsafe path: $entry" ;;
  esac
  [ -f "$test_path" ] ||
    fail "execution pass-list entry is absent from vendored test262: $entry"
done < "$pass_entries"

pretty_passes=$(awk -v n="$test262_passes" '
  function commas(value, text, length_) {
    text = sprintf("%.0f", value)
    length_ = length(text)
    if (length_ <= 3) return text
    return commas(substr(text, 1, length_ - 3)) "," substr(text, length_ - 2)
  }
  BEGIN { print commas(n) }
')

benchmark_baseline=$(awk '/^\| Phase-24 baseline / { print; exit }' docs/benchmarks.md)
benchmark_latest=$(awk '/^\| m[0-9][0-9]* / { latest = $0 } END { print latest }' docs/benchmarks.md)
[ -n "$benchmark_baseline" ] && [ -n "$benchmark_latest" ] ||
  fail "could not read benchmark baseline and latest milestone"
benchmark_milestone=$(printf '%s\n' "$benchmark_latest" |
  sed -n 's/^| \(m[0-9][0-9]*\) .*/\1/p')
[ -n "$benchmark_milestone" ] || fail "latest benchmark row has no milestone"

metric_value() {
  printf '%s\n' "$1" | awk -F '|' -v column="$2" '
    {
      gsub(/^[[:space:]]+/, "", $column)
      split($column, fields, /[[:space:]]+/)
      print fields[1]
    }
  '
}

benchmark_met=0
benchmark_column=3
while [ "$benchmark_column" -le 5 ]; do
  baseline_value=$(metric_value "$benchmark_baseline" "$benchmark_column")
  current_value=$(metric_value "$benchmark_latest" "$benchmark_column")
  gain=$(awk -v baseline="$baseline_value" -v current="$current_value" \
    'BEGIN { printf "%.2f", baseline / current }')
  require_text site/index.html "$current_value ms"
  require_text site/index.html "${gain}x"
  if awk -v baseline="$baseline_value" -v current="$current_value" \
    'BEGIN { exit !((baseline / current) >= 5) }'; then
    benchmark_met=$((benchmark_met + 1))
  fi
  benchmark_column=$((benchmark_column + 1))
done

phase_exists() {
  grep -F "$1$(printf '\t')" docs/roadmap.tsv >/dev/null 2>&1
}

write_canonical_matrix() {
  kind=$1
  input=$2
  output=$3
  : >"$output"
  while IFS="$(printf '\t')" read -r capability state phase_list marker extra ||
        [ -n "${capability}${state}${phase_list}${marker}${extra}" ]; do
    [ -n "$capability" ] || fail "$kind matrix contains a blank capability row"
    [ -z "$extra" ] || fail "$kind matrix row has unexpected fields: $capability"
    [ -n "$phase_list" ] || fail "$kind matrix has no phase URLs for $capability"
    seen_phases=,
    for phase in $(printf '%s\n' "$phase_list" | tr ',' ' '); do
      case "$phase" in
        *[!0-9]*|'') fail "$kind matrix has an invalid phase URL for $capability" ;;
      esac
      case "$seen_phases" in
        *",$phase,"*) fail "$kind matrix repeats phase $phase for $capability" ;;
      esac
      seen_phases="${seen_phases}${phase},"
      phase_exists "$phase" ||
        fail "$kind matrix references undefined phase $phase for $capability"
    done
    if [ "$kind" = site ]; then
      case "$seen_phases" in
        *",$marker,"*) ;;
        *) fail "site matrix marker phase $marker has no row-local URL for $capability" ;;
      esac
    fi
    printf '%s\t%s\t%s\n' "$capability" "$state" "$phase_list" >>"$output"
  done <"$input"
}

awk -F '[|]' '
  function trim(value) {
    sub(/^[[:space:]]+/, "", value)
    sub(/[[:space:]]+$/, "", value)
    return value
  }
  function occurrences(value, needle, count, offset) {
    while ((offset = index(value, needle)) > 0) {
      count++
      value = substr(value, offset + length(needle))
    }
    return count
  }
  function phase_urls(value, prefix, expected, output, count, offset, rest, phase) {
    while ((offset = index(value, prefix)) > 0) {
      rest = substr(value, offset + length(prefix))
      if (match(rest, /^[0-9]+/) == 0) return ""
      if (substr(rest, RLENGTH + 1, 1) != expected) return ""
      phase = substr(rest, 1, RLENGTH)
      output = output (count ? "," : "") phase
      count++
      value = substr(rest, RLENGTH + 1)
    }
    return output
  }
  function die(message) {
    print "public-claims-check: README matrix: " message > "/dev/stderr"
    failed = 1
    exit 2
  }
  $0 == "## Compatibility roadmap" { section = 1; next }
  section && $0 == "| Capability | Current pre-alpha state | Evidence-backed target |" {
    table = 1
    next
  }
  table && /^\|---/ { next }
  table && /^\|/ {
    capability = trim($2)
    current = trim($3)
    target = trim($4)
    state = current
    sub(/:.*/, "", state)
    state = trim(state)
    if (state !~ /^(Yes|Partial|No)$/) die("invalid state for " capability ": " state)
    if (seen[capability]++) die("duplicate capability: " capability)
    prefix = "label%3Aphase-"
    if (occurrences(target, prefix) < 1) die("expected at least one phase URL for " capability)
    phases = phase_urls(target, prefix, ")")
    if (phases == "") die("malformed phase URL for " capability)
    print capability, state, phases
    rows++
    next
  }
  table { exit }
  END {
    if (!failed && !rows) die("compatibility table was not found")
  }
' OFS="$(printf '\t')" README.md >"$readme_rows" ||
  fail "could not parse the README compatibility matrix"

awk '
  function occurrences(value, needle, count, offset) {
    while ((offset = index(value, needle)) > 0) {
      count++
      value = substr(value, offset + length(needle))
    }
    return count
  }
  function between(value, opening, closing, start, rest, finish) {
    start = index(value, opening)
    if (!start) return ""
    rest = substr(value, start + length(opening))
    finish = index(rest, closing)
    if (!finish) return ""
    return substr(rest, 1, finish - 1)
  }
  function text(value) {
    gsub(/<[^>]*>/, "", value)
    gsub(/&amp;/, "\\&", value)
    gsub(/^[[:space:]]+/, "", value)
    gsub(/[[:space:]]+$/, "", value)
    return value
  }
  function digits_after(value, prefix, rest) {
    rest = substr(value, index(value, prefix) + length(prefix))
    if (match(rest, /^[0-9]+/) == 0) return ""
    if (substr(rest, RLENGTH + 1, 1) != "\"") return ""
    return substr(rest, 1, RLENGTH)
  }
  function phase_urls(value, prefix, expected, output, count, offset, rest, phase) {
    while ((offset = index(value, prefix)) > 0) {
      rest = substr(value, offset + length(prefix))
      if (match(rest, /^[0-9]+/) == 0) return ""
      if (substr(rest, RLENGTH + 1, 1) != expected) return ""
      phase = substr(rest, 1, RLENGTH)
      output = output (count ? "," : "") phase
      count++
      value = substr(rest, RLENGTH + 1)
    }
    return output
  }
  function die(message) {
    print "public-claims-check: site matrix: " message > "/dev/stderr"
    failed = 1
    exit 2
  }
  function process_row(value, heading, capability, cell, marker_prefix, url_prefix,
                       marker, phases, opening, closing, bold, state) {
    opening = "<th scope=\"row\">"
    if (!index(value, opening)) {
      if (index(value, "data-roadmap-phase")) die("phase marker outside a capability row")
      return
    }
    heading = between(value, opening, "</th>")
    capability = text(between(heading, "<strong>", "</strong>"))
    if (capability == "") capability = text(heading)
    if (capability == "") die("capability row has no name")
    if (seen[capability]++) die("duplicate capability: " capability)
    if (occurrences(value, "data-roadmap-phase") != 1)
      die("roadmap marker is not unique within the row for " capability)
    if (occurrences(value, "<td class=\"clun-col\">") != 1)
      die("expected one Clun cell for " capability)
    cell = between(value, "<td class=\"clun-col\">", "</td>")
    marker_prefix = "data-roadmap-phase=\""
    if (occurrences(cell, marker_prefix) != 1)
      die("expected one row-local roadmap marker for " capability)
    marker = digits_after(cell, marker_prefix)
    if (marker == "") die("malformed roadmap marker for " capability)
    url_prefix = "href=\"https://github.com/theesfeld/clun/issues?q=is%3Aissue%20label%3Aphase-"
    if (occurrences(cell, url_prefix) < 1)
      die("expected at least one canonical phase URL for " capability)
    phases = phase_urls(cell, url_prefix, "\"")
    if (phases == "") die("malformed phase URL for " capability)
    bold = substr(cell, index(cell, "<b class=\"state "))
    opening = index(bold, ">")
    closing = index(bold, "</b>")
    if (!opening || closing <= opening) die("missing state for " capability)
    state = text(substr(bold, opening + 1, closing - opening - 1))
    if (state !~ /^(Yes|Partial|No)$/) die("invalid state for " capability ": " state)
    print capability, state, phases, marker
    rows++
  }
  {
    if (!in_row && index($0, "data-roadmap-phase"))
      die("phase marker outside a table row")
    if ($0 ~ /<tr([[:space:]>])/) {
      if (in_row) die("nested table rows")
      in_row = 1
      row = ""
    }
    if (in_row) row = row " " $0
    if (in_row && index($0, "</tr>")) {
      process_row(row)
      in_row = 0
      row = ""
    }
  }
  END {
    if (!failed && in_row) die("unclosed table row")
    if (!failed && !rows) die("compatibility table was not found")
  }
' OFS="$(printf '\t')" site/index.html >"$site_rows" ||
  fail "could not parse the site compatibility matrix"

write_canonical_matrix README "$readme_rows" "$readme_matrix"
write_canonical_matrix site "$site_rows" "$site_matrix"
if ! cmp -s "$readme_matrix" "$site_matrix"; then
  diff -u "$readme_matrix" "$site_matrix" >&2 || :
  fail "README and site capability/state/phase anchors disagree"
fi
capability_rows=$(wc -l <"$site_matrix" | tr -d ' ')

for tag in html head title body header nav main section article div p pre code table \
           thead tbody tr th td a span b strong button i footer dl dt dd ol ul li; do
  openings=$(grep -E -o "<$tag([[:space:]>])" site/index.html | wc -l | tr -d ' ')
  closings=$(grep -E -o "</$tag>" site/index.html | wc -l | tr -d ' ')
  [ "$openings" = "$closings" ] ||
    fail "site/index.html has unbalanced <$tag> elements ($openings open, $closings close)"
done
for tag in html head body main; do
  openings=$(grep -E -o "<$tag([[:space:]>])" site/index.html | wc -l | tr -d ' ')
  [ "$openings" -eq 1 ] ||
    fail "site/index.html must contain exactly one <$tag> element"
done

js_syntax=skipped
if command -v node >/dev/null 2>&1; then
  node --check site/app.js || fail "site/app.js failed Node syntax validation"
  js_syntax=passed
fi

require_text README.md "./build/clun --version   # => clun $version"
require_text README.md "$pretty_passes tests"
require_text site/index.html "href=\"https://github.com/theesfeld/clun/releases/tag/v$version\""
require_text site/index.html "v$version for Linux and macOS"
require_text site/index.html "</span> v$version / pre-alpha</p>"
require_text site/index.html "<span>$version / pre-alpha</span>"
require_text site/index.html "$pretty_passes pass"
require_text site/index.html "github.com/theesfeld/clun/blob/master/PLAN.md"
require_text site/index.html "Phase 25 / milestone ${benchmark_milestone#m}"
require_text site/index.html "$benchmark_met of 3 workloads"
installer_default="requested_version=\${CLUN_VERSION:-v$version}"
[ "$(grep -Fxc "$installer_default" site/install)" -eq 1 ] ||
  fail "site/install default CLUN_VERSION is not v$version"

if [ "${GITHUB_REF_TYPE:-}" = tag ]; then
  [ "${GITHUB_REF_NAME:-}" = "v$version" ] ||
    fail "tag ${GITHUB_REF_NAME:-<unset>} does not match source version v$version"
fi

sh -n site/install
sh scripts/test-installer.sh
sh scripts/roadmap.sh check

printf 'public claim anchors agree: version=%s test262=%s capabilities=%s js-syntax=%s\n' \
  "$version" "$test262_passes" "$capability_rows" "$js_syntax"
