#!/bin/sh
# shellcheck disable=SC2016

set -eu

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
ROOT=$(CDPATH='' cd "$SCRIPT_DIR/.." && pwd)
ROADMAP="$ROOT/docs/roadmap.tsv"
PLAN="$ROOT/PLAN.md"
README="$ROOT/README.md"
SITE="$ROOT/site"
VERSION_FILE="$ROOT/src/version.lisp"
STATE_FILE="$ROOT/STATE.md"
EXECUTION_REPORT="$ROOT/docs/conformance/test262-execution.md"
BUN_PIN=c1076ce95e
BUN_VERSION=1.4.0-dev
MILESTONE="Purity-compatible Bun parity"
FIRST_PHASE=27
LAST_PHASE=82
PHASE_COUNT=56
TAB=$(printf '\t')
CONTRACT_BEGIN='<!-- clun-roadmap-technical-contract:begin -->'
CONTRACT_END='<!-- clun-roadmap-technical-contract:end -->'
PHASE26_TITLE='Phase 26: Hardening, docs, release'
PHASE26_LABEL='phase-26'
PHASE26_MARKER='<!-- clun-canonical-phase:26 -->'
PHASE26_HEADER='# Canonical status'
SEMVER_IDENTIFIER='(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
SEMVER_PATTERN="^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-${SEMVER_IDENTIFIER}(\\.${SEMVER_IDENTIFIER})*)?(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?$"

usage() {
  printf 'usage: %s check\n' "$0" >&2
  printf '       %s verify-live\n' "$0" >&2
  printf '       %s sync [--dry-run]\n' "$0" >&2
  exit 2
}

fail() {
  printf 'roadmap: error: %s\n' "$*" >&2
  exit 1
}

is_semver() {
  printf '%s\n' "$1" | LC_ALL=C grep -Eq "$SEMVER_PATTERN"
}

verify_assigned_release_disposition() {
  body=$1
  phase=$2
  issue_number=$3
  impact=$(sed -n 's/^\*\*SemVer impact:\*\*[[:space:]]*`\([^`]*\)`$/\1/p' "$body")
  rationale=$(sed -n 's/^\*\*SemVer rationale:\*\*[[:space:]]*`\([^`]*\)`$/\1/p' "$body")
  release_version=$(sed -n 's/^\*\*Release version:\*\*[[:space:]]*`\([^`]*\)`$/\1/p' "$body")
  release_tag=$(sed -n 's/^\*\*Release tag:\*\*[[:space:]]*`\([^`]*\)`$/\1/p' "$body")
  case "$impact" in
    major|minor|patch|none) ;;
    *) fail "active Phase $phase issue #$issue_number has invalid SemVer impact: $impact" ;;
  esac
  case "$rationale" in
    ''|unassigned) fail "active Phase $phase issue #$issue_number has no SemVer rationale" ;;
  esac
  is_semver "$release_version" ||
    fail "active Phase $phase issue #$issue_number has invalid release SemVer: $release_version"
  if [ "$impact" = none ]; then
    [ "$release_tag" = none ] ||
      fail "none-impact Phase $phase issue #$issue_number must use release tag none"
  else
    [ "$release_tag" = "v$release_version" ] ||
      fail "active Phase $phase issue #$issue_number release tag does not match its SemVer"
  fi
}

report_measure() {
  label=$1
  awk -F '|' -v label="$label" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    trim($2) == label { print trim($3); found = 1; exit }
    END { if (!found) exit 2 }
  ' "$EXECUTION_REPORT" || fail "could not read $label from the execution report"
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

extract_phase_section() {
  phase=$1
  awk -v target="$phase" '
    $0 ~ ("^### Phase " target "([^0-9]|$)") { active = 1 }
    active && emitted && ($0 ~ /^### Phase / || $0 ~ /^## /) { exit }
    active { print; emitted = 1 }
    END { if (!active) exit 2 }
  ' "$PLAN"
}

check_roadmap() {
  [ -f "$ROADMAP" ] || fail "missing docs/roadmap.tsv"
  [ -f "$PLAN" ] || fail "missing PLAN.md"

  expected=$FIRST_PHASE
  rows=0
  line_number=0
  while IFS="$TAB" read -r phase slug title track extra ||
        [ -n "${phase}${slug}${title}${track}${extra}" ]; do
    line_number=$((line_number + 1))
    if [ "$line_number" -eq 1 ]; then
      [ "$phase" = phase ] && [ "$slug" = slug ] &&
        [ "$title" = title ] && [ "$track" = track ] && [ -z "$extra" ] ||
        fail "docs/roadmap.tsv must start with: phase<TAB>slug<TAB>title<TAB>track"
      continue
    fi

    [ -n "$phase" ] || fail "blank row at docs/roadmap.tsv:$line_number"
    [ -z "$extra" ] || fail "too many fields at docs/roadmap.tsv:$line_number"
    case "$phase" in
      *[!0-9]*|'') fail "invalid phase at docs/roadmap.tsv:$line_number" ;;
    esac
    [ "$phase" -eq "$expected" ] ||
      fail "expected phase $expected at docs/roadmap.tsv:$line_number, found $phase"
    case "$slug" in
      ''|*[!a-z0-9-]*|-*|*-) fail "invalid slug for phase $phase: $slug" ;;
    esac
    [ -n "$title" ] || fail "missing title for phase $phase"
    [ -n "$track" ] || fail "missing track for phase $phase"

    heading=$(awk -v target="$phase" '
      $0 ~ ("^### Phase " target "([^0-9]|$)") { print; exit }
    ' "$PLAN")
    [ -n "$heading" ] || fail "PLAN.md has no Phase $phase heading"
    case "$heading" in
      *"$title"*) ;;
      *) fail "PLAN.md Phase $phase heading does not contain TSV title: $title" ;;
    esac

    expected=$((expected + 1))
    rows=$((rows + 1))
  done < "$ROADMAP"

  [ "$rows" -eq "$PHASE_COUNT" ] ||
    fail "expected $PHASE_COUNT roadmap rows, found $rows"
  [ "$expected" -eq $((LAST_PHASE + 1)) ] ||
    fail "roadmap phases must be contiguous from $FIRST_PHASE through $LAST_PHASE"

  refs=$(
    {
      grep -E -o "data-roadmap-phase[[:space:]]*=[[:space:]]*['\"][0-9][0-9]*['\"]" \
        "$README" 2>/dev/null |
        sed 's/[^0-9]//g' || :
      grep -o 'label%3Aphase-[0-9][0-9]*' "$README" 2>/dev/null |
        sed 's/.*phase-//' || :
      if [ -d "$SITE" ]; then
        find "$SITE" -type f -exec grep -h -E -o \
          "data-roadmap-phase[[:space:]]*=[[:space:]]*['\"][0-9][0-9]*['\"]" \
          {} + 2>/dev/null |
          sed 's/[^0-9]//g' || :
        find "$SITE" -type f -exec grep -h -o 'label%3Aphase-[0-9][0-9]*' {} + 2>/dev/null |
          sed 's/.*phase-//' || :
      fi
    } |
      sort -u
  )
  for ref in $refs; do
    grep -F "${ref}${TAB}" "$ROADMAP" >/dev/null 2>&1 ||
      fail "data-roadmap-phase=\"$ref\" is not defined in docs/roadmap.tsv"
  done

  printf 'roadmap: phases %s..%s and public roadmap references are valid\n' \
    "$FIRST_PHASE" "$LAST_PHASE"
}

