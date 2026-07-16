#!/bin/sh

set -eu

repo_root=${CLUN_VERSION_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}
cd "$repo_root"

fail() {
  printf 'version-transition-check: %s\n' "$*" >&2
  exit 1
}

extract_version() {
  version_source=$1
  version_label=$2
  extracted_versions=$(sed -n 's/^(defparameter \*clun-version\* "\([^"]*\)".*/\1/p' \
    "$version_source")
  extracted_count=$(printf '%s\n' "$extracted_versions" |
    awk 'NF { count++ } END { print count + 0 }')
  [ "$extracted_count" -eq 1 ] ||
    fail "$version_label must contain exactly one nonempty *clun-version*"
  printf '%s\n' "$extracted_versions" | sed -n '1p'
}

validate_semver() {
  candidate=$1
  candidate_label=$2
  semver_identifier='(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
  semver_pattern="^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-${semver_identifier}(\\.${semver_identifier})*)?(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?$"
  printf '%s\n' "$candidate" | LC_ALL=C grep -Eq "$semver_pattern" ||
    fail "$candidate_label is not strict SemVer: $candidate"
}

compare_uint() {
  LC_ALL=C awk -v left="$1" -v right="$2" '
    BEGIN {
      if (length(left) < length(right)) print -1
      else if (length(left) > length(right)) print 1
      else if ("x" left < "x" right) print -1
      else if ("x" left > "x" right) print 1
      else print 0
    }
  '
}

increment_uint() {
  LC_ALL=C awk -v value="$1" '
    BEGIN {
      result = ""
      carry = 1
      for (position = length(value); position > 0; position--) {
        digit = substr(value, position, 1) + carry
        if (digit == 10) {
          digit = 0
          carry = 1
        } else {
          carry = 0
        }
        result = digit result
      }
      if (carry) result = "1" result
      print result
    }
  '
}

prerelease_part() {
  without_build=${1%%+*}
  version_core=${without_build%%-*}
  if [ "$without_build" = "$version_core" ]; then
    printf '%s\n' ''
  else
    printf '%s\n' "${without_build#"$version_core"-}"
  fi
}

split_prerelease_sequence() {
  prerelease=$1
  case $prerelease in
    *.*)
      sequence_prefix=${prerelease%.*}
      sequence_number=${prerelease##*.}
      ;;
    *)
      sequence_prefix=
      sequence_number=$prerelease
      ;;
  esac
  case $sequence_number in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\t%s\n' "$sequence_prefix" "$sequence_number"
}

