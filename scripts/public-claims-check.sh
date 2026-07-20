#!/bin/sh
# shellcheck disable=SC2016 # Contract anchors intentionally match literal shell/Markdown text.

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

# Compatibility/version blocks are generated from compat/*.tsv. Keep this
# check first so later claim parsing never accepts hand-edited matrix prose.
sh scripts/compat.sh check

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

reject_text() {
  file=$1
  rejected=$2
  if grep -Fq -- "$rejected" "$file"; then
    fail "$file contains stale text: $rejected"
  fi
}

versions=$(sed -n 's/^(defparameter \*clun-version\* "\([^"]*\)".*/\1/p' src/version.lisp)
version_count=$(printf '%s\n' "$versions" | awk 'NF { count++ } END { print count + 0 }')
[ "$version_count" -eq 1 ] ||
  fail "src/version.lisp must contain exactly one nonempty *clun-version*"
version=$(printf '%s\n' "$versions" | sed -n '1p')

semver_identifier='(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
semver_pattern="^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-${semver_identifier}(\\.${semver_identifier})*)?(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?$"
printf '%s\n' "$version" | LC_ALL=C grep -Eq "$semver_pattern" ||
  fail "src/version.lisp version is not strict SemVer: $version"

asdf_versions=$(sed -n 's/^[[:space:]]*:version "\([^"]*\)".*/\1/p' clun.asd)
asdf_version_count=$(printf '%s\n' "$asdf_versions" | awk 'NF { count++ } END { print count + 0 }')
[ "$asdf_version_count" -eq 1 ] || fail "clun.asd must contain exactly one ASDF :version"
asdf_version=$(printf '%s\n' "$asdf_versions" | sed -n '1p')
version_without_build=${version%%+*}
version_core=${version_without_build%%-*}
[ "$asdf_version" = "$version_core" ] ||
  fail "clun.asd version $asdf_version does not match source SemVer core $version_core"

release_row=$(sed -n '2p' compat/release.tsv)
IFS="$(printf '\t')" read -r release_id release_version release_asdf installer_tag release_tag \
  release_state release_license active_phase active_issue semver_impact previous_version \
  version_source asdf_source installer_source release_commit extra <<EOF
$release_row
EOF
[ -z "${extra:-}" ] && [ -n "${release_id:-}" ] || fail 'compat/release.tsv must contain one complete release row'
[ "$release_version" = "$version" ] || fail "release ledger version $release_version disagrees with source $version"
[ "$release_asdf" = "$asdf_version" ] || fail "release ledger ASDF core disagrees with clun.asd"
[ "$release_tag" = "v$version" ] || fail "release ledger tag disagrees with source version"
[ "$release_license" = GPL-3.0-or-later ] || fail 'release ledger license must be GPL-3.0-or-later'
[ "$version_source:$asdf_source:$installer_source" = 'src/version.lisp:clun.asd:site/install' ] ||
  fail 'release ledger source paths drifted'
case "$release_state" in candidate|published) ;; *) fail "invalid release state: $release_state" ;; esac
if [ "$release_state" = candidate ]; then
  expected_installer_tag="v$previous_version"
else
  expected_installer_tag="v$version"
fi
[ "$installer_tag" = "$expected_installer_tag" ] ||
  fail "release ledger installer default $installer_tag disagrees with $release_state expectation $expected_installer_tag"
case "$active_phase:$active_issue" in *[!0-9:]*|:*|*:|*::* ) fail 'release ledger has invalid phase or issue' ;; esac
case "$semver_impact" in major|minor|patch|none) ;; *) fail 'release ledger has invalid SemVer impact' ;; esac
candidate_tagged=0
if [ "$release_state" = candidate ]; then
  if [ "$release_commit" = pending ]; then
    candidate_tagged=0
  elif printf '%s\n' "$release_commit" | LC_ALL=C grep -Eq '^[0-9a-f]{40}$'; then
    candidate_tagged=1
  else
    fail 'candidate release ledger commit must be pending or a full tagged commit SHA'
  fi
else
  printf '%s\n' "$release_commit" | LC_ALL=C grep -Eq '^[0-9a-f]{40}$' ||
    fail 'published release ledger commit must be a full commit SHA'
fi

TAB=$(printf '\t')
feature_field() {
  feature_id=$1
  column=$2
  awk -F "$TAB" -v feature_id="$feature_id" -v column="$column" '
    NR > 1 && $1 == feature_id { print $column; found++ }
    END { if (found != 1) exit 2 }
  ' compat/features.tsv || fail "expected exactly one feature row for $feature_id"
}

