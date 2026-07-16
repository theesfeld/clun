#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
compat_tool=$repo_root/scripts/compat.sh
TAB=$(printf '\t')
export LC_ALL=C

fail() {
  printf 'test-compat-tools: %s\n' "$*" >&2
  exit 1
}

scratch=$(mktemp -d "${TMPDIR:-/tmp}/clun-compat-tools.XXXXXX") ||
  fail 'could not create scratch directory'
trap 'rm -rf "$scratch"' 0 HUP INT TERM
mkdir -p "$scratch/tmp"
pristine=$scratch/pristine

copy_input() {
  path=$1
  [ -f "$repo_root/$path" ] || fail "required source input is missing: $path"
  mkdir -p "$pristine/$(dirname -- "$path")"
  cp "$repo_root/$path" "$pristine/$path"
}

copy_hashed_input() {
  path=$1
  [ "$path" = - ] && return 0
  copy_input "$path"
}

create_presence_input() {
  path=$1
  [ "$path" = - ] && return 0
  destination=$pristine/$path
  if [ ! -f "$destination" ]; then
    [ -f "$repo_root/$path" ] || fail "registered evidence path is missing: $path"
    mkdir -p "$(dirname -- "$destination")"
    # Validation needs existence only; avoid copying the large built runtime into every case.
    : > "$destination"
  fi
}

create_generated_presence_input() {
  path=$1
  [ "$path" = - ] && return 0
  destination=$pristine/$path
  if [ ! -f "$destination" ]; then
    mkdir -p "$(dirname -- "$destination")"
    # Executables are build outputs. Validation needs the declared path, not a local build.
    : > "$destination"
  fi
}

for path in \
  docs/roadmap.tsv \
  STATE.md \
  compat/baselines.tsv \
  compat/features.tsv \
  compat/evidence.tsv \
  compat/platforms.tsv \
  compat/references.tsv \
  compat/release.tsv \
  compat/upstream-assets.tsv \
  compat/benchmarks/workloads.tsv \
  compat/benchmarks/metrics.tsv \
  src/version.lisp \
  clun.asd \
  site/install \
  README.md \
  site/index.html \
  docs/releases/current.md; do
  copy_input "$path"
done

awk -F "$TAB" 'NR > 1 { print $5 }' \
  "$repo_root/compat/evidence.tsv" |
  while IFS= read -r path; do
    create_generated_presence_input "$path"
  done

awk -F "$TAB" 'NR > 1 { print $6; print $7 }' \
  "$repo_root/compat/evidence.tsv" |
  while IFS= read -r path; do
    create_presence_input "$path"
  done

awk -F "$TAB" 'NR > 1 { print $4; print $6 }' \
  "$repo_root/compat/benchmarks/workloads.tsv" |
  while IFS= read -r path; do
    copy_hashed_input "$path"
  done

run_compat() {
  candidate_root=$1
  command=$2
  CLUN_COMPAT_ROOT=$candidate_root TMPDIR=$scratch/tmp \
    sh "$compat_tool" "$command"
}

expect_pass() {
  label=$1
  candidate_root=$2
  command=$3
  log=$scratch/$label.log
  if run_compat "$candidate_root" "$command" > "$log" 2>&1; then
    printf '  (pass) %s\n' "$label"
  else
    cat "$log" >&2
    fail "$label unexpectedly failed"
  fi
}

expect_failure() {
  label=$1
  candidate_root=$2
  command=$3
  log=$scratch/$label.log
  if run_compat "$candidate_root" "$command" > "$log" 2>&1; then
    cat "$log" >&2
    fail "$label unexpectedly passed"
  fi
  printf '  (pass) %s rejected deliberate drift\n' "$label"
}