repo_from_git() {
  remote=$(git -C "$ROOT" remote get-url origin 2>/dev/null || :)
  case "$remote" in
    https://github.com/*) repo=${remote#https://github.com/} ;;
    http://github.com/*) repo=${remote#http://github.com/} ;;
    git@github.com:*) repo=${remote#git@github.com:} ;;
    ssh://git@github.com/*) repo=${remote#ssh://git@github.com/} ;;
    *) repo= ;;
  esac
  repo=${repo%.git}
  printf '%s' "$repo"
}

resolve_repo() {
  repo=${ROADMAP_REPO:-}
  if [ -z "$repo" ]; then
    repo=$(repo_from_git)
  fi
  if [ -z "$repo" ] && command -v gh >/dev/null 2>&1; then
    repo=$(gh repo view --json nameWithOwner --template '{{.nameWithOwner}}' 2>/dev/null || :)
  fi
  case "$repo" in
    */*) ;;
    *) fail "could not determine GitHub repo; set ROADMAP_REPO=owner/name" ;;
  esac
  owner=${repo%%/*}
  name=${repo#*/}
  [ -n "$owner" ] && [ -n "$name" ] || fail "invalid GitHub repo: $repo"
  case "$name" in */*) fail "invalid GitHub repo: $repo" ;; esac
  printf '%s' "$repo"
}

find_milestone() {
  repo=$1
  matches=$(gh api --paginate "repos/$repo/milestones?state=all&per_page=100" \
    --template '{{range .}}{{if eq .title "Purity-compatible Bun parity"}}{{printf "%v\t%s\n" .number .state}}{{end}}{{end}}')
  count=0
  number=
  while IFS="$TAB" read -r found_number _found_state; do
    [ -n "$found_number" ] || continue
    count=$((count + 1))
    number=$found_number
  done <<EOF
$matches
EOF
  [ "$count" -le 1 ] || fail "multiple '$MILESTONE' milestones found in $repo"
  [ "$count" -eq 1 ] && printf '%s' "$number"
  return 0
}

ensure_milestone() {
  repo=$1
  number=$2
  if [ -z "$number" ]; then
    gh api --method POST "repos/$repo/milestones" \
      -f title="$MILESTONE" \
      -f description="Canonical purity-compatible Bun parity roadmap for Clun phases $FIRST_PHASE through $LAST_PHASE." >/dev/null
    printf 'roadmap: created milestone %s\n' "$MILESTONE"
  else
    gh api --method PATCH "repos/$repo/milestones/$number" \
      -f title="$MILESTONE" \
      -f state=open \
      -f description="Canonical purity-compatible Bun parity roadmap for Clun phases $FIRST_PHASE through $LAST_PHASE." >/dev/null
    printf 'roadmap: ensured milestone %s\n' "$MILESTONE"
  fi
}

ensure_label() {
  repo=$1
  label=$2
  color=$3
  description=$4
  gh label create "$label" --repo "$repo" --color "$color" \
    --description "$description" --force >/dev/null
}

find_issue() {
  issue_cache=$1
  phase=$2
  phase_label=$3
  title_prefix="Phase $phase:"

  label_count=0
  label_number=
  label_title=
  title_count=0
  title_number=
  while IFS="$TAB" read -r candidate candidate_title candidate_labels candidate_state candidate_milestone extra; do
    [ -n "$candidate" ] || continue
    [ -z "$extra" ] || fail "could not parse cached GitHub issue #$candidate"
    case "$candidate_state" in
      open|closed) ;;
      *) fail "cached GitHub issue #$candidate has invalid state: $candidate_state" ;;
    esac
    [ -n "$candidate_milestone" ] ||
      fail "cached GitHub issue #$candidate has no milestone sentinel"
    case ",$candidate_labels" in
      *",$phase_label,"*)
        label_count=$((label_count + 1))
        label_number=$candidate
        label_title=$candidate_title
        ;;
    esac
    case "$candidate_title" in
      "$title_prefix"*)
        title_count=$((title_count + 1))
        title_number=$candidate
        ;;
    esac
  done <"$issue_cache"
  [ "$label_count" -le 1 ] || fail "multiple issues carry unique label $phase_label"
  [ "$title_count" -le 1 ] || fail "multiple issues have title prefix: $title_prefix"
  if [ -n "$label_number" ]; then
    case "$label_title" in
      "$title_prefix"*) ;;
      *) fail "$phase_label belongs to unexpected issue title: $label_title" ;;
    esac
  fi
  if [ -n "$label_number" ] && [ -n "$title_number" ] &&
     [ "$label_number" != "$title_number" ]; then
    fail "$phase_label and $title_prefix identify different issues"
  fi
  if [ -n "$label_number" ]; then
    printf '%s' "$label_number"
  elif [ -n "$title_number" ]; then
    printf '%s' "$title_number"
  fi
}

write_contract_block() (
  repo=$1
  phase=$2
  slug=$3
  track=$4
  body_file=$5
  plan_url="https://github.com/$repo/blob/master/PLAN.md"
  ledger_url="https://github.com/$repo/blob/master/docs/roadmap.tsv"
  bun_url="https://github.com/oven-sh/bun/tree/$BUN_PIN"

  # shellcheck disable=SC2016
  {
    printf '%s\n' "$CONTRACT_BEGIN"
    printf '> [!NOTE]\n'
    printf '> Generated technical contract from [`docs/roadmap.tsv`](%s) and [`PLAN.md`](%s). `scripts/roadmap.sh sync` updates only this marked block; keep live status, checklists, decisions, and evidence outside it.\n' "$ledger_url" "$plan_url"
    printf '\n**Track:** `%s`  \n' "$track"
    printf '**Ledger slug:** `%s`  \n' "$slug"
    printf '**Pinned Bun reference:** Bun `%s` at commit [`%s`](%s)\n' \
      "$BUN_VERSION" "$BUN_PIN" "$bun_url"
    printf '\n## Generated technical contract\n\n'
    extract_phase_section "$phase"
    printf '%s\n' "$CONTRACT_END"
  } > "$body_file"
)

write_legacy_prefix() (
  repo=$1
  slug=$2
  track=$3
  output=$4
  plan_url="https://github.com/$repo/blob/master/PLAN.md"
  ledger_url="https://github.com/$repo/blob/master/docs/roadmap.tsv"
  bun_url="https://github.com/oven-sh/bun/tree/$BUN_PIN"

  # shellcheck disable=SC2016
  {
    printf '> [!WARNING]\n'
    printf '> Generated from [`docs/roadmap.tsv`](%s) and the matching [`PLAN.md`](%s) section. Do not edit this body manually; run `scripts/roadmap.sh sync`.\n' "$ledger_url" "$plan_url"
    printf '\n**Track:** `%s`  \n' "$track"
    printf '**Ledger slug:** `%s`  \n' "$slug"
    printf '**Pinned Bun reference:** Bun `%s` at commit [`%s`](%s)\n' \
      "$BUN_VERSION" "$BUN_PIN" "$bun_url"
    printf '\n## Canonical phase specification\n\n'
  } > "$output"
)

write_legacy_suffix() (
  output=$1
  # shellcheck disable=SC2016
  {
    printf '## Execution checklist\n\n'
    printf '%s\n' '- [ ] Design is written and accepted before non-trivial implementation.'
    printf '%s\n' '- [ ] Implementation is complete within the phase scope.'
    printf '%s\n' '- [ ] Tests and reproducible evidence cover every acceptance item.'
    printf '%s\n' '- [ ] Adversarial review findings are resolved or explicitly recorded.'
    printf '%s\n' '- [ ] Documentation, compatibility ledger, site, and README are synchronized.'
    printf '%s\n' '- [ ] The exact phase gate passes.'
    printf '\n## Purity and evidence rules\n\n'
    printf '%s\n' '- Honor the current purity contract. A constitutional-checkpoint phase must record an operator-approved contract amendment before using any exception.'
    printf '%s\n' '- Keep JavaScript and TypeScript in fixtures/user programs, not the implementation, unless the approved contract explicitly changes.'
    printf '%s\n' '- Every completed checklist item needs code, test, command, or measured-result evidence; unsupported and unmeasured claims remain visibly partial or absent.'
    printf '%s\n' '- Performance comparisons require committed, reproducible, same-workload evidence with environment and methodology recorded.'
    printf '%s\n' '- Run `make purity` and the phase-specific acceptance gate before completion.'
  } > "$output"
)

write_legacy_body() (
  repo=$1
  phase=$2
  slug=$3
  track=$4
  output=$5
  scratch=$6
  prefix="$scratch/expected-legacy-prefix.md"
  suffix="$scratch/expected-legacy-suffix.md"
  write_legacy_prefix "$repo" "$slug" "$track" "$prefix"
  write_legacy_suffix "$suffix"
  {
    cat "$prefix"
    extract_phase_section "$phase"
    printf '\n'
    cat "$suffix"
  } > "$output"
)

write_live_header() (
  output=$1
  {
    printf '# Canonical live phase record\n\n'
    printf '%s\n' 'This issue is the canonical source of truth for live scope, status, blockers, decisions, measured evidence, and completion.'
    printf '%s\n' 'The marked technical-contract block is generated from the repository; maintain live progress outside that block and in substantive issue comments.'
    printf '\n## Current status\n\n'
    printf '%s\n\n' '**Phase status:** `not-started`'
    printf 'Not started.\n\n'
    printf '## Release disposition\n\n'
    printf '%s\n' "**SemVer impact:** \`unassigned\`  "
    printf '%s\n' "**SemVer rationale:** \`unassigned\`  "
    printf '%s\n' "**Release version:** \`unassigned\`  "
    printf '%s\n\n' "**Release tag:** \`unassigned\`"
  } > "$output"
)

write_evidence_tail() (
  output=$1
  {
    printf '\n## Decisions and evidence\n\n'
    printf '%s\n' 'Record implementation decisions, diagnosed residuals, gate results, commit hashes, and deployment status here or in substantive issue comments.'
  } > "$output"
)

marker_line() (
  file=$1
  marker=$2
  count=$(grep -F -x -c "$marker" "$file" 2>/dev/null || :)
  [ "$count" -eq 1 ] || return 1
  grep -F -x -n "$marker" "$file" | cut -d: -f1
)

replace_marked_contract() (
  existing=$1
  contract=$2
  output=$3
  begin=$(marker_line "$existing" "$CONTRACT_BEGIN") ||
    fail "marked issue body must contain exactly one contract begin marker"
  end=$(marker_line "$existing" "$CONTRACT_END") ||
    fail "marked issue body must contain exactly one contract end marker"
  [ "$begin" -lt "$end" ] || fail "contract markers are out of order"

  before=$((begin - 1))
  after=$((end + 1))
  : > "$output"
  if [ "$before" -gt 0 ]; then
    head -n "$before" "$existing" >> "$output"
  fi
  cat "$contract" >> "$output"
  tail -n "+$after" "$existing" >> "$output"
)

migrate_legacy_body() (
  repo=$1
  phase=$2
  slug=$3
  track=$4
  existing=$5
  contract=$6
  output=$7
  scratch=$8

  expected_legacy="$scratch/expected-legacy.md"
  normalized_legacy="$scratch/normalized-legacy.md"
  actual_suffix="$scratch/actual-suffix.md"
  live_header="$scratch/live-header.md"
  evidence_tail="$scratch/evidence-tail.md"

  write_legacy_body "$repo" "$phase" "$slug" "$track" "$expected_legacy" "$scratch"
  sed 's/^- \[[xX]\]/- [ ]/' "$existing" > "$normalized_legacy"
  cmp -s "$expected_legacy" "$normalized_legacy" ||
    fail "unmarked issue body for Phase $phase differs from the known generated body; refusing to overwrite it"

  checklist_lines=$(grep -F -x -n '## Execution checklist' "$existing" 2>/dev/null || :)
  checklist_count=$(printf '%s\n' "$checklist_lines" | awk 'NF { count++ } END { print count + 0 }')
  [ "$checklist_count" -eq 1 ] ||
    fail "unmarked issue body for Phase $phase is not the known generated format (checklist)"
  checklist_line=$(printf '%s\n' "$checklist_lines" | cut -d: -f1)
  tail -n "+$checklist_line" "$existing" > "$actual_suffix"

  write_live_header "$live_header"
  write_evidence_tail "$evidence_tail"
  {
    cat "$live_header"
    cat "$contract"
    printf '\n'
    cat "$actual_suffix"
    cat "$evidence_tail"
  } > "$output"
)

prepare_issue_body() (
  repo=$1
  phase=$2
  slug=$3
  track=$4
  existing=$5
  contract=$6
  output=$7
  scratch=$8
  begin_count=$(grep -F -x -c "$CONTRACT_BEGIN" "$existing" 2>/dev/null || :)
  end_count=$(grep -F -x -c "$CONTRACT_END" "$existing" 2>/dev/null || :)

  if [ "$begin_count" -eq 1 ] && [ "$end_count" -eq 1 ]; then
    replace_marked_contract "$existing" "$contract" "$output"
  elif [ "$begin_count" -eq 0 ] && [ "$end_count" -eq 0 ]; then
    migrate_legacy_body "$repo" "$phase" "$slug" "$track" \
      "$existing" "$contract" "$output" "$scratch"
  else
    fail "issue body for Phase $phase has incomplete or duplicate contract markers"
  fi
)

write_new_issue_body() (
  contract=$1
  output=$2
  scratch=$3
  live_header="$scratch/live-header.md"
  legacy_suffix="$scratch/legacy-suffix.md"
  evidence_tail="$scratch/evidence-tail.md"
  write_live_header "$live_header"
  write_legacy_suffix "$legacy_suffix"
  write_evidence_tail "$evidence_tail"
  {
    cat "$live_header"
    cat "$contract"
    printf '\n'
    cat "$legacy_suffix"
    cat "$evidence_tail"
  } > "$output"
)

fetch_issue_cache() (
  repo=$1
  output=$2
  gh api --paginate "repos/$repo/issues?state=all&per_page=100" \
    --jq '.[] | select(.pull_request == null) | [(.number | tostring), .title, (if (.labels | length) == 0 then "-" else ([.labels[].name] | join(",")) end), .state, (.milestone.title // "-")] | @tsv' \
    > "$output"
)

fetch_issue_body() (
  repo=$1
  issue_number=$2
  output=$3
  # Go-template output preserves the stored body byte-for-byte; --jq appends a newline.
  gh issue view "$issue_number" --repo "$repo" --json body --template '{{.body}}' > "$output"
)

cached_issue_title() (
  issue_cache=$1
  issue_number=$2
  awk -F "$TAB" -v target="$issue_number" '
    $1 == target { print $2; found++ }
    END { if (found != 1) exit 2 }
  ' "$issue_cache"
)

cached_issue_has_label() (
  issue_cache=$1
  issue_number=$2
  wanted=$3
  awk -F "$TAB" -v target="$issue_number" -v label="$wanted" '
    $1 == target {
      found++
      count = split($3, labels, ",")
      for (i = 1; i <= count; i++) if (labels[i] == label) matched = 1
    }
    END { if (found != 1 || !matched) exit 2 }
  ' "$issue_cache"
)

cached_issue_state() (
  issue_cache=$1
  issue_number=$2
  awk -F "$TAB" -v target="$issue_number" '
    $1 == target { print $4; found++ }
    END { if (found != 1) exit 2 }
  ' "$issue_cache"
)

cached_issue_milestone() (
  issue_cache=$1
  issue_number=$2
  awk -F "$TAB" -v target="$issue_number" '
    $1 == target { print $5; found++ }
    END { if (found != 1) exit 2 }
  ' "$issue_cache"
)

verify_generated_live_sections() (
  body=$1
  phase=$2
  issue_number=$3
  issue_state=$4
  for heading in '# Canonical live phase record' '## Current status' \
                 '## Release disposition' '## Execution checklist' \
                 '## Decisions and evidence'; do
    count=$(grep -F -x -c "$heading" "$body" 2>/dev/null || :)
    [ "$count" -eq 1 ] ||
      fail "Phase $phase issue #$issue_number must contain exactly one $heading heading"
  done
  for field in 'SemVer impact' 'SemVer rationale' 'Release version' 'Release tag'; do
    count=$(grep -E -c "^\\*\\*$field:\\*\\*[[:space:]]+[^[:space:]].*" "$body" 2>/dev/null || :)
    [ "$count" -eq 1 ] ||
      fail "Phase $phase issue #$issue_number must contain exactly one nonempty $field field"
  done
  phase_status_count=$(grep -E -c '^\*\*Phase status:\*\* `(not-started|in-progress|blocked|complete)`$' \
    "$body" 2>/dev/null || :)
  [ "$phase_status_count" -eq 1 ] ||
    fail "Phase $phase issue #$issue_number must contain exactly one valid Phase status field"
  phase_status=$(sed -n 's/^\*\*Phase status:\*\* `\([^`]*\)`$/\1/p' "$body")
  case "$issue_state:$phase_status" in
    open:not-started|open:in-progress|open:blocked|closed:complete) ;;
    *) fail "Phase $phase issue #$issue_number state $issue_state disagrees with Phase status $phase_status" ;;
  esac
  case "$phase_status" in
    in-progress|complete)
      verify_assigned_release_disposition "$body" "$phase" "$issue_number"
      ;;
  esac
  if [ "$phase_status" = complete ]; then
    checklist=$(awk '
      $0 == "## Execution checklist" { active = 1; next }
      active && /^## / { exit }
      active { print }
    ' "$body")
    checked=$(printf '%s\n' "$checklist" | grep -E -c '^- \[x\] ' 2>/dev/null || :)
    unchecked=$(printf '%s\n' "$checklist" | grep -E -c '^- \[ \] ' 2>/dev/null || :)
    [ "$checked" -ge 6 ] && [ "$unchecked" -eq 0 ] ||
      fail "completed Phase $phase issue #$issue_number must have every execution checklist item checked"
  fi
)

extract_marked_contract() (
  body=$1
  output=$2
  begin=$(marker_line "$body" "$CONTRACT_BEGIN") ||
    fail "live issue body must contain exactly one contract begin marker"
  end=$(marker_line "$body" "$CONTRACT_END") ||
    fail "live issue body must contain exactly one contract end marker"
  [ "$begin" -lt "$end" ] || fail "live contract markers are out of order"
  sed -n "${begin},${end}p" "$body" > "$output"
)

extract_phase25b_public_ref() (
  file=$1
  repo=$2
  issue_prefix="https://github.com/$repo/issues/"
  awk -v issue_prefix="$issue_prefix" '
    index($0, issue_prefix) && $0 ~ /Phase 25b milestone [0-9]+/ {
      line = $0
      while (match(line, /Phase 25b milestone [0-9]+/)) {
        value = substr(line, RSTART, RLENGTH)
        sub(/^Phase 25b milestone /, "", value)
        if (milestone != "" && milestone != value) conflict = 1
        milestone = value
        line = substr(line, RSTART + RLENGTH)
      }

      line = $0
      while ((position = index(line, issue_prefix)) != 0) {
        line = substr(line, position + length(issue_prefix))
        if (match(line, /^[0-9]+/)) {
          value = substr(line, RSTART, RLENGTH)
          if (issue != "" && issue != value) conflict = 1
          issue = value
          line = substr(line, RLENGTH + 1)
        } else {
          line = substr(line, 2)
        }
      }
    }
    END {
      if (issue == "" || milestone == "" || conflict) exit 2
      printf "%s\t%s\n", issue, milestone
    }
  ' "$file"
)

verify_phase25b_reference() (
  repo=$1
  issue_cache=$2
  scratch=$3
  readme_ref=$(extract_phase25b_public_ref "$README" "$repo") ||
    fail "README.md must link the current Phase 25b issue beside one milestone marker"
  site_ref=$(extract_phase25b_public_ref "$SITE/index.html" "$repo") ||
    fail "site/index.html must link the current Phase 25b issue beside one milestone marker"
  [ "$readme_ref" = "$site_ref" ] ||
    fail "README and site point to different Phase 25b issue or milestone records"

  IFS="$TAB" read -r issue_number milestone extra <<EOF
$readme_ref
EOF
  [ -z "$extra" ] && [ -n "$issue_number" ] && [ -n "$milestone" ] ||
    fail "could not parse the public Phase 25b reference"

  canonical_issue=$(find_issue "$issue_cache" 25b phase-25b)
  [ -n "$canonical_issue" ] || fail "no canonical phase-25b issue found"
  [ "$canonical_issue" = "$issue_number" ] ||
    fail "public Phase 25b link points to #$issue_number, canonical label/title identify #$canonical_issue"
  issue_state=$(cached_issue_state "$issue_cache" "$issue_number") ||
    fail "could not read state for Phase 25b issue #$issue_number"
  [ "$issue_state" = open ] ||
    fail "Phase 25b issue #$issue_number must remain open until the 90% phase gate is complete"

  body="$scratch/phase-25b-body.md"
  fetch_issue_body "$repo" "$issue_number" "$body"
  [ "$(grep -F -x -c '**Phase status:** `in-progress`' "$body" 2>/dev/null || :)" -eq 1 ] ||
    fail "Phase 25b issue #$issue_number must record Phase status in-progress"
  current_count=$(grep -E -x -c '## Current milestone: m[0-9]+' "$body" 2>/dev/null || :)
  [ "$current_count" -eq 1 ] ||
    fail "Phase 25b issue #$issue_number must contain exactly one current milestone heading"
  grep -F -x "## Current milestone: m$milestone" "$body" >/dev/null 2>&1 ||
    fail "public Phase 25b milestone $milestone disagrees with issue #$issue_number"

  source_versions=$(sed -n 's/^(defparameter \*clun-version\* "\([^"]*\)".*/\1/p' "$VERSION_FILE")
  source_version_count=$(printf '%s\n' "$source_versions" |
    awk 'NF { count++ } END { print count + 0 }')
  [ "$source_version_count" -eq 1 ] ||
    fail "src/version.lisp must contain exactly one release version"
  source_version=$(printf '%s\n' "$source_versions" | sed -n '1p')
  impact_line="**SemVer impact:** \`minor\`"
  impact_field_count=$(grep -E -c '^\*\*SemVer impact:\*\*' "$body" 2>/dev/null || :)
  [ "$impact_field_count" -eq 1 ] ||
    fail "Phase 25b issue #$issue_number must contain exactly one SemVer impact field"
  [ "$(grep -F -x -c "$impact_line" "$body" 2>/dev/null || :)" -eq 1 ] ||
    fail "Phase 25b issue #$issue_number must contain exactly: $impact_line"

  rationale_field_count=$(grep -E -c '^\*\*SemVer rationale:\*\*' "$body" 2>/dev/null || :)
  [ "$rationale_field_count" -eq 1 ] ||
    fail "Phase 25b issue #$issue_number must contain exactly one SemVer rationale field"
  rationale=$(sed -n 's/^\*\*SemVer rationale:\*\*[[:space:]]*//p' "$body" |
    sed 's/[[:space:]]*$//')
  case "$rationale" in
    ''|'unassigned'|'`unassigned`')
      fail "Phase 25b issue #$issue_number must contain a nonempty SemVer rationale" ;;
  esac

  release_line=$(printf "**Release version:** \`%s\`" "$source_version")
  release_field_count=$(grep -E -c '^\*\*Release version:\*\*' "$body" 2>/dev/null || :)
  [ "$release_field_count" -eq 1 ] ||
    fail "Phase 25b issue #$issue_number must contain exactly one release version field"
  [ "$(grep -F -x -c "$release_line" "$body" 2>/dev/null || :)" -eq 1 ] ||
    fail "Phase 25b issue #$issue_number must contain exactly: $release_line"

  tag_line=$(printf "**Release tag:** \`v%s\`" "$source_version")
  tag_field_count=$(grep -E -c '^\*\*Release tag:\*\*' "$body" 2>/dev/null || :)
  [ "$tag_field_count" -eq 1 ] ||
    fail "Phase 25b issue #$issue_number must contain exactly one release tag field"
  [ "$(grep -F -x -c "$tag_line" "$body" 2>/dev/null || :)" -eq 1 ] ||
    fail "Phase 25b issue #$issue_number must contain exactly: $tag_line"

  report_pass=$(report_measure Pass)
  report_fail=$(report_measure Fail)
  report_skip=$(report_measure Skip)
  report_crash=$(report_measure Crash)
  report_eligible=$(report_measure 'Eligible (`pass + fail`)')
  report_lift=$(report_measure 'Required pass lift')
  phase25b_rows=$(report_measure '`phase-25b`')
  phase37_rows=$(report_measure '`phase-37`')
  for value in "$report_pass" "$report_fail" "$report_skip" "$report_crash" \
               "$report_eligible" "$report_lift" "$phase25b_rows" "$phase37_rows"; do
    case "$value" in
      ''|*[!0-9]*) fail "execution report contains a non-integer Phase 25b measure: $value" ;;
    esac
  done
  report_rate_exact=$(awk -v pass="$report_pass" -v eligible="$report_eligible" \
    'BEGIN { printf "%.6f", (pass * 100) / eligible }')
  report_rate=$(awk -v pass="$report_pass" -v eligible="$report_eligible" '
    BEGIN {
      scaled = int((pass * 10000) / eligible)
      printf "%d.%02d", int(scaled / 100), scaled % 100
    }
  ')
  pretty_pass=$(format_count "$report_pass")
  pretty_fail=$(format_count "$report_fail")
  pretty_skip=$(format_count "$report_skip")
  pretty_lift=$(format_count "$report_lift")
  pretty_phase25b=$(format_count "$phase25b_rows")
  pretty_phase37=$(format_count "$phase37_rows")
  ledger_line="- Current ledger: $pretty_pass pass / $pretty_fail fail / $pretty_skip skip / $report_crash crash"
  rate_line="- Exact current rate: $report_rate_exact%; public two-decimal value: $report_rate%"
  lift_line="- Remaining lift: $pretty_lift live passes"
  owner_line="- Remaining ownership: $pretty_phase25b Phase-25b / $pretty_phase37 Phase-37 gaps"
  for expected_line in "$ledger_line" "$rate_line" "$lift_line" "$owner_line"; do
    [ "$(grep -F -x -c -- "$expected_line" "$body" 2>/dev/null || :)" -eq 1 ] ||
      fail "Phase 25b issue #$issue_number measured evidence must contain exactly: $expected_line"
  done
  for expected_text in \
    'Exact six-directory slice: 181 files, 15 unchanged static skips, and 166 runnable controls.' \
    'All 162 m2-owned controls pass.' \
    'built-ins/Object/seal/seal-finalizationregistry.js' \
    'built-ins/Object/seal/seal-weakref.js' \
    'built-ins/Object/seal/seal-proxy.js' \
    'built-ins/Object/seal/throws-when-false.js' \
    'Focused m3 slice: 1,497 total / 1,442 pass / 55 fail / 0 skip / 0 crash.' \
    'Residual ownership: m4 28 / m7 4 / m11 19 / Phase 37 4.' \
    'Focused m4 slice: 430 total / 366 pass / 64 fail / 0 skip / 0 crash.' \
    '`functions-arguments`: 169 pass / 44 fail.' \
    '`classes`: 169 pass / 8 fail.' \
    'm3-origin binding dependencies: 28 pass / 0 fail.' \
    'Same-bucket Phase-37 controls: 0 pass / 12 fail.' \
    'Residual ownership: m7 2 / m11 46 / m13 1 / m14 2 / Phase 37 13 / m4 0.' \
    'Pass-list gain from milestone 3: 504; gain from phase entry: 2,365.' \
    'Canonical artifact digest: `B77552A66955B6C3`.' \
    'Off/eager ledgers are byte-identical; eager compiled 1,020,917 forms, classified 54,315 as ineligible, and fell back 0 times.' \
    'Parse gate: 23,713 total / 17,688 pass / 987 fail / 5,038 skip / 0 crash; all 17,512 frozen parser passes hold.' \
    '`make test-lisp`: 3,120 pass / 0 fail.' \
    'Pass-list gain from milestone 4: 43; gain from phase entry: 2,408.' \
    'Canonical artifact digest: `C104919DBAF109E4`.' \
    'Full off/eager ledgers are byte-identical; eager compiled 1,021,895 forms, classified 54,494 as ineligible, fell back 0 times, and executed 0 interpreter fallbacks.' \
    'Parse gate: 23,713 total / 17,699 pass / 976 fail / 5,038 skip / 0 crash; all 17,512 frozen parser passes hold.' \
    '`make test-lisp`: 3,187 pass / 0 fail.' \
    'Tracked fail-closed m5 gate: 56 total = 43 m5 pass / 12 m11 fail / 1 Phase-37 fail / 0 skip / 0 timeout / 0 crash; m5 has no owned residual.' \
    'Independent review corrected the sync/async raw-result boundary, module `await` context, inherited `GeneratorPrototype@@iterator` identity, exact close receiver, and bounded delegate teardown after repeated incomplete `return()` results.'; do
    grep -Fq "$expected_text" "$body" ||
      fail "Phase 25b issue #$issue_number is missing measured scope evidence: $expected_text"
  done

  m5_candidate='This is local candidate evidence only. No dev.5 tag, release assets, Pages deployment, or hosted-installer result is claimed yet; dev.4 remains the last published release.'
  if grep -Fq "$m5_candidate" "$body"; then
    for expected_text in \
      'Milestone-5 local release-candidate result:' \
      '**Last published release:** `0.1.0-dev.4` / `v0.1.0-dev.4`; all four native archives, checksums, Pages, and hosted installer are verified.'; do
      grep -Fq "$expected_text" "$body" ||
        fail "Phase 25b issue #$issue_number is missing m5 candidate evidence: $expected_text"
    done
    if grep -Fq 'Milestone-5 publication evidence:' "$body"; then
      fail "Phase 25b issue #$issue_number mixes m5 candidate and publication evidence"
    fi
  else
    for expected_text in \
      'Milestone-5 publication evidence:' \
      'published [`v0.1.0-dev.5`](https://github.com/theesfeld/clun/releases/tag/v0.1.0-dev.5) as a prerelease.' \
      'Assets: `clun-linux-x64.tar.gz`, `clun-linux-arm64.tar.gz`, `clun-darwin-x64.tar.gz`, `clun-darwin-arm64.tar.gz`, and `checksums.txt`;' \
      'deployed the dev.5 candidate-status page plus the release-gated installer after release assets existed.' \
      'installed binary reported `clun 0.1.0-dev.5`.' \
      '**Post-publication handoff disposition:** impact `none`; source and release remain `0.1.0-dev.5`, no tag is created, and the handoff changes status evidence only.' \
      '**Last published release:** `0.1.0-dev.5` / `v0.1.0-dev.5`; all four native archives, checksums, the release-gated Pages installer, and hosted installer are verified.'; do
      grep -Fq "$expected_text" "$body" ||
        fail "Phase 25b issue #$issue_number is missing m5 publication evidence: $expected_text"
    done
  fi

  canonical_url="https://github.com/$repo/issues/$issue_number"
  [ "$(grep -F -x -c "**Canonical issue:** $canonical_url" "$STATE_FILE" 2>/dev/null || :)" -eq 1 ] ||
    fail "STATE.md must name the exact canonical Phase 25b issue URL"
  state_milestone_line=$(printf '**Current Phase 25b milestone:** `m%s`' "$milestone")
  [ "$(grep -F -x -c "$state_milestone_line" "$STATE_FILE" 2>/dev/null || :)" -eq 1 ] ||
    fail "STATE.md current Phase 25b milestone disagrees with issue #$issue_number"

  printf 'roadmap: Phase 25b public marker matches canonical issue #%s (m%s, v%s)\n' \
    "$issue_number" "$milestone" "$source_version"
)