native_addons_state=$(feature_field runtime.native-addons 6)
native_addons_gap=$(feature_field runtime.native-addons 8)
[ "$native_addons_state" = Partial ] ||
  fail 'runtime.native-addons must remain Partial until the actual native ABI and complete corpus gate pass'
case "$native_addons_gap" in
  *'No machine-code .so/.dylib/.node loading or calls'*) ;;
  *) fail 'runtime.native-addons is missing its machine-code ABI gap' ;;
esac
for audited_feature in runtime.native-addons; do
  awk -F "$TAB" -v feature_id="$audited_feature" '
    NR > 1 && $1 == feature_id { found++; if ($3 != "unverified") bad = 1 }
    END { exit !(found == 4 && !bad) }
  ' compat/platforms.tsv ||
    fail "$audited_feature must remain unverified on all four full-capability platform rows"
done

baseline_row() {
  runtime=$1
  channel=$2
  awk -F "$(printf '\t')" -v runtime="$runtime" -v channel="$channel" '
    NR > 1 && $2 == runtime && $4 == channel {
      print $3 "\t" $5 "\t" $7 "\t" $9
      found++
    }
    END { if (found != 1) exit 2 }
  ' compat/baselines.tsv || fail "expected exactly one $runtime/$channel compatibility baseline"
}

human_date() {
  awk -v value="$1" 'BEGIN {
    split("January February March April May June July August September October November December", month)
    month_index = substr(value, 6, 2) + 0
    printf "%s %d, %s\n", month[month_index], substr(value, 9, 2) + 0, substr(value, 1, 4)
  }'
}

bun_public_row=$(baseline_row Bun stable-executable)
IFS="$TAB" read -r bun_version _ bun_checked bun_source <<EOF
$bun_public_row
EOF
bun_engineering_row=$(baseline_row Bun engineering-source)
IFS="$TAB" read -r _ bun_engineering_revision _ bun_engineering_source <<EOF
$bun_engineering_row
EOF
node_row=$(baseline_row Node.js comparison-release)
IFS="$TAB" read -r node_version _ _ node_source <<EOF
$node_row
EOF
deno_row=$(baseline_row Deno comparison-release)
IFS="$TAB" read -r deno_version _ _ deno_source <<EOF
$deno_row
EOF
baseline_date=$(human_date "$bun_checked")
bun_engineering_short=$(printf '%.10s' "$bun_engineering_revision")

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

parse_entries="$scratch_dir/parse-entries"
awk '
  /^[[:space:]]*$/ { next }
  /^#/ { next }
  /^[[:space:]]/ { exit 2 }
  /[[:space:]]/ { exit 3 }
  { print }
' tests/conformance/parse-passlist.txt >"$parse_entries" ||
  fail "parse pass-list contains a malformed entry"
LC_ALL=C sort -c "$parse_entries" >/dev/null 2>&1 ||
  fail "parse pass-list is not sorted in C-locale order"
[ -z "$(LC_ALL=C sort "$parse_entries" | uniq -d | sed -n '1p')" ] ||
  fail "parse pass-list contains a duplicate entry"
parse_frozen=$(wc -l <"$parse_entries" | tr -d ' ')
parse_header=$(sed -n '2s/^# Regenerate: .*\. \([0-9][0-9]*\) entries\.$/\1/p' \
  tests/conformance/parse-passlist.txt)
[ "$parse_header" = "$parse_frozen" ] ||
  fail "parse pass-list header count does not match its canonical entries"

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

report_measure() {
  label=$1
  awk -F '|' -v label="$label" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    trim($2) == label {
      print trim($3)
      found = 1
      exit
    }
    END { if (!found) exit 2 }
  ' docs/conformance/test262-execution.md ||
    fail "could not read $label from the test262 execution report"
}

report_provenance() {
  label=$1
  awk -F '|' -v label="$label" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    trim($2) == label {
      value = trim($3)
      sub(/^`/, "", value)
      sub(/`$/, "", value)
      print value
      found = 1
      exit
    }
    END { if (!found) exit 2 }
  ' docs/conformance/test262-execution.md ||
    fail "could not read $label from the test262 execution report"
}

format_count() {
  awk -v n="$1" '
    function commas(value, text, length_) {
      text = sprintf("%.0f", value)
      length_ = length(text)
      if (length_ <= 3) return text
      return commas(substr(text, 1, length_ - 3)) "," substr(text, length_ - 2)
    }
    BEGIN { print commas(n) }
  '
}