expect_failure_matching() {
  label=$1
  candidate_root=$2
  command=$3
  diagnostic=$4
  log=$scratch/$label.log
  if run_compat "$candidate_root" "$command" > "$log" 2>&1; then
    cat "$log" >&2
    fail "$label unexpectedly passed"
  fi
  if ! grep -F "$diagnostic" "$log" >/dev/null 2>&1; then
    cat "$log" >&2
    fail "$label failed without the expected diagnostic: $diagnostic"
  fi
  printf '  (pass) %s rejected deliberate drift\n' "$label"
}

fresh_case() {
  name=$1
  case_root=$scratch/case-$name
  rm -rf "$case_root"
  cp -R "$pristine" "$case_root"
}

replace_file() {
  file=$1
  output=$file.deliberate-drift
  shift
  "$@" > "$output"
  mv "$output" "$file"
}

mutate_version() {
  file=$1
  replace_file "$file" awk '
    /^\(defparameter \*clun-version\*/ && !changed {
      sub(/"[^"]*"/, "\"0.0.0-deliberate-drift\"")
      changed = 1
    }
    { print }
    END { if (!changed) exit 3 }
  ' "$file"
}

mutate_feature_status() {
  file=$1
  # shellcheck disable=SC2016 # AWK field references must not expand in the shell.
  replace_file "$file" awk -F "$TAB" -v OFS="$TAB" '
    NR > 1 && !changed && $6 == "No" {
      $6 = "Partial"
      if ($8 == "-") $8 = "Deliberate status drift."
      changed = 1
    }
    { print }
    END { if (!changed) exit 3 }
  ' "$file"
}

mutate_owner() {
  file=$1
  column=$2
  # shellcheck disable=SC2016 # AWK field references must not expand in the shell.
  replace_file "$file" awk -F "$TAB" -v OFS="$TAB" -v column="$column" '
    NR == 2 { $column = "deliberate.drift.owner"; changed = 1 }
    { print }
    END { if (!changed) exit 3 }
  ' "$file"
}

remove_reference() {
  file=$1
  reference_id=$2
  # shellcheck disable=SC2016 # AWK field references must not expand in the shell.
  replace_file "$file" awk -F "$TAB" -v reference_id="$reference_id" '
    $1 == reference_id { removed = 1; next }
    { print }
    END { if (!removed) exit 3 }
  ' "$file"
}

mutate_reference_field() {
  file=$1
  reference_id=$2
  column=$3
  value=$4
  # shellcheck disable=SC2016 # AWK field references must not expand in the shell.
  replace_file "$file" awk -F "$TAB" -v OFS="$TAB" -v reference_id="$reference_id" \
    -v column="$column" -v value="$value" '
    $1 == reference_id {
      $column = value
      changed = 1
    }
    { print }
    END { if (!changed) exit 3 }
  ' "$file"
}

mutate_release_previous_version() {
  file=$1
  value=$2
  # shellcheck disable=SC2016 # AWK field references must not expand in the shell.
  replace_file "$file" awk -F "$TAB" -v OFS="$TAB" -v value="$value" '
    NR == 2 { $11 = value; changed = 1 }
    { print }
    END { if (!changed) exit 3 }
  ' "$file"
}

mutate_baseline_revision() {
  file=$1
  baseline_id=$2
  # shellcheck disable=SC2016 # AWK field references must not expand in the shell.
  replace_file "$file" awk -F "$TAB" -v OFS="$TAB" -v baseline_id="$baseline_id" '
    $1 == baseline_id {
      $5 = "0000000000000000000000000000000000000000"
      changed = 1
    }
    { print }
    END { if (!changed) exit 3 }
  ' "$file"
}

rename_baseline_reference() {
  file=$1
  column=$2
  old_id=$3
  new_id=$4
  # shellcheck disable=SC2016 # AWK field references must not expand in the shell.
  replace_file "$file" awk -F "$TAB" -v OFS="$TAB" -v column="$column" \
    -v old_id="$old_id" -v new_id="$new_id" '
    $column == old_id { $column = new_id; changed++ }
    { print }
    END { if (!changed) exit 3 }
  ' "$file"
}

