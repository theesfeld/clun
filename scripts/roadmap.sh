#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
ROOT=$(CDPATH='' cd "$SCRIPT_DIR/.." && pwd)
ROADMAP="$ROOT/docs/roadmap.tsv"
PLAN="$ROOT/PLAN.md"
README="$ROOT/README.md"
SITE="$ROOT/site"
BUN_PIN=c1076ce95e
BUN_VERSION=1.4.0-dev
MILESTONE="Purity-compatible Bun parity"
FIRST_PHASE=27
LAST_PHASE=82
PHASE_COUNT=56
TAB=$(printf '\t')

usage() {
  printf 'usage: %s check\n' "$0" >&2
  printf '       %s sync [--dry-run]\n' "$0" >&2
  exit 2
}

fail() {
  printf 'roadmap: error: %s\n' "$*" >&2
  exit 1
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
      -f description="Generated purity-compatible Bun parity roadmap for Clun phases $FIRST_PHASE through $LAST_PHASE." >/dev/null
    printf 'roadmap: created milestone %s\n' "$MILESTONE"
  else
    gh api --method PATCH "repos/$repo/milestones/$number" \
      -f title="$MILESTONE" \
      -f state=open \
      -f description="Generated purity-compatible Bun parity roadmap for Clun phases $FIRST_PHASE through $LAST_PHASE." >/dev/null
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
  while IFS="$TAB" read -r candidate candidate_title candidate_labels extra; do
    [ -n "$candidate" ] || continue
    [ -z "$extra" ] || fail "could not parse cached GitHub issue #$candidate"
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

write_issue_body() {
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
    printf '> [!WARNING]\n'
    printf '> Generated from [`docs/roadmap.tsv`](%s) and the matching [`PLAN.md`](%s) section. Do not edit this body manually; run `scripts/roadmap.sh sync`.\n' "$ledger_url" "$plan_url"
    printf '\n**Track:** `%s`  \n' "$track"
    printf '**Ledger slug:** `%s`  \n' "$slug"
    printf '**Pinned Bun reference:** Bun `%s` at commit [`%s`](%s)\n' \
      "$BUN_VERSION" "$BUN_PIN" "$bun_url"
    printf '\n## Canonical phase specification\n\n'
    extract_phase_section "$phase"
    printf '\n## Execution checklist\n\n'
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
  } > "$body_file"
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
  gh api --paginate "repos/$repo/issues?state=all&per_page=100" \
    --template '{{range .}}{{if not .pull_request}}{{printf "%v\t%s\t" .number .title}}{{range .labels}}{{printf "%s," .name}}{{end}}{{printf "\n"}}{{end}}{{end}}' \
    >"$issue_cache"

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
        printf 'roadmap: would update #%s "%s" with labels roadmap,%s\n' \
          "$issue_number" "$issue_title" "$phase_label"
      else
        printf 'roadmap: would create "%s" with labels roadmap,%s\n' \
          "$issue_title" "$phase_label"
      fi
    done < "$ROADMAP"
    return
  fi

  ensure_milestone "$repo" "$milestone_number"
  ensure_label "$repo" roadmap 0052CC 'Generated Clun roadmap issue.'

  body_file="$sync_dir/body.md"

  while IFS="$TAB" read -r phase slug title track extra; do
    [ "$phase" = phase ] && continue
    phase_label="phase-$phase"
    issue_title="Phase $phase: $title"
    ensure_label "$repo" "$phase_label" 5319E7 "Clun roadmap phase $phase."
    write_issue_body "$repo" "$phase" "$slug" "$track" "$body_file"
    issue_number=$(find_issue "$issue_cache" "$phase" "$phase_label")
    if [ -n "$issue_number" ]; then
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