report_total=$(report_measure Total)
report_pass=$(report_measure Pass)
report_fail=$(report_measure Fail)
report_skip=$(report_measure Skip)
report_crash=$(report_measure Crash)
# Backticks are literal Markdown in the generated report labels.
# shellcheck disable=SC2016
report_eligible=$(report_measure 'Eligible (`pass + fail`)')
report_frozen=$(report_measure 'Frozen baseline pass count')
report_delta=$(report_measure 'Current-pass delta from frozen baseline')
# shellcheck disable=SC2016
report_target=$(report_measure '`ceil(90% * eligible)`')
report_lift=$(report_measure 'Required pass lift')
report_source_revision=$(report_provenance source-revision)
report_digest=$(report_provenance classification-ledger-fnv-1a-64)

printf '%s\n' "$report_source_revision" | grep -Eq '^(working-tree@)?[0-9a-f]{40}$' ||
  fail "test262 execution report has an invalid source revision: $report_source_revision"
printf '%s\n' "$report_digest" | grep -Eq '^[0-9A-F]{16}$' ||
  fail "test262 execution report has an invalid FNV-1a-64 digest: $report_digest"
[ "$report_digest" = ECC1719FA1FA8A61 ] ||
  fail "current execution digest is not the frozen ECC1719FA1FA8A61"

for value in "$report_total" "$report_pass" "$report_fail" "$report_skip" \
             "$report_crash" "$report_eligible" "$report_frozen" \
             "$report_target" "$report_lift"; do
  case "$value" in
    ''|*[!0-9]*) fail "test262 execution report contains a non-integer measure: $value" ;;
  esac
done
case "$report_delta" in
  +*) delta_digits=${report_delta#+} ;;
  -*) delta_digits=${report_delta#-} ;;
  *) delta_digits=$report_delta ;;
esac
case "$delta_digits" in
  ''|*[!0-9]*) fail "test262 execution report has an invalid pass delta: $report_delta" ;;
esac

[ "$report_total" -eq $((report_pass + report_fail + report_skip + report_crash)) ] ||
  fail "test262 execution report classifications do not sum to Total"
[ "$report_eligible" -eq $((report_pass + report_fail)) ] ||
  fail "test262 execution report eligible count is not pass + fail"
[ "$report_crash" -eq 0 ] || fail "test262 execution report contains crashes"
[ "$report_frozen" -eq "$test262_passes" ] ||
  fail "test262 execution report frozen baseline disagrees with the pass-list"
[ "$report_delta" -eq $((report_pass - report_frozen)) ] ||
  fail "test262 execution report current-pass delta is inconsistent"
computed_target=$(((report_eligible * 9 + 9) / 10))
[ "$report_target" -eq "$computed_target" ] ||
  fail "test262 execution report 90% target is inconsistent"
computed_lift=$((report_target - report_pass))
[ "$computed_lift" -ge 0 ] || computed_lift=0
[ "$report_lift" -eq "$computed_lift" ] ||
  fail "test262 execution report required lift is inconsistent"
[ "$test262_passes" -eq 26018 ] && [ "$report_total" -eq 40654 ] &&
  [ "$report_pass" -eq 26018 ] && [ "$report_fail" -eq 2145 ] &&
  [ "$report_skip" -eq 12491 ] && [ "$report_crash" -eq 0 ] &&
  [ "$report_eligible" -eq 28163 ] && [ "$report_target" -eq 25347 ] &&
  [ "$report_lift" -eq 0 ] ||
  fail "execution artifacts no longer match the frozen 26,018/28,163 candidate result"