refresh_baseline_row() {
  file=$1
  baseline_id=$2
  version=$3
  revision=$4
  tag=$5
  source_url=$6
  # shellcheck disable=SC2016 # AWK field references must not expand in the shell.
  replace_file "$file" awk -F "$TAB" -v OFS="$TAB" -v baseline_id="$baseline_id" \
    -v version="$version" -v revision="$revision" -v tag="$tag" -v source_url="$source_url" '
    $1 == baseline_id {
      $3 = version
      $5 = revision
      $6 = tag
      $7 = "2027-01-02"
      $9 = source_url
      changed = 1
    }
    { print }
    END { if (!changed) exit 3 }
  ' "$file"
}

mutate_baseline_field() {
  file=$1
  baseline_id=$2
  column=$3
  value=$4
  # shellcheck disable=SC2016 # AWK field references must not expand in the shell.
  replace_file "$file" awk -F "$TAB" -v OFS="$TAB" -v baseline_id="$baseline_id" \
    -v column="$column" -v value="$value" '
    $1 == baseline_id { $column = value; changed = 1 }
    { print }
    END { if (!changed) exit 3 }
  ' "$file"
}

refresh_upstream_asset_tag() {
  file=$1
  old_tag=$2
  new_tag=$3
  # shellcheck disable=SC2016 # AWK field references must not expand in the shell.
  replace_file "$file" awk -F "$TAB" -v OFS="$TAB" -v old_tag="$old_tag" -v new_tag="$new_tag" '
    {
      needle = "/" old_tag "/"
      position = index($5, needle)
      if (position) {
        $5 = substr($5, 1, position) new_tag substr($5, position + length(needle) - 1)
        changed++
      }
      print
    }
    END { if (!changed) exit 3 }
  ' "$file"
}

duplicate_marker() {
  file=$1
  marker=$2
  # shellcheck disable=SC2016 # $0 belongs to AWK.
  replace_file "$file" awk -v marker="$marker" '
    $0 == marker { print; print; changed++; next }
    { print }
    END { if (changed != 1) exit 3 }
  ' "$file"
}

reverse_markers() {
  file=$1
  begin=$2
  end=$3
  # shellcheck disable=SC2016 # $0 belongs to AWK.
  replace_file "$file" awk -v begin="$begin" -v end="$end" '
    $0 == begin { print end; begins++; next }
    $0 == end { print begin; ends++; next }
    { print }
    END { if (begins != 1 || ends != 1) exit 3 }
  ' "$file"
}

remove_marker() {
  file=$1
  marker=$2
  # shellcheck disable=SC2016 # $0 belongs to AWK.
  replace_file "$file" awk -v marker="$marker" '
    $0 == marker { removed++; next }
    { print }
    END { if (removed != 1) exit 3 }
  ' "$file"
}

remove_benchmark_row() {
  file=$1
  replace_file "$file" awk '
    NR == 2 { removed = 1; next }
    { print }
    END { if (!removed) exit 3 }
  ' "$file"
}

move_release_to_phase_28() {
  file=$1
  # shellcheck disable=SC2016 # AWK field references must not expand in the shell.
  replace_file "$file" awk -F "$TAB" -v OFS="$TAB" '
    NR == 2 { $8 = "28"; $9 = "2"; changed = 1 }
    { print }
    END { if (!changed) exit 3 }
  ' "$file"
}

move_state_to_phase_28() {
  file=$1
  replace_file "$file" sed \
    -e 's/^## Current phase: \*\*27 /## Current phase: **28 /' \
    -e 's|^\*\*Canonical issue:\*\* https://github.com/theesfeld/clun/issues/1$|**Canonical issue:** https://github.com/theesfeld/clun/issues/2|' \
    "$file"
}

