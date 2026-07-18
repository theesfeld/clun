# Phase 27 compatibility-ledger validator. Input files are passed in the order
# documented by scripts/compat.sh. This is POSIX awk so the documentation gate
# runs unchanged on Linux and macOS.

BEGIN {
  OFS = FS
  failures = 0
  feature_count = 0
  release_count = 0
  baseline_count = 0
  workload_count = 0
  metric_count = 0
}

function fail(message) {
  print "compat-validate: " FILENAME ":" FNR ": " message > "/dev/stderr"
  failures++
}

function expect_header(expected) {
  if ($0 != expected) fail("unexpected header; expected " expected)
}

function require_fields(count) {
  if (NF != count) {
    fail("expected " count " fields, found " NF)
    return 0
  }
  return 1
}

function require_value(value, name) {
  if (value == "" || value == "-") {
    fail(name " must not be empty or -")
    return 0
  }
  return 1
}

function valid_id(value) {
  return value ~ /^[a-z0-9][a-z0-9.-]*$/ && value !~ /\.\./ && value !~ /--/
}

function valid_phase(value) {
  return value ~ /^[0-9]+$/ && (value + 0) >= 27 && (value + 0) <= 82
}

function valid_sha256(value) {
  return value ~ /^[0-9a-f]+$/ && length(value) == 64
}

function require_sorted(key, file_key) {
  if ((file_key in previous_key) && key <= previous_key[file_key])
    fail("rows are not strictly sorted: " key " follows " previous_key[file_key])
  previous_key[file_key] = key
}

function remember_unique(array, key, what) {
  if (key in array) fail("duplicate " what ": " key)
  array[key] = 1
}

function split_values(value, output, what,    count, i, prior) {
  if (value == "-") return 0
  count = split(value, output, ",")
  prior = ""
  for (i = 1; i <= count; i++) {
    if (output[i] == "" || output[i] == "-") fail(what " contains an empty value")
    if (prior != "" && output[i] <= prior) fail(what " is not strictly sorted: " value)
    prior = output[i]
  }
  return count
}

function state_allowed(value) {
  return value == "Yes" || value == "Partial" || value == "No" || value == "Separate"
}

function target_allowed(value) {
  return value == "darwin-arm64" || value == "darwin-x64" || \
         value == "linux-arm64" || value == "linux-x64"
}

function safe_repo_path(value) {
  return value != "" && value != "-" && value !~ /^\// && value !~ /(^|\/)\.\.(\/|$)/ && \
         value !~ /\/\// && value !~ /[[:cntrl:]]/
}

function valid_semver_identifiers(value, reject_numeric_leading_zero,    count, i, identifiers) {
  count = split(value, identifiers, /\./)
  if (count == 0) return 0
  for (i = 1; i <= count; i++) {
    if (identifiers[i] == "" || identifiers[i] !~ /^[0-9A-Za-z-]+$/) return 0
    if (reject_numeric_leading_zero && identifiers[i] ~ /^[0-9]+$/ && \
        length(identifiers[i]) > 1 && substr(identifiers[i], 1, 1) == "0") return 0
  }
  return 1
}

function valid_semver(value,    build_count, core_count, dash, i, core, prerelease, build_parts, core_parts) {
  build_count = split(value, build_parts, /[+]/)
  if (build_count > 2 || (build_count == 2 && !valid_semver_identifiers(build_parts[2], 0))) return 0

  core = build_parts[1]
  dash = index(core, "-")
  if (dash) {
    prerelease = substr(core, dash + 1)
    core = substr(core, 1, dash - 1)
    if (!valid_semver_identifiers(prerelease, 1)) return 0
  }

  core_count = split(core, core_parts, /\./)
  if (core_count != 3) return 0
  for (i = 1; i <= 3; i++) {
    if (core_parts[i] !~ /^[0-9]+$/) return 0
    if (length(core_parts[i]) > 1 && substr(core_parts[i], 1, 1) == "0") return 0
  }
  return 1
}