gap_stats="$scratch_dir/gap-stats"
bucket_stats="$scratch_dir/bucket-stats"
: >"$bucket_stats"
LC_ALL=C awk -F '\t' -v buckets="$bucket_stats" '
  function die(message) {
    print "public-claims-check: execution gap snapshot: " message > "/dev/stderr"
    failed = 1
    exit 2
  }
  /^#/ { next }
  !header {
    expected = "path\towner\tphase_owner\twork_bucket\ttopic\tfeatures\tflags\tincludes"
    if ($0 != expected) die("unexpected TSV header")
    header = 1
    next
  }
  {
    if (NF != 8) die("row does not have eight fields: " $1)
    if ($6 == "" || $7 == "" || $8 == "")
      die("metadata fields must use the explicit - sentinel: " $1)
    if (previous != "" && $1 <= previous) die("paths are not strictly sorted: " $1)
    previous = $1
    if ($3 != "phase-25b" && $3 != "phase-37")
      die("unknown phase owner for " $1 ": " $3)
    if ($4 !~ /^(binding-patterns|dynamic-scope-eval|async-iteration|async-generators|generators|classes|binary-data|regexp|iterator-protocol|promises|collections|arrays|objects|functions-arguments|operators-references|primitive-builtins|other-runtime)$/)
      die("unknown work bucket for " $1 ": " $4)
    rows++
    phases[$3]++
    bucket_count[$4]++
  }
  END {
    if (failed) exit 2
    if (!header) die("missing TSV header")
    printf "%d\t%d\t%d\n", rows, phases["phase-25b"], phases["phase-37"]
    for (bucket in bucket_count)
      printf "%s\t%d\n", bucket, bucket_count[bucket] > buckets
  }
' tests/conformance/exec-gaps.tsv >"$gap_stats" ||
  fail "could not validate the execution gap snapshot"

IFS="$(printf '\t')" read -r gap_rows phase25b_rows phase37_rows <"$gap_stats"
[ "$gap_rows" -eq "$report_fail" ] ||
  fail "execution gap snapshot row count disagrees with the report"
[ $((phase25b_rows + phase37_rows)) -eq "$report_fail" ] ||
  fail "execution gap snapshot phase-owner counts do not reconcile"
[ "$phase25b_rows" -eq 1767 ] && [ "$phase37_rows" -eq 378 ] ||
  fail "residual ownership no longer matches the frozen 1,767/378 split"
require_text docs/conformance/test262-execution.md "| \`phase-25b\` | $phase25b_rows |"
require_text docs/conformance/test262-execution.md "| \`phase-37\` | $phase37_rows |"
LC_ALL=C sort -o "$bucket_stats" "$bucket_stats"
while IFS="$(printf '\t')" read -r bucket count; do
  require_text docs/conformance/test262-execution.md "| \`$bucket\` | $count |"
done <"$bucket_stats"