mutate_evidence_executable() {
  file=$1
  evidence_id=$2
  executable=$3
  # shellcheck disable=SC2016 # AWK field references must not expand in the shell.
  replace_file "$file" awk -F "$TAB" -v OFS="$TAB" -v evidence_id="$evidence_id" \
    -v executable="$executable" '
    $1 == evidence_id { $5 = executable; changed = 1 }
    { print }
    END { if (!changed) exit 3 }
  ' "$file"
}

publish_release() {
  file=$1
  # shellcheck disable=SC2016 # AWK field references must not expand in the shell.
  replace_file "$file" awk -F "$TAB" -v OFS="$TAB" '
    NR == 2 {
      $6 = "published"
      $15 = "0123456789abcdef0123456789abcdef01234567"
      changed = 1
    }
    { print }
    END { if (!changed) exit 3 }
  ' "$file"
}

promote_feature_to_yes() {
  file=$1
  feature_id=$2
  # shellcheck disable=SC2016 # AWK field references must not expand in the shell.
  replace_file "$file" awk -F "$TAB" -v OFS="$TAB" -v feature_id="$feature_id" '
    NR > 1 && $1 == feature_id {
      $6 = "Yes"
      $8 = "-"
      changed = 1
    }
    { print }
    END { if (!changed) exit 3 }
  ' "$file"
}

support_feature_on_all_targets() {
  file=$1
  feature_id=$2
  evidence_ids=$3
  # shellcheck disable=SC2016 # AWK field references must not expand in the shell.
  replace_file "$file" awk -F "$TAB" -v OFS="$TAB" -v feature_id="$feature_id" \
    -v evidence_ids="$evidence_ids" '
    NR > 1 && $1 == feature_id {
      $3 = "supported"
      $4 = evidence_ids
      changed++
    }
    { print }
    END { if (changed != 4) exit 3 }
  ' "$file"
}

mutate_evidence_scope() {
  file=$1
  evidence_id=$2
  platform_scope=$3
  # shellcheck disable=SC2016 # AWK field references must not expand in the shell.
  replace_file "$file" awk -F "$TAB" -v OFS="$TAB" -v evidence_id="$evidence_id" \
    -v platform_scope="$platform_scope" '
    NR > 1 && $1 == evidence_id {
      $8 = platform_scope
      changed = 1
    }
    { print }
    END { if (!changed) exit 3 }
  ' "$file"
}

mutate_platform_target() {
  file=$1
  feature_id=$2
  old_target=$3
  new_target=$4
  # shellcheck disable=SC2016 # AWK field references must not expand in the shell.
  replace_file "$file" awk -F "$TAB" -v OFS="$TAB" -v feature_id="$feature_id" \
    -v old_target="$old_target" -v new_target="$new_target" '
    NR > 1 && $1 == feature_id && $2 == old_target {
      $2 = new_target
      changed = 1
    }
    { print }
    END { if (!changed) exit 3 }
  ' "$file"
}

expect_pass pristine-validate "$pristine" validate
expect_pass pristine-docs-check "$pristine" check

fresh_case version
mutate_version "$case_root/src/version.lisp"
expect_failure version-drift "$case_root" check

fresh_case missing-release-notes
rm "$case_root/docs/releases/current.md"
expect_failure_matching missing-release-notes "$case_root" validate \
  'required input is missing: docs/releases/current.md'

fresh_case stale-binary
mkdir -p "$case_root/build"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "clun 0.1.0-dev.6"' > "$case_root/build/clun"
chmod +x "$case_root/build/clun"
stale_log=$scratch/stale-binary.log
if CLUN_COMPAT_ROOT=$case_root TMPDIR=$scratch/tmp \
    sh "$compat_tool" run language.typescript >"$stale_log" 2>&1; then
  cat "$stale_log" >&2
  fail 'stale-binary unexpectedly passed'
fi
grep -F 'build/clun version mismatch: expected clun 0.1.0-dev.7, got clun 0.1.0-dev.6' \
  "$stale_log" >/dev/null 2>&1 || {
  cat "$stale_log" >&2
  fail 'stale-binary failed without the expected version diagnostic'
}
printf '  (pass) stale-binary rejected deliberate drift\n'