resolve_repository() {
  if [ -n "${CLUN_CANONICAL_REPOSITORY:-}" ]; then
    canonical_repo=$CLUN_CANONICAL_REPOSITORY
  elif [ -n "${GITHUB_REPOSITORY:-}" ]; then
    canonical_repo=$GITHUB_REPOSITORY
  else
    remote_url=$(git remote get-url origin 2>/dev/null || :)
    case $remote_url in
      https://github.com/*) canonical_repo=${remote_url#https://github.com/} ;;
      git@github.com:*) canonical_repo=${remote_url#git@github.com:} ;;
      ssh://git@github.com/*) canonical_repo=${remote_url#ssh://git@github.com/} ;;
      *) fail "could not determine GitHub repository; set CLUN_CANONICAL_REPOSITORY" ;;
    esac
    canonical_repo=${canonical_repo%.git}
  fi
  case $canonical_repo in
    *[!A-Za-z0-9_./-]*|*/*/*|/*|*/|'')
      fail "invalid GitHub repository: $canonical_repo"
      ;;
    */*) ;;
    *) fail "GitHub repository must be OWNER/REPO: $canonical_repo" ;;
  esac
}

read_disposition() {
  issue_body=$1

  marker_count=$(grep -E -x -c '# Canonical (status|live phase record)' \
    "$issue_body" 2>/dev/null || :)
  [ "$marker_count" -eq 1 ] ||
    fail "$canonical_ref must contain exactly one recognized canonical status heading"

  # The single-quoted expressions below match literal Markdown syntax.
  # shellcheck disable=SC2016
  impact_field_count=$(grep -E -c '^\*\*SemVer impact:\*\*' "$issue_body" 2>/dev/null || :)
  [ "$impact_field_count" -eq 1 ] ||
    fail "$canonical_ref must contain exactly one SemVer impact field"
  # shellcheck disable=SC2016
  issue_impacts=$(sed -n \
    's/^\*\*SemVer impact:\*\*[[:space:]]*`\([^`]*\)`[[:space:]]*$/\1/p' \
    "$issue_body")
  issue_impact_count=$(printf '%s\n' "$issue_impacts" |
    awk 'NF { count++ } END { print count + 0 }')
  [ "$issue_impact_count" -eq 1 ] ||
    fail "$canonical_ref must contain exactly one strict SemVer impact field"
  canonical_impact=$(printf '%s\n' "$issue_impacts" | sed -n '1p')
  case $canonical_impact in
    major|minor|patch|none) ;;
    *) fail "$canonical_ref contains an invalid SemVer impact: $canonical_impact" ;;
  esac

  # shellcheck disable=SC2016
  release_version_field_count=$(grep -E -c '^\*\*Release version:\*\*' \
    "$issue_body" 2>/dev/null || :)
  [ "$release_version_field_count" -eq 1 ] ||
    fail "$canonical_ref must contain exactly one release version field"
  # shellcheck disable=SC2016
  issue_versions=$(sed -n \
    's/^\*\*Release version:\*\*[[:space:]]*`\([^`]*\)`[[:space:]]*$/\1/p' \
    "$issue_body")
  release_version_count=$(printf '%s\n' "$issue_versions" |
    awk 'NF { count++ } END { print count + 0 }')
  [ "$release_version_count" -eq 1 ] ||
    fail "$canonical_ref must contain exactly one release version field"
  issue_version=$(printf '%s\n' "$issue_versions" | sed -n '1p')
  [ "$issue_version" = "$current_version" ] ||
    fail "$canonical_ref targets $issue_version instead of $current_version"

  # shellcheck disable=SC2016
  release_tag_field_count=$(grep -E -c '^\*\*Release tag:\*\*' \
    "$issue_body" 2>/dev/null || :)
  [ "$release_tag_field_count" -eq 1 ] ||
    fail "$canonical_ref must contain exactly one release tag field"
  # shellcheck disable=SC2016
  issue_tags=$(sed -n \
    's/^\*\*Release tag:\*\*[[:space:]]*`\([^`]*\)`[[:space:]]*$/\1/p' \
    "$issue_body")
  release_tag_count=$(printf '%s\n' "$issue_tags" |
    awk 'NF { count++ } END { print count + 0 }')
  [ "$release_tag_count" -eq 1 ] ||
    fail "$canonical_ref must contain exactly one release tag field"
  issue_tag=$(printf '%s\n' "$issue_tags" | sed -n '1p')
  [ "$issue_tag" = "v$current_version" ] ||
    fail "$canonical_ref targets tag $issue_tag instead of v$current_version"

  rationale_count=$(grep -E -c '^\*\*SemVer rationale:\*\*' "$issue_body" 2>/dev/null || :)
  [ "$rationale_count" -eq 1 ] ||
    fail "$canonical_ref must contain exactly one SemVer rationale field"
  rationale=$(sed -n 's/^\*\*SemVer rationale:\*\*[[:space:]]*//p' "$issue_body" |
    sed 's/[[:space:]]*$//')
  case $rationale in
    ''|unassigned|"\`unassigned\`")
      fail "$canonical_ref must contain a nonempty SemVer rationale"
      ;;
  esac
}

materialize_current_state() {
  current_state_file=$scratch_dir/current-state.md
  [ -f "$current_state_file" ] && return
  if [ "$include_dirty" -eq 1 ]; then
    [ -f STATE.md ] || fail "STATE.md does not exist in the worktree"
    cp STATE.md "$current_state_file"
  else
    git show "$head_sha:STATE.md" >"$current_state_file" 2>/dev/null ||
      fail "STATE.md does not exist at $head_sha"
  fi
}