report_rate=$(awk -v pass="$report_pass" -v eligible="$report_eligible" '
  BEGIN {
    scaled = int((pass * 10000) / eligible)
    printf "%d.%02d", int(scaled / 100), scaled % 100
  }
')
report_rate_exact=$(awk -v pass="$report_pass" -v eligible="$report_eligible" \
  'BEGIN { printf "%.6f", (pass * 100) / eligible }')
[ "$report_rate_exact" = 92.383624 ] ||
  fail "current exact pass rate is not the frozen 92.383624%"
require_text docs/conformance/test262-execution.md \
  "| Pass rate | $report_pass / $report_eligible = $report_rate_exact% |"
pretty_report_pass=$(format_count "$report_pass")
pretty_report_fail=$(format_count "$report_fail")
pretty_report_skip=$(format_count "$report_skip")
pretty_report_total=$(format_count "$report_total")
pretty_report_eligible=$(format_count "$report_eligible")
pretty_report_target=$(format_count "$report_target")
pretty_report_lift=$(format_count "$report_lift")
pretty_phase25b_rows=$(format_count "$phase25b_rows")
milestone5_gain=$((report_pass - 25051))
phase25b_entry_gain=$((report_pass - 22643))
pretty_milestone5_gain=$(format_count "$milestone5_gain")
pretty_phase25b_entry_gain=$(format_count "$phase25b_entry_gain")
pretty_phase37_rows=$(format_count "$phase37_rows")

focused_milestone='m6'
focused_stats="$scratch_dir/focused-stats"
LC_ALL=C awk -F '\t' '
  function die(message) {
    print "public-claims-check: Phase 25b m6 manifest: " message > "/dev/stderr"
    failed = 1
    exit 2
  }
  NR == 1 {
    expected = "path\tentry_phase_owner\tentry_work_bucket\tmilestone_owner\troot_cause\tentry_classification\trequired_final"
    if ($0 != expected) die("unexpected TSV header")
    next
  }
  {
    if (NF != 7) die("row does not have seven fields: " $1)
    if ($1 == "") die("row has an empty path")
    if (previous != "" && $1 <= previous) die("paths are not strictly sorted: " $1)
    previous = $1
    if ($2 != "phase-25b" && $2 != "phase-37")
      die("unknown entry phase owner for " $1 ": " $2)
    if ($4 != "m6" && $4 != "m11" && $4 != "phase-37")
      die("unknown milestone owner for " $1 ": " $4)
    if ($7 != "pass" && $7 != "fail")
      die("required_final must be pass or fail for " $1 ": " $7)
    total++
    outcomes[$7]++
    owners[$4, $7]++
    phases[$2]++
  }
  END {
    if (failed) exit 2
    if (NR < 2) die("manifest has no rows")
    printf "%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",
      total, outcomes["pass"] + 0, outcomes["fail"] + 0,
      owners["m6", "pass"] + 0, owners["m6", "fail"] + 0,
      owners["m11", "fail"] + 0, owners["phase-37", "fail"] + 0,
      phases["phase-25b"] + 0, phases["phase-37"] + 0
  }
' tests/conformance/phase-25b-m6.tsv >"$focused_stats" ||
  fail "could not validate the Phase 25b m6 manifest"

IFS="$(printf '\t')" read -r focused_total focused_pass focused_fail \
  focused_owned_pass focused_owned_fail focused_m11 focused_phase37 \
  focused_phase25b_rows focused_phase37_rows <"$focused_stats"
focused_skip=0
focused_timeout=0
focused_crash=0
focused_controls=$((focused_m11 + focused_phase37))
pretty_focused_total=$(format_count "$focused_total")
pretty_focused_pass=$(format_count "$focused_pass")

[ "$focused_total" -eq $((focused_pass + focused_fail + focused_skip + focused_crash)) ] ||
  fail "focused m6 classifications do not sum to the frozen total"
[ "$focused_total" -eq $((focused_phase25b_rows + focused_phase37_rows)) ] ||
  fail "focused m6 phase-owner rows do not sum to the frozen total"
[ "$focused_fail" -eq "$focused_controls" ] ||
  fail "focused m6 control owners do not sum to the failure count"
[ "$focused_total" -eq 509 ] && [ "$focused_pass" -eq 407 ] &&
  [ "$focused_fail" -eq 102 ] && [ "$focused_owned_pass" -eq 407 ] &&
  [ "$focused_owned_fail" -eq 0 ] && [ "$focused_m11" -eq 7 ] &&
  [ "$focused_phase37" -eq 95 ] && [ "$focused_phase25b_rows" -eq 414 ] &&
  [ "$focused_phase37_rows" -eq 95 ] ||
  fail "focused m6 manifest no longer matches its frozen 407-owned-pass/102-control contract"

parse_total=23713
parse_pass=17699
parse_fail=976
parse_skip=5038
parse_crash=0
lisp_pass=19848
lisp_fail=0
lisp_skip=0
[ "$parse_total" -eq $((parse_pass + parse_fail + parse_skip + parse_crash)) ] ||
  fail "recorded m6 parse classifications do not sum to the corpus total"
[ "$parse_frozen" -eq 17512 ] ||
  fail "parse pass-list no longer matches the m6 frozen baseline"
[ "$parse_pass" -ge "$parse_frozen" ] ||
  fail "recorded m6 parse pass count regresses the frozen baseline"
pretty_parse_total=$(format_count "$parse_total")
pretty_parse_pass=$(format_count "$parse_pass")
pretty_parse_fail=$(format_count "$parse_fail")
pretty_parse_skip=$(format_count "$parse_skip")
pretty_parse_frozen=$(format_count "$parse_frozen")
pretty_lisp_pass=$(format_count "$lisp_pass")

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

# Keep metric integrity against docs/benchmarks.md only (no landing-page bar chart).
benchmark_met=0
benchmark_column=3
while [ "$benchmark_column" -le 5 ]; do
  baseline_value=$(metric_value "$benchmark_baseline" "$benchmark_column")
  current_value=$(metric_value "$benchmark_latest" "$benchmark_column")
  gain=$(awk -v baseline="$baseline_value" -v current="$current_value" \
    'BEGIN { printf "%.2f", baseline / current }')
  require_text docs/benchmarks.md "$current_value ms"
  require_text docs/benchmarks.md "${gain}×"
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

active_issue_url="https://github.com/theesfeld/clun/issues/$active_issue"
require_text README.md "[Phase $active_phase issue #$active_issue]($active_issue_url)"
require_text site/index.html "href=\"$active_issue_url\""

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
require_text tests/lisp/smoke.lisp "(is string= \"$version\" clun::*clun-version*)"
require_text docs/versioning.md "Phase $active_phase"
require_text docs/versioning.md "\`$version\` / \`v$version\`"
require_text docs/versioning.md "impact is \`$semver_impact\`"
require_text README.md "$pretty_passes tests"
require_text README.md "$pretty_report_total-row off-mode execution ledger"
require_text README.md "$pretty_report_pass passes and $pretty_report_fail gaps across $pretty_report_eligible eligible tests"
require_text README.md "($report_rate%), with $pretty_report_skip skips and zero crashes"

release_url="https://github.com/theesfeld/clun/releases/tag/v$version"
previous_release_url="https://github.com/theesfeld/clun/releases/tag/v$previous_version"
readme_candidate_marker="\`$version\` release candidate"
site_candidate_marker="v$version release candidate / pre-alpha"
readme_candidate=0
site_candidate=0
grep -Fq -- "$readme_candidate_marker" README.md && readme_candidate=1
grep -Fq -- "$site_candidate_marker" site/index.html && site_candidate=1
[ "$readme_candidate" -eq "$site_candidate" ] ||
  fail "README and site disagree about whether v$version is a release candidate"

if [ "$release_state" = candidate ]; then
  [ "$readme_candidate" -eq 1 ] || fail "release ledger says candidate but generated documents do not"
  require_text README.md "The current source is the \`$version\` release candidate"
  if [ "$candidate_tagged" -eq 1 ]; then
    require_text README.md "Its annotated [\`v$version\`](https://github.com/theesfeld/clun/tree/v$version) points to commit \`$release_commit\`, but no GitHub Release or release assets were published."
    reject_text README.md "immutable tag and assets are not published yet"
  else
    require_text README.md "immutable tag and assets are not published yet"
  fi
  require_text README.md "The last published prerelease remains"
  require_text README.md "[Phase $active_phase]($active_issue_url) is in progress."
  require_text README.md "[\`v$previous_version\`]($previous_release_url)"
  reject_text README.md "$release_url"

  if [ "$candidate_tagged" -eq 1 ]; then
    require_text site/index.html "<a href=\"$active_issue_url\">"
    require_text site/index.html '<span>Tag only / no Release</span>'
    require_text site/index.html 'The annotated candidate tag exists, but its GitHub Release and assets do not.'
    require_text site/index.html 'Tag-only recovery remains in'
    require_text site/index.html "the canonical Phase $active_phase record"
  else
    require_text site/index.html "<a href=\"$active_issue_url\">"
    require_text site/index.html "<span>In development</span>"
  fi
  require_text site/index.html "Phase $active_phase is active:"
  if [ "$candidate_tagged" -eq 1 ]; then
    require_text site/index.html '>Current status</a>'
    require_text site/index.html '>Canonical phase record</a>'
  else
    require_text site/index.html ">Current status</a>"
  fi
  require_text site/index.html "v$version / Phase $active_phase"
  require_text site/index.html "<a href=\"$previous_release_url\">v$previous_version release</a>"
  require_text site/index.html "v$version release candidate / pre-alpha</p>"
  require_text site/index.html "<span>$version candidate / pre-alpha</span>"
  reject_text site/index.html "$release_url"
else
  [ "$readme_candidate" -eq 0 ] || fail "release ledger says published but generated documents say candidate"
  require_text README.md "$release_url"
  require_text README.md "[Phase $active_phase]($active_issue_url) tracks the published prerelease and remaining phase work."
  reject_text README.md "release candidate"
  reject_text README.md "[Phase $active_phase]($active_issue_url) is in progress."
  reject_text README.md "[Phase $active_phase]($active_issue_url) is complete."

  require_text site/index.html "href=\"$release_url\""
  require_text site/index.html "<span>Available now</span>"
  require_text site/index.html "Phase $active_phase has a published prerelease:"
  require_text site/index.html "Consult the live Issue for remaining work and completion status."
  require_text site/index.html ">Release record</a>"
  reject_text site/index.html "Phase $active_phase is active:"
  reject_text site/index.html "Phase $active_phase is complete:"
  require_text site/index.html "<a href=\"$release_url\">v$version release</a>"
  require_text site/index.html "v$version / pre-alpha</p>"
  require_text site/index.html "<span>$version / pre-alpha</span>"
  reject_text site/index.html "release candidate"
fi
require_text site/index.html 'clun --check-update'
require_text site/index.html 'clun --update'
if [ "$release_state" = candidate ]; then
  require_text README.md "While the hosted boundary remains \`v$previous_version\`, that command only reinstalls \`v$previous_version\` and does not"
  require_text site/index.html "Until then, the command only reinstalls <code>v$previous_version</code>."
else
  require_text README.md "The published \`v$version\` boundary includes the built-in updater"
  require_text site/index.html "The hosted command installs verified <code>v$version</code>"
  reject_text README.md "While the hosted boundary remains \`v$previous_version\`"
  reject_text site/index.html "Until then, the command only reinstalls <code>v$previous_version</code>."
fi
require_text site/index.html 'Proxy traps and invariants are implemented for the covered paths'
require_text site/index.html 'Snapshot edge formats and cooperative/parallel concurrency are covered; test-watch reruns remain a known gap'
require_text site/index.html 'Streaming request and response bodies; WebSocket + Pub/Sub; no HTTP/2 server'
require_text site/index.html 'Source checkpoints already exist for archive/compression, Markdown and HTML rewriting, Cron, and build APIs.'
reject_text site/index.html 'No Proxy, Intl, or native addons (JSX/TSX is built in)'
reject_text site/index.html 'Exotic snapshot edges, watch, and concurrency'
reject_text site/index.html 'Buffered bodies; WebSocket + Pub/Sub; no HTTP/2'
reject_text site/index.html 'none is implemented or claimed today'
reject_text site/index.html 'Pre-alpha FULL PORT: exceed Bun/npm'
reject_text site/index.html 'FULL PORT of Bun/npm capability'
reject_text README.md 'Proxy remains unsupported.'
reject_text README.md '33 core matchers'
reject_text README.md 'buffered HTTP serving'

require_text site/index.html "$pretty_passes pass"
require_text site/index.html "Full run: $pretty_report_total total = $pretty_report_pass pass / $pretty_report_fail fail / $pretty_report_skip skip / $report_crash crash."
require_text site/index.html "Eligible: $pretty_report_eligible / target: $pretty_report_target pass / remaining lift: $pretty_report_lift."
require_text README.md "focused $focused_milestone slice contains $pretty_focused_total tests: $pretty_focused_pass pass and $focused_fail fail, with zero skips, timeouts, and crashes"
require_text README.md "All $focused_owned_pass milestone-owned rows pass; the $focused_controls deliberate controls remain assigned to m11 ($focused_m11) and Phase 37"
require_text README.md "($focused_phase37), leaving m6 with no owned residual."
require_text README.md "full gap inventory assigns $pretty_phase25b_rows residuals to Phase 25b and"
require_text README.md "$pretty_phase37_rows to Phase 37."
require_text site/index.html "Focused $focused_milestone slice: $pretty_focused_total total / $pretty_focused_pass pass / $focused_fail fail / $focused_skip skip / $focused_timeout timeout / $focused_crash crash."
require_text site/index.html "All $focused_owned_pass owned rows pass; controls: $focused_m11 m11 / $focused_phase37 Phase 37; m6 residual: $focused_owned_fail. Remaining ownership:"
require_text site/index.html "$pretty_phase25b_rows Phase-25b / $pretty_phase37_rows Phase-37 gaps."
require_text README.md "pass list gained $pretty_milestone5_gain tests from milestone 5 and $pretty_phase25b_entry_gain from the Phase 25b entry"
require_text site/index.html "Pass-list gain: +$pretty_milestone5_gain from m5 / +$pretty_phase25b_entry_gain from Phase 25b entry."
require_text README.md "Phase 37 milestone 1 adds 173 more frozen passes without claiming complete modern"
require_text site/index.html "Phase 37 milestone 1 adds"
require_text site/index.html "173 more frozen passes without claiming complete modern ECMAScript parity."
require_text README.md "\`species-constructor.js\`, \`subclass-reject-count.js\`, and \`subclass-resolve-count.js\`"
require_text site/index.html "<code>species-constructor.js</code>, <code>subclass-reject-count.js</code>, and"
require_text site/index.html "<code>subclass-resolve-count.js</code>."
require_text README.md "canonical execution ledger digest is \`$report_digest\`"
require_text site/index.html "Ledger digest: <code>$report_digest</code>."
require_text README.md "off/eager ledgers are byte-identical; eager mode compiled"
require_text README.md "1,030,545 forms, classified 56,018 as ineligible, fell back zero times, and executed zero interpreter"
require_text README.md "fallbacks."
require_text site/index.html "Off/eager ledgers are byte-identical; eager compiled 1,030,545 forms / classified 56,018"
require_text site/index.html "as ineligible / fell back 0 times / executed 0 interpreter fallbacks."
require_text README.md "$pretty_parse_total tests as $pretty_parse_pass pass, $pretty_parse_fail fail, $pretty_parse_skip skip, and zero crash"
require_text README.md "current full Common Lisp suite passes $pretty_lisp_pass assertions with zero failures and zero skips"
require_text site/index.html "Parse gate: $pretty_parse_total total / $pretty_parse_pass pass / $pretty_parse_fail fail / $pretty_parse_skip skip / $parse_crash crash; all $pretty_parse_frozen"
require_text site/index.html "Current full Common Lisp suite: $pretty_lisp_pass assertions / $lisp_fail fail / $lisp_skip skip."
if [ "$report_lift" -gt 0 ]; then
  require_text README.md "the $pretty_report_target-pass target requires $pretty_report_lift additional live"
  reject_text README.md "Phase 25b's 90% target is met"
  require_text site/index.html "<dt>Phase 25b progress</dt><dd>$report_rate% current</dd>"
  reject_text site/index.html "90% target met"
else
  require_text README.md "Phase 25b's 90% target is met"
  reject_text README.md "reaching 90% requires"
  require_text site/index.html "$report_rate% current"
  require_text site/index.html "90% target met"
fi
require_text site/index.html "github.com/theesfeld/clun/blob/master/PLAN.md"
# Engine microbenchmark tables live in docs/benchmarks.md — not a landing-page bar chart.
require_text docs/benchmarks.md "Phase-24 baseline"
require_text docs/benchmarks.md "| $benchmark_milestone "
# Landing page must keep npm + secrets as first-class product copy (honest Partial is fine).
require_text site/index.html "npm package management"
require_text site/index.html "Encrypted secrets storage"
require_text site/index.html "tool-critical"
require_text README.md "Bun $bun_version, Node.js $node_version, and Deno $deno_version"
require_text README.md "$baseline_date"
require_text README.md "$bun_engineering_short"
require_text site/index.html "<span>$node_version / current</span>"
require_text site/index.html "$node_source"
require_text site/index.html "<span>$deno_version / runtime</span>"
require_text site/index.html "$deno_source"
require_text site/index.html "Snapshot checked $baseline_date"
require_text site/index.html "$bun_source"
require_text site/index.html "$bun_engineering_source"
installer_boundary="verified_installer_tag=$installer_tag"
[ "$(grep -Fxc "$installer_boundary" site/install)" -eq 1 ] ||
  fail 'site/install verified default disagrees with the release ledger installer boundary'
# shellcheck disable=SC2016 # Compare the installer's literal parameter expansion.
installer_default='requested_version=${1:-${INSTALL_VERSION:-${CLUN_VERSION:-$verified_installer_tag}}}'
[ "$(grep -Fxc "$installer_default" site/install)" -eq 1 ] ||
  fail 'site/install does not default to its verified boundary with version-pin overrides'
require_text site/install 'bin_dir="$HOME/.local/bin"'
require_text site/install 'https://github.com/$repo/releases/latest'
require_text site/install 'https://api.github.com/repos/$repo/releases?per_page=10'
require_text site/install 'https://github.com/$repo/releases.atom'
require_text site/install "Authorization: Bearer \$token"
require_text site/install 'release_parent="$install_root/releases/$release_version"'
require_text site/install 'release_dir="$release_parent/$target"'
require_text site/install "marker_begin='# >>> clun installer >>>'"
require_text README.md 'installs `clun` into `~/.local/bin`'
require_text README.md 'INSTALL_VERSION='
require_text README.md 'GITHUB_TOKEN` or `GH_TOKEN`'
require_text site/index.html '<code>~/.local/bin/clun</code>'
require_text site/index.html '<code>INSTALL_VERSION</code>'
require_text site/index.html '<code>ADD_PATH=1</code>'

if [ "${GITHUB_REF_TYPE:-}" = tag ]; then
  [ "${GITHUB_REF_NAME:-}" = "v$version" ] ||
    fail "tag ${GITHUB_REF_NAME:-<unset>} does not match source version v$version"
fi

sh -n site/install
sh scripts/test-installer.sh
sh scripts/roadmap.sh check

printf 'public claim anchors agree: version=%s release-state=%s frozen-test262=%s current=%s/%s (%s%%) gaps=%s focused-%s=%s/%s capabilities=%s js-syntax=%s\n' \
  "$version" "$release_state" "$test262_passes" "$report_pass" "$report_eligible" "$report_rate" \
  "$report_fail" "$focused_milestone" "$focused_pass" "$focused_total" "$capability_rows" "$js_syntax"