fresh_case feature-status
mutate_feature_status "$case_root/compat/features.tsv"
expect_failure feature-status-drift "$case_root" check

fresh_case next-phase-render
move_release_to_phase_28 "$case_root/compat/release.tsv"
move_state_to_phase_28 "$case_root/STATE.md"
expect_pass next-phase-generate "$case_root" generate
grep -F '# Clun 0.1.0-dev.7' "$case_root/docs/releases/current.md" >/dev/null 2>&1 ||
  fail 'next-phase render lost the release version'
grep -F 'Phase 28: TLS, DNS, streaming transport, and public npm.' \
  "$case_root/docs/releases/current.md" >/dev/null 2>&1 ||
  fail 'next-phase render retained a Phase 27-specific summary'
if grep -Fq 'Phase 25b is complete' "$case_root/README.md"; then
  fail 'next-phase render retained a Phase 25b-specific prior-release statement'
fi
grep -F 'Phase 28 is active:' "$case_root/site/index.html" >/dev/null 2>&1 ||
  fail 'next-phase render did not update the landing-page phase status'
grep -F 'github.com/theesfeld/clun/issues/2' "$case_root/site/index.html" >/dev/null 2>&1 ||
  fail 'next-phase render did not update the landing-page canonical issue'
if grep -Fq 'Phase 27 is active:' "$case_root/site/index.html"; then
  fail 'next-phase render retained stale Phase 27 landing-page status'
fi

fresh_case active-state-drift
move_release_to_phase_28 "$case_root/compat/release.tsv"
expect_failure_matching active-state-drift "$case_root" validate \
  'STATE.md current phase 27 disagrees with release ledger phase 28'

fresh_case published-render
publish_release "$case_root/compat/release.tsv"
expect_pass published-generate "$case_root" generate
grep -F 'Available now' "$case_root/site/index.html" >/dev/null 2>&1 ||
  fail 'published render did not expose the published release'
grep -F 'latest published prerelease' "$case_root/README.md" >/dev/null 2>&1 ||
  fail 'published render did not expose the published release summary'

fresh_case refreshed-baselines
refresh_baseline_row "$case_root/compat/baselines.tsv" bun-engineering-c1076ce95e \
  9.9.0-dev 2222222222222222222222222222222222222222 - \
  https://github.com/oven-sh/bun/tree/2222222222222222222222222222222222222222
refresh_baseline_row "$case_root/compat/baselines.tsv" bun-stable-1.3.14 \
  9.8.7 1111111111111111111111111111111111111111 bun-v9.8.7 \
  https://github.com/oven-sh/bun/tree/1111111111111111111111111111111111111111
refresh_baseline_row "$case_root/compat/baselines.tsv" deno-stable-2.9.3 \
  9.2.0 4444444444444444444444444444444444444444 v9.2.0 \
  https://github.com/denoland/deno/tree/4444444444444444444444444444444444444444
refresh_baseline_row "$case_root/compat/baselines.tsv" node-current-26.5.0 \
  99.1.0 3333333333333333333333333333333333333333 v99.1.0 \
  https://github.com/nodejs/node/tree/3333333333333333333333333333333333333333