function valid_calendar_date(value,    year, month, day, max_day) {
  if (value !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) return 0
  year = substr(value, 1, 4) + 0
  month = substr(value, 6, 2) + 0
  day = substr(value, 9, 2) + 0
  if (month < 1 || month > 12 || day < 1) return 0
  if (month == 2) {
    max_day = ((year % 400 == 0) || (year % 4 == 0 && year % 100 != 0)) ? 29 : 28
  } else if (month == 4 || month == 6 || month == 9 || month == 11) {
    max_day = 30
  } else {
    max_day = 31
  }
  return day <= max_day
}

FNR == 1 {
  if (FILENAME ~ /docs\/roadmap\.tsv$/)
    expect_header("phase" FS "slug" FS "title" FS "track")
  else if (FILENAME ~ /compat\/baselines\.tsv$/)
    expect_header("baseline_id" FS "runtime" FS "version" FS "channel" FS "revision" FS "tag" FS "checked_on" FS "purpose" FS "source_url" FS "license")
  else if (FILENAME ~ /compat\/features\.tsv$/)
    expect_header("feature_id" FS "display_order" FS "display_group" FS "capability" FS "summary" FS "clun_state" FS "clun_detail" FS "gap" FS "bun_state" FS "bun_detail" FS "node_state" FS "node_detail" FS "deno_state" FS "deno_detail" FS "primary_phase" FS "integration_phases")
  else if (FILENAME ~ /compat\/evidence\.tsv$/)
    expect_header("evidence_id" FS "feature_id" FS "kind" FS "command" FS "executable_path" FS "fixture_path" FS "expected_path" FS "platform_scope" FS "assertion")
  else if (FILENAME ~ /compat\/platforms\.tsv$/)
    expect_header("feature_id" FS "target" FS "support_state" FS "evidence_ids" FS "note")
  else if (FILENAME ~ /compat\/references\.tsv$/)
    expect_header("reference_id" FS "feature_id" FS "baseline_id" FS "kind" FS "paths" FS "assertion")
  else if (FILENAME ~ /compat\/release\.tsv$/)
    expect_header("release_id" FS "version" FS "asdf_core" FS "installer_default" FS "tag" FS "publication_state" FS "license" FS "active_phase" FS "issue" FS "semver_impact" FS "previous_version" FS "version_source" FS "asdf_source" FS "installer_source" FS "release_commit")
  else if (FILENAME ~ /compat\/upstream-assets\.tsv$/)
    expect_header("baseline_id" FS "target" FS "asset_name" FS "sha256" FS "source_url")
  else if (FILENAME ~ /compat\/benchmarks\/workloads\.tsv$/)
    expect_header("workload_id" FS "coverage_scope" FS "owner_phase" FS "fixture_path" FS "fixture_sha256" FS "runner_path" FS "runner_sha256" FS "mode" FS "iterations" FS "warmups" FS "default_repetitions" FS "correctness_signal" FS "immutable_since")
  else if (FILENAME ~ /compat\/benchmarks\/metrics\.tsv$/)
    expect_header("metric_id" FS "workload_id" FS "metric" FS "unit" FS "direction" FS "aggregation" FS "required" FS "claim_scope" FS "immutable_since")
  else
    fail("unexpected input file")
  next
}

/\r$/ { fail("CRLF line ending is not allowed") }
NF == 0 { fail("blank records are not allowed"); next }

FILENAME ~ /docs\/roadmap\.tsv$/ {
  if (!require_fields(4)) next
  if (!valid_phase($1)) fail("invalid roadmap phase: " $1)
  remember_unique(roadmap_phase, $1, "roadmap phase")
  next
}