load_canonical_disposition() {
  if [ -n "${CLUN_CANONICAL_ISSUE_BODY_FILE:-}" ]; then
    [ -f "$CLUN_CANONICAL_ISSUE_BODY_FILE" ] ||
      fail "canonical issue body does not exist: $CLUN_CANONICAL_ISSUE_BODY_FILE"
    canonical_ref=${CLUN_CANONICAL_ISSUE_REF:-canonical issue fixture}
    read_disposition "$CLUN_CANONICAL_ISSUE_BODY_FILE"
    return
  fi

  materialize_current_state
  canonical_refs=$(sed -n \
    's#^\*\*Canonical issue:\*\*[[:space:]]*https://github.com/\([^/[:space:]]*/[^/[:space:]]*\)/issues/\([0-9][0-9]*\)[[:space:]]*$#\1|\2#p' \
    "$current_state_file")
  canonical_ref_count=$(printf '%s\n' "$canonical_refs" |
    awk 'NF { count++ } END { print count + 0 }')
  [ "$canonical_ref_count" -eq 1 ] ||
    fail "STATE.md at the checked release unit must contain exactly one canonical issue URL"
  canonical_record=$(printf '%s\n' "$canonical_refs" | sed -n '1p')
  canonical_repo=$(printf '%s\n' "$canonical_record" | awk -F '|' '{ print $1 }')
  canonical_issue=$(printf '%s\n' "$canonical_record" | awk -F '|' '{ print $2 }')
  case $canonical_repo in
    *[!A-Za-z0-9_./-]*|*/*/*|/*|*/|'')
      fail "STATE.md contains an invalid canonical repository: $canonical_repo"
      ;;
    */*) ;;
    *) fail "STATE.md canonical repository must be OWNER/REPO" ;;
  esac
  case $canonical_issue in
    ''|*[!0-9]*) fail "STATE.md contains an invalid canonical issue number" ;;
  esac
  if [ -n "${GITHUB_REPOSITORY:-}" ] && [ "$GITHUB_REPOSITORY" != "$canonical_repo" ]; then
    fail "STATE.md canonical repository $canonical_repo disagrees with $GITHUB_REPOSITORY"
  fi
  if [ -n "${CLUN_CANONICAL_REPOSITORY:-}" ] &&
    [ "$CLUN_CANONICAL_REPOSITORY" != "$canonical_repo" ]; then
    fail "STATE.md canonical repository $canonical_repo disagrees with CLUN_CANONICAL_REPOSITORY"
  fi

  command -v "$gh_bin" >/dev/null 2>&1 ||
    fail "GitHub CLI is required to resolve the canonical issue: $gh_bin"
  canonical_state=$("$gh_bin" issue view "$canonical_issue" --repo "$canonical_repo" \
    --json state --jq .state) ||
    fail "could not read canonical issue #$canonical_issue state"
  case $canonical_state in
    OPEN|CLOSED) ;;
    *) fail "canonical issue #$canonical_issue has an invalid state: $canonical_state" ;;
  esac

  canonical_body=$scratch_dir/canonical-issue.md
  "$gh_bin" issue view "$canonical_issue" --repo "$canonical_repo" \
    --json body --jq .body >"$canonical_body" ||
    fail "could not read canonical issue #$canonical_issue"
  canonical_ref="canonical issue #$canonical_issue"
  read_disposition "$canonical_body"
}

remote_resource_exists() {
  endpoint=$1
  resource_label=$2
  resource_error=$scratch_dir/remote-resource-error
  if "$gh_bin" api "$endpoint" >/dev/null 2>"$resource_error"; then
    published_reason=$resource_label
    return 0
  fi
  if grep -Eq 'HTTP[[:space:]]+404|\(HTTP 404\)' "$resource_error"; then
    return 1
  fi
  remote_error=$(sed -n '1p' "$resource_error")
  fail "could not verify $resource_label: ${remote_error:-unknown GitHub API error}"
}

published_version_exists() {
  release_tag=v$current_version
  if git show-ref --verify --quiet "refs/tags/$release_tag"; then
    published_reason="local tag $release_tag"
    return 0
  fi

  resolve_repository
  command -v "$gh_bin" >/dev/null 2>&1 ||
    fail "GitHub CLI is required to prove $release_tag is unpublished: $gh_bin"
  if remote_resource_exists \
    "repos/$canonical_repo/releases/tags/$release_tag" \
    "GitHub release $release_tag"; then
    return 0
  fi
  if remote_resource_exists \
    "repos/$canonical_repo/git/ref/tags/$release_tag" \
    "remote tag $release_tag"; then
    return 0
  fi
  return 1
}

git rev-parse --git-dir >/dev/null 2>&1 ||
  fail "repository root is not a Git worktree: $repo_root"

scratch_parent=${TMPDIR:-/tmp}
[ -d "$scratch_parent" ] || scratch_parent=.
scratch_dir=$(mktemp -d "$scratch_parent/clun-version-transition.XXXXXX") ||
  fail "could not create a scratch directory"
trap 'rm -rf "$scratch_dir"' 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

gh_bin=${CLUN_GH_BIN:-gh}
if [ "${CLUN_INCLUDE_DIRTY+x}" = x ]; then
  include_dirty=$CLUN_INCLUDE_DIRTY
elif [ -n "${HEAD_SHA:-}${GITHUB_SHA:-}" ]; then
  include_dirty=0
else
  include_dirty=1
fi
case $include_dirty in
  0|1) ;;
  *) fail "CLUN_INCLUDE_DIRTY must be 0 or 1" ;;
esac

head_sha=${HEAD_SHA:-${GITHUB_SHA:-HEAD}}
git cat-file -e "$head_sha^{commit}" 2>/dev/null ||
  fail "head commit is unavailable: $head_sha"

base_sha=${BASE_SHA:-}
case $base_sha in
  '')
    if [ "${CI:-}" = true ]; then
      fail "BASE_SHA is required in CI"
    fi
    if [ "$include_dirty" -eq 1 ]; then
      base_sha=$(git rev-parse "$head_sha" 2>/dev/null || :)
    else
      base_sha=$(git rev-parse "$head_sha^" 2>/dev/null || :)
    fi
    ;;
  0000000000000000000000000000000000000000)
    base_sha=
    ;;
esac
if [ -n "$base_sha" ]; then
  git cat-file -e "$base_sha^{commit}" 2>/dev/null ||
    fail "base commit is unavailable: $base_sha (CI checkout must use fetch-depth: 0)"
fi

current_version_file=$scratch_dir/current-version.lisp
if [ "$include_dirty" -eq 1 ]; then
  [ -f src/version.lisp ] || fail "src/version.lisp does not exist in the worktree"
  cp src/version.lisp "$current_version_file"
  current_version_label=src/version.lisp
else
  git show "$head_sha:src/version.lisp" >"$current_version_file" 2>/dev/null ||
    fail "src/version.lisp does not exist at $head_sha"
  current_version_label="src/version.lisp at $head_sha"
fi
current_version=$(extract_version "$current_version_file" "$current_version_label")
validate_semver "$current_version" "current version"

changed_files=$scratch_dir/changed-files
if [ -n "$base_sha" ]; then
  git diff --no-renames --name-only "$base_sha" "$head_sha" >"$changed_files" ||
    fail "could not compare $base_sha to $head_sha"
else
  git ls-tree -r --name-only "$head_sha" >"$changed_files" ||
    fail "could not inventory the initial commit"
fi
if [ "$include_dirty" -eq 1 ]; then
  git diff --no-renames --name-only "$head_sha" -- >>"$changed_files" ||
    fail "could not inventory dirty tracked files"
  git ls-files --others --exclude-standard >>"$changed_files" ||
    fail "could not inventory dirty untracked files"
fi
LC_ALL=C sort -u "$changed_files" -o "$changed_files"

release_bearing=false
release_bearing_path=
while IFS= read -r changed_path; do
  case $changed_path in
    src/*|vendor/*|vendor-data/*|clun.asd|site/install|scripts/release/*|scripts/build.lisp|scripts/registry.lisp|Makefile|.github/workflows/release.yml|LICENSE|COPYING|THIRD_PARTY_NOTICES.md)
      release_bearing=true
      release_bearing_path=$changed_path
      break
      ;;
  esac
done <"$changed_files"

if [ -z "$base_sha" ] || ! git cat-file -e "$base_sha:src/version.lisp" 2>/dev/null; then
  printf 'version-transition-check: bootstrap version %s; no prior source version exists\n' \
    "$current_version"
  exit 0
fi

git show "$base_sha:src/version.lisp" >"$scratch_dir/base-version.lisp" ||
  fail "could not read src/version.lisp at $base_sha"
base_version=$(extract_version "$scratch_dir/base-version.lisp" \
  "src/version.lisp at $base_sha")
validate_semver "$base_version" "base version"

if [ "$current_version" = "$base_version" ]; then
  if [ "$release_bearing" = false ]; then
    printf 'version-transition-check: version %s unchanged; no release-bearing paths changed\n' \
      "$current_version"
    exit 0
  fi

  transition='correction'
  load_canonical_disposition
  [ "$canonical_impact" != none ] ||
    fail "$canonical_ref records none for release-bearing correction $release_bearing_path"
  if published_version_exists; then
    fail "$published_reason already publishes $current_version; release-bearing correction $release_bearing_path needs the next version"
  fi
  printf 'version-transition-check: %s retained for unpublished correction (%s; %s)\n' \
    "$current_version" "$canonical_impact" "$canonical_ref"
  exit 0
fi

base_without_build=${base_version%%+*}
current_without_build=${current_version%%+*}
base_core=${base_without_build%%-*}
current_core=${current_without_build%%-*}
IFS=. read -r base_major base_minor base_patch <<EOF
$base_core
EOF
IFS=. read -r current_major current_minor current_patch <<EOF
$current_core
EOF

major_cmp=$(compare_uint "$current_major" "$base_major")
minor_cmp=$(compare_uint "$current_minor" "$base_minor")
patch_cmp=$(compare_uint "$current_patch" "$base_patch")
transition=

if [ "$major_cmp" -gt 0 ]; then
  expected_major=$(increment_uint "$base_major")
  [ "$current_major" = "$expected_major" ] &&
    [ "$current_minor" = 0 ] && [ "$current_patch" = 0 ] ||
    fail "major transition must be exactly $expected_major.0.0 core: $base_version -> $current_version"
  transition='major'
elif [ "$major_cmp" -lt 0 ]; then
  fail "version downgrade: $base_version -> $current_version"
elif [ "$minor_cmp" -gt 0 ]; then
  expected_minor=$(increment_uint "$base_minor")
  [ "$current_minor" = "$expected_minor" ] && [ "$current_patch" = 0 ] ||
    fail "minor transition must be exactly $base_major.$expected_minor.0 core: $base_version -> $current_version"
  transition='minor'
elif [ "$minor_cmp" -lt 0 ]; then
  fail "version downgrade: $base_version -> $current_version"
elif [ "$patch_cmp" -gt 0 ]; then
  expected_patch=$(increment_uint "$base_patch")
  [ "$current_patch" = "$expected_patch" ] ||
    fail "patch transition must be exactly $base_major.$base_minor.$expected_patch core: $base_version -> $current_version"
  transition='patch'
elif [ "$patch_cmp" -lt 0 ]; then
  fail "version downgrade: $base_version -> $current_version"
else
  base_prerelease=$(prerelease_part "$base_version")
  current_prerelease=$(prerelease_part "$current_version")
  if [ -z "$base_prerelease" ]; then
    fail "same-core stable version cannot move to another prerelease or build: $base_version -> $current_version"
  fi

  base_sequence=$(split_prerelease_sequence "$base_prerelease") ||
    fail "base prerelease lacks a numeric published-unit sequence: $base_version"
  if [ -z "$current_prerelease" ]; then
    transition='stable'
  else
    current_sequence=$(split_prerelease_sequence "$current_prerelease") ||
      fail "current prerelease lacks a numeric published-unit sequence: $current_version"
    base_prefix=$(printf '%s\n' "$base_sequence" | awk -F '\t' '{ print $1 }')
    base_number=$(printf '%s\n' "$base_sequence" | awk -F '\t' '{ print $2 }')
    current_prefix=$(printf '%s\n' "$current_sequence" | awk -F '\t' '{ print $1 }')
    current_number=$(printf '%s\n' "$current_sequence" | awk -F '\t' '{ print $2 }')
    [ "$current_prefix" = "$base_prefix" ] ||
      fail "same-core prerelease prefix changed: $base_version -> $current_version"
    expected_number=$(increment_uint "$base_number")
    [ "$current_number" = "$expected_number" ] ||
      fail "same-core prerelease must advance exactly once: expected $base_prefix${base_prefix:+.}$expected_number"
    transition='prerelease'
  fi
fi

case $transition in
  major|minor|patch)
    target_prerelease=$(prerelease_part "$current_version")
    if [ -n "$target_prerelease" ]; then
      target_sequence=$(split_prerelease_sequence "$target_prerelease") ||
        fail "new-core prerelease must start a numeric .1 sequence: $current_version"
      target_prefix=$(printf '%s\n' "$target_sequence" | awk -F '\t' '{ print $1 }')
      target_number=$(printf '%s\n' "$target_sequence" | awk -F '\t' '{ print $2 }')
      [ -n "$target_prefix" ] && [ "$target_number" = 1 ] ||
        fail "new-core prerelease must start a numeric .1 sequence: $current_version"
    fi
    ;;
esac

[ "$release_bearing" = true ] ||
  fail "version changed without a release-bearing path: $base_version -> $current_version"
load_canonical_disposition
case $transition in
  major|minor|patch)
    [ "$canonical_impact" = "$transition" ] ||
      fail "version transition is $transition but $canonical_ref records $canonical_impact"
    ;;
  prerelease|stable)
    [ "$canonical_impact" != none ] ||
      fail "$canonical_ref records none for release-bearing $transition unit"
    ;;
esac

if published_version_exists; then
  fail "$published_reason already publishes target $current_version; release versions and tags cannot be reused"
fi

printf 'version-transition-check: %s -> %s (%s; %s; %s)\n' \
  "$base_version" "$current_version" "$transition" "$canonical_impact" "$canonical_ref"