refresh_upstream_asset_tag "$case_root/compat/upstream-assets.tsv" bun-v1.3.14 bun-v9.8.7
for mapping in \
  'bun-engineering-c1076ce95e bun-engineering-refresh' \
  'bun-stable-1.3.14 bun-stable-refresh' \
  'deno-stable-2.9.3 deno-stable-refresh' \
  'node-current-26.5.0 node-current-refresh'; do
  old_id=${mapping%% *}
  new_id=${mapping#* }
  rename_baseline_reference "$case_root/compat/baselines.tsv" 1 "$old_id" "$new_id"
  rename_baseline_reference "$case_root/compat/references.tsv" 3 "$old_id" "$new_id"
  if [ "$old_id" = bun-stable-1.3.14 ]; then
    rename_baseline_reference "$case_root/compat/upstream-assets.tsv" 1 "$old_id" "$new_id"
  fi
done
expect_pass refreshed-baselines-generate "$case_root" generate
grep -F 'Bun 9.8.7, Node.js 99.1.0, and Deno 9.2.0' \
  "$case_root/README.md" >/dev/null 2>&1 ||
  fail 'baseline refresh did not update the README snapshot'
grep -F 'stable Bun 9.8.7 runtime feature matrix' "$case_root/site/index.html" >/dev/null 2>&1 ||
  fail 'baseline refresh did not update the landing-page comparison introduction'
grep -F '2222222222</code> (<code>9.9.0-dev</code>)' \
  "$case_root/site/index.html" >/dev/null 2>&1 ||
  fail 'baseline refresh did not update the engineering introduction'
if grep -Fq 'stable Bun 1.3.14 runtime feature matrix' "$case_root/site/index.html"; then
  fail 'baseline refresh retained stale landing-page baseline copy'
fi

fresh_case evidence-owner
mutate_owner "$case_root/compat/evidence.tsv" 2
expect_failure evidence-owner-drift "$case_root" validate

fresh_case reference-owner
mutate_owner "$case_root/compat/references.tsv" 2
expect_failure reference-owner-drift "$case_root" validate

fresh_case missing-node-reference
remove_reference "$case_root/compat/references.tsv" ref.cloud.s3.node.v1
expect_failure_matching missing-node-reference "$case_root" validate \
  'feature cloud.s3 must have exactly one Node.js and one Deno comparison reference'

fresh_case wrong-comparison-baseline
mutate_reference_field "$case_root/compat/references.tsv" ref.cloud.s3.node.v1 3 deno-stable-2.9.3
expect_failure_matching wrong-comparison-baseline "$case_root" validate \
  'feature cloud.s3 must have exactly one Node.js and one Deno comparison reference'

fresh_case wrong-comparison-kind
mutate_reference_field "$case_root/compat/references.tsv" ref.cloud.s3.node.v1 4 stable-map
expect_failure_matching wrong-comparison-kind "$case_root" validate \
  'Node.js comparison reference must use comparison-page'

fresh_case unsafe-reference-path
mutate_reference_field "$case_root/compat/references.tsv" ref.cloud.s3.node.v1 5 ../README.md
expect_failure_matching unsafe-reference-path "$case_root" validate \
  'invalid reference repository path: ../README.md'

fresh_case comparison-assertion
mutate_reference_field "$case_root/compat/references.tsv" ref.cloud.s3.node.v1 6 'Yes: deliberate drift'
expect_failure_matching comparison-assertion "$case_root" validate \
  'Node.js comparison assertion disagrees with features.tsv'

fresh_case bun-stable-assertion
mutate_reference_field "$case_root/compat/references.tsv" ref.cloud.s3.bun-stable.v1 6 'No: deliberate drift'
expect_failure_matching bun-stable-assertion "$case_root" validate \
  'Bun stable assertion disagrees with features.tsv'

fresh_case noncanonical-executable
mutate_evidence_executable "$case_root/compat/evidence.tsv" \
  ev.language.typescript.annotations.v1 scripts/fake-clun
expect_failure_matching noncanonical-executable "$case_root" validate \
  'executable evidence must use the canonical build/clun artifact'

fresh_case comparison-revision
mutate_baseline_revision "$case_root/compat/baselines.tsv" node-current-26.5.0
expect_failure_matching comparison-revision "$case_root" validate \
  'baseline source URL must pin its full revision'

fresh_case incomplete-baseline
mutate_baseline_field "$case_root/compat/baselines.tsv" bun-stable-1.3.14 8 -
expect_failure_matching incomplete-baseline "$case_root" validate \
  'baseline purpose must not be empty or -'

fresh_case previous-version-semver
mutate_release_previous_version "$case_root/compat/release.tsv" 01.0.0
expect_failure_matching previous-version-semver "$case_root" validate \
  'previous release version must be strict SemVer'

fresh_case platform-owner
mutate_owner "$case_root/compat/platforms.tsv" 1
expect_failure platform-owner-drift "$case_root" validate

release_begin='<!-- clun-generated:release:begin -->'
release_end='<!-- clun-generated:release:end -->'

fresh_case duplicate-marker
duplicate_marker "$case_root/README.md" "$release_begin"
expect_failure duplicate-marker "$case_root" check

fresh_case reversed-markers
reverse_markers "$case_root/README.md" "$release_begin" "$release_end"
expect_failure reversed-markers "$case_root" check

fresh_case missing-marker
remove_marker "$case_root/README.md" "$release_begin"
expect_failure missing-marker "$case_root" check

fresh_case benchmark-manifest
remove_benchmark_row "$case_root/compat/benchmarks/workloads.tsv"
expect_failure benchmark-manifest-drift "$case_root" validate

fresh_case benchmark-hash
printf '\n// deliberate fixture digest drift\n' >> "$case_root/bench/deltablue.js"
expect_failure benchmark-hash-drift "$case_root" validate

fresh_case public-superlative
printf '\nClun is faster than Bun.\n' >> "$case_root/README.md"
expect_failure_matching public-superlative "$case_root" check \
  'public documents contain an unqualified cross-runtime superlative'

fresh_case yes-without-executable
move_release_to_phase_28 "$case_root/compat/release.tsv"
promote_feature_to_yes "$case_root/compat/features.tsv" cloud.s3
support_feature_on_all_targets "$case_root/compat/platforms.tsv" cloud.s3 -
expect_failure_matching yes-without-executable "$case_root" validate \
  'Yes feature cloud.s3 has no shipped-binary evidence'

fresh_case yes-without-four-target-evidence
move_release_to_phase_28 "$case_root/compat/release.tsv"
promote_feature_to_yes "$case_root/compat/features.tsv" runtime.web-standard-apis
support_feature_on_all_targets "$case_root/compat/platforms.tsv" runtime.web-standard-apis \
  ev.runtime.web-standard-apis.fetch-suite.v1
expect_failure_matching yes-without-four-target-evidence "$case_root" validate \
  'Yes feature runtime.web-standard-apis has no target-scoped shipped-binary evidence on darwin-arm64'

fresh_case checked-script-without-scope
mutate_evidence_scope "$case_root/compat/evidence.tsv" \
  ev.package-manager.npm.hermetic-install.v1 -
expect_failure_matching checked-script-without-scope "$case_root" validate \
  'executable evidence requires at least one platform target'

fresh_case static-with-platform-scope
mutate_evidence_scope "$case_root/compat/evidence.tsv" \
  ev.runtime.web-standard-apis.fetch-suite.v1 linux-x64
expect_failure_matching static-with-platform-scope "$case_root" validate \
  'static evidence requires -, a safe fixture path, -, and - platform scope'

fresh_case executable-scope-mismatch
mutate_evidence_scope "$case_root/compat/evidence.tsv" \
  ev.language.typescript.annotations.v1 darwin-x64,linux-arm64,linux-x64
expect_failure_matching executable-scope-mismatch "$case_root" validate \
  'platform evidence ev.language.typescript.annotations.v1 does not declare target darwin-arm64'

fresh_case invalid-platform-target
mutate_platform_target "$case_root/compat/platforms.tsv" cloud.s3 darwin-arm64 macos-arm64
expect_failure_matching invalid-platform-target "$case_root" validate \
  'invalid target: macos-arm64'

printf 'test-compat-tools: 2 pristine checks, 3 forward-render cases, and 30 deliberate-drift cases passed\n'