verify_phase26_issue() (
  repo=$1
  issue_cache=$2
  scratch=$3
  issue_number=$(find_issue "$issue_cache" 26 "$PHASE26_LABEL")
  [ -n "$issue_number" ] || fail "no canonical Phase 26 issue found"

  actual_title=$(cached_issue_title "$issue_cache" "$issue_number") ||
    fail "could not read title for Phase 26 issue #$issue_number"
  [ "$actual_title" = "$PHASE26_TITLE" ] ||
    fail "Phase 26 issue #$issue_number title drift: $actual_title"
  cached_issue_has_label "$issue_cache" "$issue_number" "$PHASE26_LABEL" ||
    fail "Phase 26 issue #$issue_number is missing label $PHASE26_LABEL"

  issue_state=$(cached_issue_state "$issue_cache" "$issue_number") ||
    fail "could not read state for Phase 26 issue #$issue_number"
  [ "$issue_state" = open ] || fail "Phase 26 issue #$issue_number must remain open while planned"

  body="$scratch/phase-26-body.md"
  fetch_issue_body "$repo" "$issue_number" "$body"
  [ "$(grep -F -x -c '**Phase status:** `blocked`' "$body" 2>/dev/null || :)" -eq 1 ] ||
    fail "Phase 26 issue #$issue_number must record Phase status blocked while its dependency is open"
  marker_count=$(grep -F -x -c "$PHASE26_MARKER" "$body" 2>/dev/null || :)
  [ "$marker_count" -eq 1 ] ||
    fail "Phase 26 issue #$issue_number must contain exactly one canonical phase marker"
  header_count=$(grep -F -x -c "$PHASE26_HEADER" "$body" 2>/dev/null || :)
  [ "$header_count" -eq 1 ] ||
    fail "Phase 26 issue #$issue_number must contain exactly one canonical status header"

  phase_lines=$(grep -E -n '^### Phase 26([^0-9]|$)' "$PLAN" 2>/dev/null || :)
  phase_count=$(printf '%s\n' "$phase_lines" | awk 'NF { count++ } END { print count + 0 }')
  [ "$phase_count" -eq 1 ] || fail "PLAN.md must contain exactly one Phase 26 heading"
  phase_line=$(printf '%s\n' "$phase_lines" | cut -d: -f1)
  plan_reference="**Technical contract:** [PLAN.md Phase 26](https://github.com/$repo/blob/master/PLAN.md#L$phase_line)"
  reference_count=$(grep -F -x -c "$plan_reference" "$body" 2>/dev/null || :)
  [ "$reference_count" -eq 1 ] ||
    fail "Phase 26 issue #$issue_number must contain the exact master PLAN.md Phase 26 link"

  printf 'roadmap: verified canonical open Phase 26 issue #%s and PLAN.md link\n' "$issue_number"
)