FILENAME ~ /compat\/baselines\.tsv$/ {
  if (!require_fields(10)) next
  baseline_count++
  require_sorted($1, "baselines")
  if (!valid_id($1)) fail("invalid baseline ID: " $1)
  remember_unique(baseline, $1, "baseline ID")
  require_value($2, "baseline runtime")
  if (!valid_semver($3)) fail("baseline version must be strict SemVer")
  if ($4 != "stable-executable" && $4 != "engineering-source" && $4 != "comparison-release")
    fail("invalid baseline channel: " $4)
  if ($5 !~ /^[0-9a-f]+$/ || length($5) != 40)
    fail("baseline revision must be a full commit SHA")
  if (!valid_calendar_date($7)) fail("invalid checked_on date")
  require_value($8, "baseline purpose")
  if ($9 !~ /^https:\/\//) fail("baseline source URL must use HTTPS")
  else if (index($9, $5) == 0) fail("baseline source URL must pin its full revision")
  if ($10 != "MIT") fail("comparison baseline license must be MIT")
  baseline_channel[$1] = $4
  baseline_runtime[$1] = $2
  baseline_tag[$1] = $6
  if ($2 == "Bun" && $4 == "stable-executable") {
    bun_stable_baseline_count++
    bun_stable_baseline_id = $1
    bun_stable_checked = $7
    if ($6 != "bun-v" $3) fail("Bun stable tag must be bun-v<version>")
  } else if ($2 == "Bun" && $4 == "engineering-source") {
    bun_engineering_baseline_count++
    bun_engineering_baseline_id = $1
    bun_engineering_checked = $7
    if ($6 != "-") fail("Bun engineering baseline tag must be -")
  } else if ($2 == "Node.js" && $4 == "comparison-release") {
    node_baseline_count++
    node_baseline_id = $1
    node_checked = $7
    if ($6 != "v" $3) fail("Node.js comparison tag must be v<version>")
  } else if ($2 == "Deno" && $4 == "comparison-release") {
    deno_baseline_count++
    deno_baseline_id = $1
    deno_checked = $7
    if ($6 != "v" $3) fail("Deno comparison tag must be v<version>")
  } else {
    fail("unexpected runtime/channel baseline role: " $2 "/" $4)
  }
  next
}

FILENAME ~ /compat\/features\.tsv$/ {
  if (!require_fields(16)) next
  require_sorted($1, "features")
  if (!valid_id($1)) fail("invalid feature ID: " $1)
  remember_unique(feature, $1, "feature ID")
  feature_count++
  feature_id[feature_count] = $1
  if ($2 !~ /^[0-9]+$/ || ($2 + 0) < 1 || ($2 + 0) > 30) fail("invalid display order: " $2)
  remember_unique(display_order, $2 + 0, "display order")
  if ($3 != "core" && $3 != "apis" && $3 != "tooling" && $3 != "utilities")
    fail("invalid display group: " $3)
  require_value($4, "capability")
  require_value($5, "summary")
  if ($6 != "Partial" && $6 != "No" && $6 != "Yes") fail("invalid Clun state: " $6)
  if (!state_allowed($9) || !state_allowed($11) || !state_allowed($13))
    fail("invalid comparison-runtime state")
  if ($6 == "Partial" && $8 == "-") fail("Partial requires an explicit gap")
  if ($6 == "Yes" && $8 != "-") fail("Yes cannot retain a gap")
  if ($6 == "No" && $7 == "-" && $8 == "-") fail("No requires a detail or gap")
  if (!valid_phase($15)) fail("invalid primary phase: " $15)
  if (!($15 in roadmap_phase)) fail("primary phase is absent from docs/roadmap.tsv: " $15)
  primary_phase[$1] = $15
  clun_state[$1] = $6
  bun_state[$1] = $9
  bun_detail[$1] = $10
  gap[$1] = $8
  node_state[$1] = $11
  node_detail[$1] = $12
  deno_state[$1] = $13
  deno_detail[$1] = $14
  integration_count = split_values($16, values, "integration phases")
  for (i = 1; i <= integration_count; i++) {
    if (!valid_phase(values[i])) fail("invalid integration phase: " values[i])
    if (!(values[i] in roadmap_phase)) fail("integration phase is absent from docs/roadmap.tsv: " values[i])
    if (values[i] == $15) fail("primary phase is repeated as an integration phase")
  }
  next
}

FILENAME ~ /compat\/evidence\.tsv$/ {
  if (!require_fields(9)) next
  require_sorted($1, "evidence")
  if (!valid_id($1)) fail("invalid evidence ID: " $1)
  remember_unique(evidence, $1, "evidence ID")
  evidence_feature[$1] = $2
  evidence_count[$2]++
  if ($3 != "fixture" && $3 != "suite" && $3 != "report" && $3 != "decision" && $3 != "benchmark")
    fail("invalid evidence kind: " $3)
  if ($4 != "clun-fixture" && $4 != "checked-script" && $4 != "static")
    fail("invalid evidence command: " $4)
  if ($4 == "clun-fixture") {
    executable_evidence[$2]++
    executable_evidence_id[$1] = 1
    if (!safe_repo_path($5) || !safe_repo_path($6) || !safe_repo_path($7))
      fail("clun-fixture requires safe executable, fixture, and expected paths")
  } else if ($4 == "checked-script") {
    executable_evidence[$2]++
    executable_evidence_id[$1] = 1
    if (!safe_repo_path($5) || !safe_repo_path($6) || $7 != "-")
      fail("checked-script requires safe executable and script paths plus - expected path")
  } else {
    if ($5 != "-" || !safe_repo_path($6) || $7 != "-" || $8 != "-")
      fail("static evidence requires -, a safe fixture path, -, and - platform scope")
  }
  if (executable_evidence_id[$1] && $5 != "build/clun")
    fail("executable evidence must use the canonical build/clun artifact")
  if ($6 != "-" && !safe_repo_path($6)) fail("invalid fixture path")
  if ($7 != "-" && !safe_repo_path($7)) fail("invalid expected path")
  platform_count = split_values($8, targets, "platform scope")
  if (executable_evidence_id[$1] && platform_count == 0)
    fail("executable evidence requires at least one platform target")
  for (i = 1; i <= platform_count; i++) {
    if (!target_allowed(targets[i])) fail("invalid evidence target: " targets[i])
    evidence_target[$1 SUBSEP targets[i]] = 1
  }
  require_value($9, "evidence assertion")
  next
}

FILENAME ~ /compat\/platforms\.tsv$/ {
  if (!require_fields(5)) next
  key = $1 SUBSEP $2
  require_sorted($1 "\t" $2, "platforms")
  remember_unique(platform_row, key, "feature/target platform row")
  platform_count_by_feature[$1]++
  if (!target_allowed($2)) fail("invalid target: " $2)
  if ($3 != "supported" && $3 != "unverified" && $3 != "unsupported" && $3 != "not-applicable")
    fail("invalid support state: " $3)
  platform_state[key] = $3
  evidence_ref_count = split_values($4, evidence_refs, "platform evidence IDs")
  platform_evidence_count[key] = evidence_ref_count
  if ($3 == "supported" && evidence_ref_count == 0)
    fail("supported platform requires at least one evidence ID")
  for (i = 1; i <= evidence_ref_count; i++) platform_evidence_ref[key SUBSEP evidence_refs[i]] = 1
  require_value($5, "platform note")
  next
}

FILENAME ~ /compat\/references\.tsv$/ {
  if (!require_fields(6)) next
  require_sorted($1, "references")
  if (!valid_id($1)) fail("invalid reference ID: " $1)
  remember_unique(reference, $1, "reference ID")
  if ($4 != "stable-map" && $4 != "engineering-map" && $4 != "comparison-page" && $4 != "binary-probe")
    fail("invalid reference kind: " $4)
  reference_path_count = split_values($5, reference_paths, "reference paths")
  if (reference_path_count == 0) fail("reference paths must not be empty or -")
  for (i = 1; i <= reference_path_count; i++) {
    if (!safe_repo_path(reference_paths[i])) fail("invalid reference repository path: " reference_paths[i])
  }
  require_value($6, "reference assertion")
  reference_count[$2]++
  reference_baseline[$1] = $3
  reference_feature[$1] = $2
  if (baseline_runtime[$3] == "Bun" && baseline_channel[$3] == "stable-executable") {
    stable_reference[$2]++
    if ($4 != "stable-map") fail("Bun stable reference must use stable-map")
    if ($6 != bun_state[$2] ": " bun_detail[$2])
      fail("Bun stable assertion disagrees with features.tsv")
  }
  if (baseline_runtime[$3] == "Bun" && baseline_channel[$3] == "engineering-source") {
    engineering_reference[$2]++
    if ($4 != "engineering-map") fail("Bun engineering reference must use engineering-map")
  }
  if (baseline_runtime[$3] == "Node.js" && baseline_channel[$3] == "comparison-release") {
    node_reference[$2]++
    if ($4 != "comparison-page") fail("Node.js comparison reference must use comparison-page")
    if ($6 != node_state[$2] ": " node_detail[$2])
      fail("Node.js comparison assertion disagrees with features.tsv")
  }
  if (baseline_runtime[$3] == "Deno" && baseline_channel[$3] == "comparison-release") {
    deno_reference[$2]++
    if ($4 != "comparison-page") fail("Deno comparison reference must use comparison-page")
    if ($6 != deno_state[$2] ": " deno_detail[$2])
      fail("Deno comparison assertion disagrees with features.tsv")
  }
  next
}

FILENAME ~ /compat\/release\.tsv$/ {
  if (!require_fields(15)) next
  release_count++
  if (release_count > 1) fail("exactly one active release row is allowed")
  if (!valid_id($1)) fail("invalid release ID: " $1)
  if ($2 != source_version) fail("release version " $2 " disagrees with src/version.lisp " source_version)
  if ($3 != asdf_version) fail("release ASDF core " $3 " disagrees with clun.asd " asdf_version)
  if ($4 != "v" installer_version) fail("installer default " $4 " disagrees with site/install v" installer_version)
  if ($5 != "v" $2) fail("release tag must be v<version>")
  if ($6 != "candidate" && $6 != "published") fail("invalid publication state: " $6)
  if ($7 != "GPL-3.0-or-later") fail("release license must be GPL-3.0-or-later")
  if (!valid_phase($8) || !($8 in roadmap_phase)) fail("release active phase is undefined: " $8)
  if ($9 !~ /^[0-9]+$/ || ($9 + 0) < 1) fail("release issue must be a positive integer")
  if ($10 != "major" && $10 != "minor" && $10 != "patch" && $10 != "none")
    fail("invalid release SemVer impact: " $10)
  if (!valid_semver($11)) fail("previous release version must be strict SemVer")
  if ($12 != "src/version.lisp" || $13 != "clun.asd" || $14 != "site/install")
    fail("release source paths are not canonical")
  if ($6 == "candidate" && $15 != "pending")
    fail("candidate release commit must be pending")
  if ($6 == "published" && ($15 !~ /^[0-9a-f]+$/ || length($15) != 40))
    fail("published release commit must be a full commit SHA")
  active_release_id = $1
  active_release_version = $2
  active_release_state = $6
  active_release_phase = $8
  next
}

FILENAME ~ /compat\/upstream-assets\.tsv$/ {
  if (!require_fields(5)) next
  require_sorted($1 "\t" $2, "upstream-assets")
  key = $1 SUBSEP $2
  remember_unique(upstream_asset, key, "baseline/target asset")
  if (!target_allowed($2)) fail("invalid upstream asset target: " $2)
  if (!valid_sha256($4)) fail("invalid upstream asset SHA-256")
  if ($5 !~ /^https:\/\//) fail("upstream asset URL must use HTTPS")
  if (baseline_runtime[$1] != "Bun" || baseline_channel[$1] != "stable-executable")
    fail("upstream assets must reference the Bun stable executable baseline")
  else if (index($5, "/releases/download/" baseline_tag[$1] "/") == 0)
    fail("upstream asset URL must contain the Bun stable release tag")
  upstream_asset_count[$1]++
  next
}

FILENAME ~ /compat\/benchmarks\/workloads\.tsv$/ {
  if (!require_fields(13)) next
  require_sorted($1, "workloads")
  if (!valid_id($1)) fail("invalid workload ID: " $1)
  remember_unique(workload, $1, "workload ID")
  workload_count++
  if (!($3 == "25" || valid_phase($3))) fail("invalid workload owner phase: " $3)
  if ($8 == "cold-start") {
    if ($4 != "-" || $5 != "-") fail("cold-start workload must use - for fixture path and digest")
  } else if (!safe_repo_path($4) || !valid_sha256($5))
    fail("steady-state workload fixture path and SHA-256 must be complete")
  if (!safe_repo_path($6) || !valid_sha256($7)) fail("workload runner path and SHA-256 must be complete")
  if ($8 != "cold-start" && $8 != "steady-state") fail("invalid workload mode: " $8)
  if ($9 !~ /^[0-9]+$/ || $10 !~ /^[0-9]+$/ || $11 !~ /^[0-9]+$/ || ($11 + 0) < 1)
    fail("invalid workload iteration/warmup/repetition counts")
  require_value($12, "workload correctness signal")
  if ($13 !~ /^phase-[0-9]+$/) fail("invalid immutable_since value")
  next
}

FILENAME ~ /compat\/benchmarks\/metrics\.tsv$/ {
  if (!require_fields(9)) next
  require_sorted($1, "metrics")
  if (!valid_id($1)) fail("invalid metric ID: " $1)
  remember_unique(metric, $1, "metric ID")
  metric_count++
  metric_workload[$1] = $2
  workload_metric_count[$2]++
  if ($5 != "lower" && $5 != "higher") fail("invalid metric direction: " $5)
  if ($6 !~ /^(minimum|median|p50|p95|maximum)(-of-[0-9]+)?$/)
    fail("invalid metric aggregation: " $6)
  if ($7 != "Yes" && $7 != "No") fail("metric required must be Yes or No")
  require_value($8, "metric claim scope")
  if ($9 !~ /^phase-[0-9]+$/) fail("invalid metric immutable_since value")
  next
}

END {
  if (feature_count != 30) fail("expected exactly 30 matrix features, found " feature_count)
  if (release_count != 1) fail("expected exactly one active release row, found " release_count)
  if (workload_count != 4) fail("expected four immutable seed workloads, found " workload_count)
  if (metric_count == 0) fail("benchmark metric manifest is empty")
  if (baseline_count != 4) fail("expected exactly four runtime baselines, found " baseline_count)
  if (bun_stable_baseline_count != 1) fail("expected exactly one Bun stable executable baseline")
  if (bun_engineering_baseline_count != 1) fail("expected exactly one Bun engineering source baseline")
  if (node_baseline_count != 1) fail("expected exactly one Node.js comparison baseline")
  if (deno_baseline_count != 1) fail("expected exactly one Deno comparison baseline")
  if (bun_stable_baseline_count == 1 && bun_engineering_baseline_count == 1 && \
      node_baseline_count == 1 && deno_baseline_count == 1 && \
      (bun_stable_checked != bun_engineering_checked || bun_stable_checked != node_checked || \
       bun_stable_checked != deno_checked))
    fail("all compatibility baselines must share one checked_on snapshot date")

  yes = partial = no = 0
  for (i = 1; i <= feature_count; i++) {
    id = feature_id[i]
    if (!(primary_phase[id] in roadmap_phase)) fail("feature " id " references undefined primary phase " primary_phase[id])
    if (clun_state[id] == "Yes") yes++
    else if (clun_state[id] == "Partial") partial++
    else if (clun_state[id] == "No") no++
    if (platform_count_by_feature[id] != 4)
      fail("feature " id " must have exactly four platform rows")
    if (stable_reference[id] != 1 || engineering_reference[id] != 1)
      fail("feature " id " must have exactly one Bun stable and one Bun engineering reference")
    if (node_reference[id] != 1 || deno_reference[id] != 1)
      fail("feature " id " must have exactly one Node.js and one Deno comparison reference")
    if (clun_state[id] == "Partial" && evidence_count[id] == 0)
      fail("Partial feature " id " has no evidence record")
    if (clun_state[id] == "Yes") {
      if (executable_evidence[id] == 0) fail("Yes feature " id " has no shipped-binary evidence")
      split("darwin-arm64 darwin-x64 linux-arm64 linux-x64", required_targets, " ")
      for (j = 1; j <= 4; j++) {
        key = id SUBSEP required_targets[j]
        if (platform_state[key] != "supported")
          fail("Yes feature " id " is not supported on " required_targets[j])
        if (platform_evidence_count[key] == 0)
          fail("Yes feature " id " has no target evidence on " required_targets[j])
        target_executable = 0
        for (evidence_id in evidence) {
          if (evidence_feature[evidence_id] == id && \
              platform_evidence_ref[key SUBSEP evidence_id] && \
              executable_evidence_id[evidence_id] && \
              ((evidence_id SUBSEP required_targets[j]) in evidence_target))
            target_executable = 1
        }
        if (!target_executable)
          fail("Yes feature " id " has no target-scoped shipped-binary evidence on " required_targets[j])
      }
    }
  }
  if (active_release_phase == 27 && (yes != 0 || partial != 6 || no != 24))
    fail("Phase 27 seed must be 0 Yes / 6 Partial / 24 No; found " yes " / " partial " / " no)

  for (id in evidence_feature) {
    if (!(evidence_feature[id] in feature)) fail("evidence " id " references unknown feature " evidence_feature[id])
  }
  for (key in platform_row) {
    split(key, parts, SUBSEP)
    if (!(parts[1] in feature)) fail("platform row references unknown feature " parts[1])
  }
  for (key in platform_evidence_ref) {
    split(key, parts, SUBSEP)
    if (!(parts[3] in evidence)) fail("platform row references unknown evidence " parts[3])
    else if (evidence_feature[parts[3]] != parts[1])
      fail("platform evidence " parts[3] " belongs to another feature")
    else if (executable_evidence_id[parts[3]] && \
             !((parts[3] SUBSEP parts[2]) in evidence_target))
      fail("platform evidence " parts[3] " does not declare target " parts[2])
  }
  for (id in reference_feature) {
    if (!(reference_feature[id] in feature)) fail("reference " id " references unknown feature " reference_feature[id])
    if (!(reference_baseline[id] in baseline)) fail("reference " id " references unknown baseline " reference_baseline[id])
  }
  for (id in upstream_asset) {
    split(id, parts, SUBSEP)
    if (!(parts[1] in baseline)) fail("upstream asset references unknown baseline " parts[1])
  }
  if (bun_stable_baseline_count == 1 && upstream_asset_count[bun_stable_baseline_id] != 4)
    fail("Bun stable executable map must contain exactly four supported targets")
  for (id in metric_workload) if (!(metric_workload[id] in workload))
    fail("metric " id " references unknown workload " metric_workload[id])
  for (id in workload) if (workload_metric_count[id] == 0)
    fail("workload " id " has no metric coverage")

  if (failures) exit 1
  print "compat-validate: 30 features (" yes " Yes / " partial " Partial / " no " No), four targets, " \
        workload_count " workloads, and " metric_count " metrics valid" > "/dev/stderr"
}