verify_live_roadmap() {
  check_roadmap
  repo=$(resolve_repo)
  command -v gh >/dev/null 2>&1 || fail "gh is required for verify-live"
  gh auth status >/dev/null 2>&1 || fail "gh is not authenticated"

  verify_dir=$(mktemp -d "${TMPDIR:-/tmp}/clun-roadmap-verify.XXXXXX") ||
    fail "could not create temporary directory"
  trap 'rm -rf "$verify_dir"' 0
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  issue_cache="$verify_dir/issues.tsv"
  fetch_issue_cache "$repo" "$issue_cache"
  verified=0
  while IFS="$TAB" read -r phase slug title track extra; do
    [ "$phase" = phase ] && continue
    phase_label="phase-$phase"
    expected_title="Phase $phase: $title"
    issue_number=$(find_issue "$issue_cache" "$phase" "$phase_label")
    [ -n "$issue_number" ] || fail "no issue found for Phase $phase"
    actual_title=$(cached_issue_title "$issue_cache" "$issue_number") ||
      fail "could not read title for Phase $phase issue #$issue_number"
    [ "$actual_title" = "$expected_title" ] ||
      fail "Phase $phase issue #$issue_number title drift: $actual_title"
    cached_issue_has_label "$issue_cache" "$issue_number" roadmap ||
      fail "Phase $phase issue #$issue_number is missing label roadmap"
    cached_issue_has_label "$issue_cache" "$issue_number" "$phase_label" ||
      fail "Phase $phase issue #$issue_number is missing label $phase_label"
    issue_state=$(cached_issue_state "$issue_cache" "$issue_number") ||
      fail "could not read state for Phase $phase issue #$issue_number"
    issue_milestone=$(cached_issue_milestone "$issue_cache" "$issue_number") ||
      fail "could not read milestone for Phase $phase issue #$issue_number"
    [ "$issue_milestone" = "$MILESTONE" ] ||
      fail "Phase $phase issue #$issue_number must belong to milestone $MILESTONE"

    body="$verify_dir/body-$phase.md"
    expected_contract="$verify_dir/contract-$phase.md"
    actual_contract="$verify_dir/actual-contract-$phase.md"
    fetch_issue_body "$repo" "$issue_number" "$body"
    write_contract_block "$repo" "$phase" "$slug" "$track" "$expected_contract"
    extract_marked_contract "$body" "$actual_contract"
    cmp -s "$expected_contract" "$actual_contract" ||
      fail "Phase $phase issue #$issue_number technical contract differs from PLAN.md/docs/roadmap.tsv"
    verify_generated_live_sections "$body" "$phase" "$issue_number" "$issue_state"
    verified=$((verified + 1))
  done < "$ROADMAP"

  [ "$verified" -eq "$PHASE_COUNT" ] ||
    fail "expected to verify $PHASE_COUNT live roadmap issues, verified $verified"
  verify_phase26_issue "$repo" "$issue_cache" "$verify_dir"
  verify_phase25b_reference "$repo" "$issue_cache" "$verify_dir"
  printf 'roadmap: verified %s generated phase issues, Phase 26, and exact live contracts in %s\n' \
    "$verified" "$repo"

  rm -rf "$verify_dir"
  trap - 0 HUP INT TERM
}

sync_roadmap() {
  dry_run=$1
  check_roadmap
  repo=$(resolve_repo)

  command -v gh >/dev/null 2>&1 || fail "gh is required for sync"
  gh auth status >/dev/null 2>&1 || fail "gh is not authenticated"

  sync_dir=$(mktemp -d "${TMPDIR:-/tmp}/clun-roadmap.XXXXXX") ||
    fail "could not create temporary directory"
  trap 'rm -rf "$sync_dir"' 0
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  issue_cache="$sync_dir/issues.tsv"
  fetch_issue_cache "$repo" "$issue_cache"

  milestone_number=$(find_milestone "$repo")
  if [ "$dry_run" -eq 1 ]; then
    printf 'roadmap: live dry run for %s\n' "$repo"
    if [ -n "$milestone_number" ]; then
      printf 'roadmap: would update milestone #%s: %s\n' "$milestone_number" "$MILESTONE"
    else
      printf 'roadmap: would create milestone: %s\n' "$MILESTONE"
    fi
    printf 'roadmap: would ensure label: roadmap\n'
    while IFS="$TAB" read -r phase slug title track extra; do
      [ "$phase" = phase ] && continue
      phase_label="phase-$phase"
      issue_title="Phase $phase: $title"
      issue_number=$(find_issue "$issue_cache" "$phase" "$phase_label")
      if [ -n "$issue_number" ]; then
        contract_file="$sync_dir/contract-$phase.md"
        existing_file="$sync_dir/existing-$phase.md"
        merged_file="$sync_dir/merged-$phase.md"
        write_contract_block "$repo" "$phase" "$slug" "$track" "$contract_file"
        fetch_issue_body "$repo" "$issue_number" "$existing_file"
        legacy=0
        if ! grep -F -x "$CONTRACT_BEGIN" "$existing_file" >/dev/null 2>&1; then
          legacy=1
        fi
        prepare_issue_body "$repo" "$phase" "$slug" "$track" \
          "$existing_file" "$contract_file" "$merged_file" "$sync_dir"
        if [ "$legacy" -eq 1 ]; then
          action='migrate the known legacy body'
        elif cmp -s "$existing_file" "$merged_file"; then
          action='preserve the live body (technical contract is current)'
        else
          action='refresh only the marked technical contract'
        fi
        printf 'roadmap: would %s and reconcile #%s "%s" with labels roadmap,%s\n' \
          "$action" "$issue_number" "$issue_title" "$phase_label"
      else
        printf 'roadmap: would create "%s" with labels roadmap,%s\n' \
          "$issue_title" "$phase_label"
      fi
    done < "$ROADMAP"
    return
  fi

  # Validate and prepare every body before the first mutation. An unknown
  # unmarked body therefore aborts the whole sync instead of causing a partial migration.
  while IFS="$TAB" read -r phase slug title track extra; do
    [ "$phase" = phase ] && continue
    phase_label="phase-$phase"
    contract_file="$sync_dir/contract-$phase.md"
    body_file="$sync_dir/body-$phase.md"
    write_contract_block "$repo" "$phase" "$slug" "$track" "$contract_file"
    issue_number=$(find_issue "$issue_cache" "$phase" "$phase_label")
    if [ -n "$issue_number" ]; then
      existing_file="$sync_dir/existing-$phase.md"
      fetch_issue_body "$repo" "$issue_number" "$existing_file"
      prepare_issue_body "$repo" "$phase" "$slug" "$track" \
        "$existing_file" "$contract_file" "$body_file" "$sync_dir"
    else
      write_new_issue_body "$contract_file" "$body_file" "$sync_dir"
    fi
  done < "$ROADMAP"

  ensure_milestone "$repo" "$milestone_number"
  ensure_label "$repo" roadmap 0052CC 'Canonical Clun roadmap phase issue.'

  while IFS="$TAB" read -r phase slug title track extra; do
    [ "$phase" = phase ] && continue
    phase_label="phase-$phase"
    issue_title="Phase $phase: $title"
    ensure_label "$repo" "$phase_label" 5319E7 "Clun roadmap phase $phase."
    body_file="$sync_dir/body-$phase.md"
    issue_number=$(find_issue "$issue_cache" "$phase" "$phase_label")
    if [ -n "$issue_number" ]; then
      latest_file="$sync_dir/latest-$phase.md"
      fetch_issue_body "$repo" "$issue_number" "$latest_file"
      cmp -s "$sync_dir/existing-$phase.md" "$latest_file" ||
        fail "Phase $phase issue #$issue_number changed after sync preflight; refusing to overwrite live content"
      gh issue edit "$issue_number" --repo "$repo" --title "$issue_title" \
        --body-file "$body_file" --add-label roadmap --add-label "$phase_label" \
        --milestone "$MILESTONE" >/dev/null
      printf 'roadmap: updated #%s %s\n' "$issue_number" "$issue_title"
    else
      issue_url=$(gh issue create --repo "$repo" --title "$issue_title" \
        --body-file "$body_file" --label roadmap --label "$phase_label" \
        --milestone "$MILESTONE")
      printf 'roadmap: created %s (%s)\n' "$issue_title" "$issue_url"
    fi
  done < "$ROADMAP"

  rm -rf "$sync_dir"
  trap - 0 HUP INT TERM
}

command=${1:-}
dry_run=0
case "$command" in
  check)
    [ "$#" -eq 1 ] || usage
    check_roadmap
    ;;
  verify-live)
    [ "$#" -eq 1 ] || usage
    verify_live_roadmap
    ;;
  sync)
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --dry-run) dry_run=1 ;;
        *) usage ;;
      esac
      shift
    done
    sync_roadmap "$dry_run"
    ;;
  *) usage ;;
esac
