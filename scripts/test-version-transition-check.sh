#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
checker=$repo_root/scripts/version-transition-check.sh
scratch_parent=${TMPDIR:-/tmp}
[ -d "$scratch_parent" ] || scratch_parent=.
scratch_dir=$(mktemp -d "$scratch_parent/clun-version-fixtures.XXXXXX")
scratch_dir=$(CDPATH='' cd -- "$scratch_dir" && pwd)
trap 'rm -rf "$scratch_dir"' 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

write_version() {
  fixture_version=$1
  fixture_file=$2
  printf '%s\n' \
    ';;;; fixture release version.' \
    '' \
    '(in-package :clun)' \
    '' \
    "(defparameter *clun-version* \"$fixture_version\")" >"$fixture_file"
}

write_issue_body() {
  fixture_version=$1
  fixture_impact=$2
  fixture_file=$3
  fixture_heading=${4:-# Canonical status}
  {
    printf '%s\n\n' "$fixture_heading"
    printf "**SemVer impact:** \`%s\`  \n" "$fixture_impact"
    printf "**Release version:** \`%s\`  \n" "$fixture_version"
    printf "**Release tag:** \`v%s\`\n" "$fixture_version"
    printf '%s\n' \
      '**SemVer rationale:** Fixture records the actual completed release impact.'
  } >"$fixture_file"
}

write_fake_gh() {
  fixture_file=$1
  # Every single-quoted line is source for the generated fake executable.
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    'mode=${FIXTURE_GH_MODE:-absent}' \
    'case ${1:-}:${2:-} in' \
    '  api:*)' \
    '    endpoint=$2' \
    '    case $mode:$endpoint in' \
    '      remote-present:*) printf "%s\n" "{}"; exit 0 ;;' \
    '      remote-tag:*git/ref/tags/*) printf "%s\n" "{}"; exit 0 ;;' \
    '      remote-published-commit:*git/ref/tags/*) printf "commit\t%s\n" "$FIXTURE_TAG_SHA"; exit 0 ;;' \
    '      remote-published-annotated:*git/ref/tags/*) printf "tag\tfixture-tag-object\n"; exit 0 ;;' \
    '      remote-published-annotated:*git/tags/fixture-tag-object) printf "commit\t%s\n" "$FIXTURE_TAG_SHA"; exit 0 ;;' \
    '    esac' \
    '    printf "%s\n" "{\"message\":\"Not Found\",\"status\":\"404\"}"' \
    '    printf "%s\n" "gh: Not Found (HTTP 404)" >&2' \
    '    exit 1' \
    '    ;;' \
    '  issue:list)' \
    '    [ "$mode" = future ] || exit 2' \
    '    printf "91\tCLOSED\n"' \
    '    ;;' \
    '  issue:view)' \
    '    [ "$mode" = future ] || exit 2' \
    '    case " $* " in' \
    '      *" --json state "*) printf "%s\n" "CLOSED" ;;' \
    '      *) sed -n "1,\$p" "$FIXTURE_ISSUE_BODY" ;;' \
    '    esac' \
    '    ;;' \
    '  *) exit 2 ;;' \
    'esac' >"$fixture_file"
  chmod +x "$fixture_file"
}

check_result() {
  fixture_name=$1
  expected_status=$2
  expected_text=$3
  status=$4
  output=$5
  case $expected_status in
    pass) [ "$status" -eq 0 ] || {
      printf 'fixture %s: expected success, got %s\n%s\n' \
        "$fixture_name" "$status" "$output" >&2
      exit 1
    } ;;
    fail) [ "$status" -ne 0 ] || {
      printf 'fixture %s: expected failure\n%s\n' "$fixture_name" "$output" >&2
      exit 1
    } ;;
    *) printf 'fixture %s: invalid expected status %s\n' \
      "$fixture_name" "$expected_status" >&2; exit 1 ;;
  esac
  printf '%s\n' "$output" | grep -Fq -- "$expected_text" || {
    printf 'fixture %s: missing output %s\n%s\n' \
      "$fixture_name" "$expected_text" "$output" >&2
    exit 1
  }
  printf '  (pass) %s\n' "$fixture_name"
}

run_case() (
  fixture_name=$1
  base_version=$2
  current_version=$3
  changed_path=$4
  expected_status=$5
  expected_text=$6
  canonical_impact=${7:-patch}
  base_mode=${8:-explicit}
  publication_mode=${9:-absent}
  fixture=$scratch_dir/$fixture_name

  mkdir -p "$fixture/src" "$fixture/docs" "$fixture/site" \
    "$fixture/scripts/release" "$fixture/vendor"
  git -C "$fixture" init -q
  git -C "$fixture" config user.name 'Clun fixture'
  git -C "$fixture" config user.email 'fixture@clun.invalid'
  write_version "$base_version" "$fixture/src/version.lisp"
  printf '%s\n' base >"$fixture/src/runtime.lisp"
  git -C "$fixture" add .
  git -C "$fixture" commit -qm base
  fixture_base=$(git -C "$fixture" rev-parse HEAD)

  write_version "$current_version" "$fixture/src/version.lisp"
  if [ "$changed_path" != src/version.lisp ]; then
    mkdir -p "$fixture/$(dirname -- "$changed_path")"
    printf '%s\n' changed >"$fixture/$changed_path"
  fi
  git -C "$fixture" add .
  git -C "$fixture" commit -qm current
  fixture_head=$(git -C "$fixture" rev-parse HEAD)

  issue_body=$fixture/issue.md
  fake_gh=$fixture/fake-gh
  write_issue_body "$current_version" "$canonical_impact" "$issue_body"
  write_fake_gh "$fake_gh"
  if [ "$publication_mode" = local-tag ]; then
    git -C "$fixture" tag "v$current_version" "$fixture_base"
  elif [ "$publication_mode" = intermediate-tag ]; then
    # Publish exactly one intermediate same-core prerelease so a multi-step
    # skip must fail closed (base.N -> base.N+2 with N+1 tagged).
    intermediate_prefix=${base_version%.*}
    intermediate_base=${base_version##*.}
    intermediate_version="$intermediate_prefix.$((intermediate_base + 1))"
    git -C "$fixture" tag "v$intermediate_version" "$fixture_base"
  fi

  set +e
  case $base_mode in
    explicit)
      output=$(GH_TOKEN=fixture GITHUB_REPOSITORY=fixture/clun \
        CLUN_VERSION_REPO_ROOT="$fixture" CLUN_GH_BIN="$fake_gh" \
        CLUN_CANONICAL_ISSUE_BODY_FILE="$issue_body" \
        CLUN_CANONICAL_ISSUE_REF='fixture issue #91' \
        FIXTURE_GH_MODE="$publication_mode" \
        BASE_SHA="$fixture_base" HEAD_SHA="$fixture_head" \
        sh "$checker" 2>&1)
      status=$?
      ;;
    missing-local)
      unset BASE_SHA CI
      output=$(GH_TOKEN=fixture GITHUB_REPOSITORY=fixture/clun \
        CLUN_VERSION_REPO_ROOT="$fixture" CLUN_GH_BIN="$fake_gh" \
        CLUN_CANONICAL_ISSUE_BODY_FILE="$issue_body" \
        CLUN_CANONICAL_ISSUE_REF='fixture issue #91' \
        FIXTURE_GH_MODE="$publication_mode" \
        HEAD_SHA="$fixture_head" sh "$checker" 2>&1)
      status=$?
      ;;
    missing-ci)
      unset BASE_SHA
      output=$(CI=true GH_TOKEN=fixture GITHUB_REPOSITORY=fixture/clun \
        CLUN_VERSION_REPO_ROOT="$fixture" CLUN_GH_BIN="$fake_gh" \
        CLUN_CANONICAL_ISSUE_BODY_FILE="$issue_body" \
        CLUN_CANONICAL_ISSUE_REF='fixture issue #91' \
        FIXTURE_GH_MODE="$publication_mode" \
        HEAD_SHA="$fixture_head" sh "$checker" 2>&1)
      status=$?
      ;;
    *) printf 'fixture %s: invalid base mode %s\n' \
      "$fixture_name" "$base_mode" >&2; exit 1 ;;
  esac
  set -e

  check_result "$fixture_name" "$expected_status" "$expected_text" "$status" "$output"
)

run_bootstrap_case() (
  fixture=$scratch_dir/bootstrap-zero-base
  mkdir -p "$fixture/src"
  git -C "$fixture" init -q
  git -C "$fixture" config user.name 'Clun fixture'
  git -C "$fixture" config user.email 'fixture@clun.invalid'
  write_version '0.1.0-dev.1' "$fixture/src/version.lisp"
  printf '%s\n' runtime >"$fixture/src/runtime.lisp"
  git -C "$fixture" add .
  git -C "$fixture" commit -qm initial
  fixture_head=$(git -C "$fixture" rev-parse HEAD)
  output=$(CLUN_VERSION_REPO_ROOT="$fixture" \
    BASE_SHA=0000000000000000000000000000000000000000 HEAD_SHA="$fixture_head" \
    sh "$checker" 2>&1)
  check_result bootstrap-zero-base pass 'bootstrap version 0.1.0-dev.1' 0 "$output"
)

run_future_issue_case() (
  fixture=$scratch_dir/future-canonical-issue
  mkdir -p "$fixture/src"
  git -C "$fixture" init -q
  git -C "$fixture" config user.name 'Clun fixture'
  git -C "$fixture" config user.email 'fixture@clun.invalid'
  write_version 1.2.3 "$fixture/src/version.lisp"
  printf '%s\n' base >"$fixture/src/runtime.lisp"
  printf '%s\n' '**Canonical issue:** https://github.com/future/clun/issues/91' \
    >"$fixture/STATE.md"
  git -C "$fixture" add .
  git -C "$fixture" commit -qm base
  fixture_base=$(git -C "$fixture" rev-parse HEAD)
  write_version 1.3.0 "$fixture/src/version.lisp"
  printf '%s\n' changed >"$fixture/src/runtime.lisp"
  git -C "$fixture" add .
  git -C "$fixture" commit -qm current
  fixture_head=$(git -C "$fixture" rev-parse HEAD)
  issue_body=$fixture/issue-91.md
  fake_gh=$fixture/fake-gh
  write_issue_body 1.3.0 minor "$issue_body" '# Canonical live phase record'
  write_fake_gh "$fake_gh"
  output=$(GH_TOKEN=fixture GITHUB_REPOSITORY=future/clun \
    CLUN_VERSION_REPO_ROOT="$fixture" CLUN_GH_BIN="$fake_gh" \
    FIXTURE_GH_MODE=future FIXTURE_ISSUE_BODY="$issue_body" \
    BASE_SHA="$fixture_base" HEAD_SHA="$fixture_head" \
    sh "$checker" 2>&1)
  check_result future-canonical-issue pass 'minor; minor; canonical issue #91' 0 "$output"
)

run_dirty_ignored_case() (
  fixture=$scratch_dir/dirty-ignored
  mkdir -p "$fixture/src"
  git -C "$fixture" init -q
  git -C "$fixture" config user.name 'Clun fixture'
  git -C "$fixture" config user.email 'fixture@clun.invalid'
  write_version 1.2.3 "$fixture/src/version.lisp"
  printf '%s\n' base >"$fixture/src/runtime.lisp"
  git -C "$fixture" add .
  git -C "$fixture" commit -qm base
  fixture_base=$(git -C "$fixture" rev-parse HEAD)
  write_version 1.2.4 "$fixture/src/version.lisp"
  printf '%s\n' committed >"$fixture/src/runtime.lisp"
  git -C "$fixture" add .
  git -C "$fixture" commit -qm current
  fixture_head=$(git -C "$fixture" rev-parse HEAD)
  issue_body=$fixture/issue.md
  fake_gh=$fixture/fake-gh
  write_issue_body 1.2.4 patch "$issue_body"
  write_fake_gh "$fake_gh"
  write_version 9.bad "$fixture/src/version.lisp"
  output=$(GH_TOKEN=fixture GITHUB_REPOSITORY=fixture/clun \
    CLUN_VERSION_REPO_ROOT="$fixture" CLUN_GH_BIN="$fake_gh" \
    FIXTURE_GH_MODE=absent \
    CLUN_CANONICAL_ISSUE_BODY_FILE="$issue_body" \
    CLUN_CANONICAL_ISSUE_REF='fixture issue #92' \
    BASE_SHA="$fixture_base" HEAD_SHA="$fixture_head" \
    sh "$checker" 2>&1)
  check_result dirty-ignored pass '1.2.3 -> 1.2.4 (patch;' 0 "$output"
)

run_dirty_included_case() (
  fixture=$scratch_dir/dirty-included
  mkdir -p "$fixture/src"
  git -C "$fixture" init -q
  git -C "$fixture" config user.name 'Clun fixture'
  git -C "$fixture" config user.email 'fixture@clun.invalid'
  write_version 1.2.3 "$fixture/src/version.lisp"
  printf '%s\n' base >"$fixture/src/runtime.lisp"
  git -C "$fixture" add .
  git -C "$fixture" commit -qm base
  fixture_head=$(git -C "$fixture" rev-parse HEAD)
  write_version 1.2.4 "$fixture/src/version.lisp"
  printf '%s\n' dirty >"$fixture/src/runtime.lisp"
  issue_body=$fixture/issue.md
  fake_gh=$fixture/fake-gh
  write_issue_body 1.2.4 patch "$issue_body"
  write_fake_gh "$fake_gh"
  output=$(GH_TOKEN=fixture GITHUB_REPOSITORY=fixture/clun \
    CLUN_INCLUDE_DIRTY=1 CLUN_VERSION_REPO_ROOT="$fixture" CLUN_GH_BIN="$fake_gh" \
    FIXTURE_GH_MODE=absent \
    CLUN_CANONICAL_ISSUE_BODY_FILE="$issue_body" \
    CLUN_CANONICAL_ISSUE_REF='fixture issue #93' \
    BASE_SHA="$fixture_head" HEAD_SHA="$fixture_head" \
    sh "$checker" 2>&1)
  check_result dirty-included pass '1.2.3 -> 1.2.4 (patch;' 0 "$output"
)

run_dirty_tagged_correction_case() (
  fixture=$scratch_dir/dirty-tagged-correction
  mkdir -p "$fixture/src"
  git -C "$fixture" init -q
  git -C "$fixture" config user.name 'Clun fixture'
  git -C "$fixture" config user.email 'fixture@clun.invalid'
  write_version 1.2.3 "$fixture/src/version.lisp"
  printf '%s\n' base >"$fixture/src/runtime.lisp"
  git -C "$fixture" add .
  git -C "$fixture" commit -qm base
  write_version 1.3.0 "$fixture/src/version.lisp"
  printf '%s\n' released >"$fixture/src/runtime.lisp"
  git -C "$fixture" add .
  git -C "$fixture" commit -qm released
  fixture_head=$(git -C "$fixture" rev-parse HEAD)
  git -C "$fixture" tag v1.3.0 "$fixture_head"
  printf '%s\n' correction >"$fixture/src/runtime.lisp"
  issue_body=$fixture/issue.md
  write_issue_body 1.3.0 patch "$issue_body"
  set +e
  output=$(BASE_SHA="$fixture_head" \
    CLUN_INCLUDE_DIRTY=1 CLUN_VERSION_REPO_ROOT="$fixture" \
    CLUN_CANONICAL_ISSUE_BODY_FILE="$issue_body" \
    CLUN_CANONICAL_ISSUE_REF='fixture issue #94' \
    HEAD_SHA="$fixture_head" sh "$checker" 2>&1)
  status=$?
  set -e
  check_result dirty-tagged-correction fail \
    'local tag v1.3.0 already publishes' "$status" "$output"
)

run_dirty_auto_case() (
  fixture=$scratch_dir/dirty-auto
  mkdir -p "$fixture/src"
  git -C "$fixture" init -q
  git -C "$fixture" config user.name 'Clun fixture'
  git -C "$fixture" config user.email 'fixture@clun.invalid'
  write_version 1.2.3 "$fixture/src/version.lisp"
  printf '%s\n' base >"$fixture/src/runtime.lisp"
  git -C "$fixture" add .
  git -C "$fixture" commit -qm base
  write_version 1.2.4 "$fixture/src/version.lisp"
  printf '%s\n' dirty >"$fixture/src/runtime.lisp"
  issue_body=$fixture/issue.md
  fake_gh=$fixture/fake-gh
  write_issue_body 1.2.4 patch "$issue_body"
  write_fake_gh "$fake_gh"
  unset BASE_SHA HEAD_SHA GITHUB_SHA CI CLUN_INCLUDE_DIRTY
  output=$(GH_TOKEN=fixture GITHUB_REPOSITORY=fixture/clun \
    CLUN_VERSION_REPO_ROOT="$fixture" CLUN_GH_BIN="$fake_gh" \
    FIXTURE_GH_MODE=absent \
    CLUN_CANONICAL_ISSUE_BODY_FILE="$issue_body" \
    CLUN_CANONICAL_ISSUE_REF='fixture issue #95' \
    sh "$checker" 2>&1)
  check_result dirty-auto pass '1.2.3 -> 1.2.4 (patch;' 0 "$output"
)

write_release_ledger() {
  fixture_version=$1
  fixture_installer=$2
  fixture_state=$3
  fixture_commit=$4
  fixture_file=$5
  printf '%b\n' \
    'release_id\tversion\tasdf_core\tinstaller_default\ttag\tpublication_state\tlicense\tactive_phase\tissue\tsemver_impact\tprevious_version\tversion_source\tasdf_source\tinstaller_source\trelease_commit' \
    "clun-$fixture_version\t$fixture_version\t1.3.0\t$fixture_installer\tv$fixture_version\t$fixture_state\tGPL-3.0-or-later\t31\t91\tpatch\t1.3.0-dev.1\tsrc/version.lisp\tclun.asd\tsite/install\t$fixture_commit" \
    >"$fixture_file"
}

write_fixture_installer() {
  fixture_boundary=$1
  fixture_installer_file=$2
  # shellcheck disable=SC2016 # Fixture needs the literal installer expansion.
  printf '%s\n' '#!/bin/sh' "verified_installer_tag=$fixture_boundary" \
    'requested_version=${1:-${INSTALL_VERSION:-${CLUN_VERSION:-$verified_installer_tag}}}' \
    "printf \"%s\\n\" \"\$requested_version\"" >"$fixture_installer_file"
}

run_publication_reconciliation_case() (
  fixture_name=$1
  mutation=$2
  expected_status=$3
  expected_text=$4
  fixture=$scratch_dir/$fixture_name
  fixture_version=1.3.0-dev.2

  mkdir -p "$fixture/src" "$fixture/compat" "$fixture/site"
  git -C "$fixture" init -q
  git -C "$fixture" config user.name 'Clun fixture'
  git -C "$fixture" config user.email 'fixture@clun.invalid'
  write_version "$fixture_version" "$fixture/src/version.lisp"
  printf '%s\n' base >"$fixture/src/runtime.lisp"
  printf '%s\n' base >"$fixture/README.md"
  printf '%s\n' base >"$fixture/STATE.md"
  printf '%s\n' base >"$fixture/site/index.html"
  write_fixture_installer v1.3.0-dev.1 "$fixture/site/install"
  write_release_ledger "$fixture_version" v1.3.0-dev.1 candidate pending \
    "$fixture/compat/release.tsv"
  git -C "$fixture" add .
  git -C "$fixture" commit -qm base
  fixture_base=$(git -C "$fixture" rev-parse HEAD)

  printf '%s\n' published >"$fixture/README.md"
  printf '%s\n' published >"$fixture/STATE.md"
  printf '%s\n' published >"$fixture/site/index.html"
  write_fixture_installer "v$fixture_version" "$fixture/site/install"
  release_commit=$fixture_base
  case $mutation in
    wrong-release-commit) release_commit=0000000000000000000000000000000000000000 ;;
    installer-content) printf '%s\n' '# unexpected mutation' >>"$fixture/site/install" ;;
    installer-boundary) write_fixture_installer v1.3.0-dev.1 "$fixture/site/install" ;;
    runtime-content) printf '%s\n' changed >"$fixture/src/runtime.lisp" ;;
    correct|missing-tag|wrong-tag|remote-tag|remote-annotated-tag) ;;
    *) printf 'fixture %s: invalid publication mutation %s\n' \
      "$fixture_name" "$mutation" >&2; exit 1 ;;
  esac
  write_release_ledger "$fixture_version" v1.3.0-dev.2 published "$release_commit" \
    "$fixture/compat/release.tsv"
  git -C "$fixture" add .
  git -C "$fixture" commit -qm published
  fixture_head=$(git -C "$fixture" rev-parse HEAD)
  case $mutation in
    missing-tag) ;;
    wrong-tag) git -C "$fixture" tag "v$fixture_version" "$fixture_head" ;;
    remote-tag|remote-annotated-tag) ;;
    *) git -C "$fixture" tag "v$fixture_version" "$fixture_base" ;;
  esac

  issue_body=$fixture/issue.md
  fake_gh=$fixture/fake-gh
  write_issue_body "$fixture_version" patch "$issue_body"
  write_fake_gh "$fake_gh"
  publication_mode=absent
  case $mutation in
    remote-tag) publication_mode=remote-published-commit ;;
    remote-annotated-tag) publication_mode=remote-published-annotated ;;
  esac
  set +e
  output=$(GH_TOKEN=fixture GITHUB_REPOSITORY=fixture/clun \
    CLUN_VERSION_REPO_ROOT="$fixture" CLUN_GH_BIN="$fake_gh" \
    CLUN_CANONICAL_ISSUE_BODY_FILE="$issue_body" \
    CLUN_CANONICAL_ISSUE_REF='fixture issue #91' \
    FIXTURE_GH_MODE="$publication_mode" FIXTURE_TAG_SHA="$fixture_base" \
    BASE_SHA="$fixture_base" HEAD_SHA="$fixture_head" \
    sh "$checker" 2>&1)
  status=$?
  set -e
  check_result "$fixture_name" "$expected_status" "$expected_text" "$status" "$output"
)

run_tag_only_recovery_case() (
  fixture_name=$1
  mutation=$2
  expected_status=$3
  expected_text=$4
  fixture=$scratch_dir/$fixture_name
  fixture_version=1.3.0-dev.2

  mkdir -p "$fixture/src" "$fixture/compat" "$fixture/site"
  git -C "$fixture" init -q
  git -C "$fixture" config user.name 'Clun fixture'
  git -C "$fixture" config user.email 'fixture@clun.invalid'
  write_version "$fixture_version" "$fixture/src/version.lisp"
  printf '%s\n' base >"$fixture/src/runtime.lisp"
  printf '%s\n' base >"$fixture/README.md"
  printf '%s\n' base >"$fixture/STATE.md"
  printf '%s\n' base >"$fixture/site/index.html"
  write_fixture_installer v1.3.0-dev.1 "$fixture/site/install"
  write_release_ledger "$fixture_version" v1.3.0-dev.1 candidate pending \
    "$fixture/compat/release.tsv"
  git -C "$fixture" add .
  git -C "$fixture" commit -qm base
  fixture_base=$(git -C "$fixture" rev-parse HEAD)

  printf '%s\n' tag-only >"$fixture/README.md"
  if [ "$mutation" != missing-state ]; then
    printf '%s\n' tag-only >"$fixture/STATE.md"
  fi
  printf '%s\n' tag-only >"$fixture/site/index.html"
  release_commit=$fixture_base
  case $mutation in
    wrong-release-commit) release_commit=0000000000000000000000000000000000000000 ;;
    runtime-content) printf '%s\n' changed >"$fixture/src/runtime.lisp" ;;
    installer-content) printf '%s\n' '# unexpected mutation' >>"$fixture/site/install" ;;
    correct|missing-tag|lightweight-tag|wrong-tag|missing-state) ;;
    *) printf 'fixture %s: invalid tag-only mutation %s\n' \
      "$fixture_name" "$mutation" >&2; exit 1 ;;
  esac
  write_release_ledger "$fixture_version" v1.3.0-dev.1 candidate "$release_commit" \
    "$fixture/compat/release.tsv"
  git -C "$fixture" add .
  git -C "$fixture" commit -qm tag-only
  fixture_head=$(git -C "$fixture" rev-parse HEAD)
  case $mutation in
    missing-tag) ;;
    lightweight-tag) git -C "$fixture" tag "v$fixture_version" "$fixture_base" ;;
    wrong-tag) git -C "$fixture" tag -a -m fixture "v$fixture_version" "$fixture_head" ;;
    *) git -C "$fixture" tag -a -m fixture "v$fixture_version" "$fixture_base" ;;
  esac

  fake_gh=$fixture/fake-gh
  write_fake_gh "$fake_gh"
  set +e
  output=$(GH_TOKEN=fixture GITHUB_REPOSITORY=fixture/clun \
    CLUN_VERSION_REPO_ROOT="$fixture" CLUN_GH_BIN="$fake_gh" \
    FIXTURE_GH_MODE=absent \
    BASE_SHA="$fixture_base" HEAD_SHA="$fixture_head" \
    sh "$checker" 2>&1)
  status=$?
  set -e
  check_result "$fixture_name" "$expected_status" "$expected_text" "$status" "$output"
)

printf 'version-transition fixtures:\n'
run_case current-phase25b 0.0.1-dev 0.1.0-dev.1 src/runtime.lisp pass \
  '0.0.1-dev -> 0.1.0-dev.1 (minor;' minor
run_case minor 1.2.3 1.3.0 src/version.lisp pass '(minor;' minor
run_case patch 1.2.3 1.2.4 src/version.lisp pass '(patch;' patch
run_case major 1.2.3 2.0.0 src/version.lisp pass '(major;' major
run_case pre1-breaking-minor-core 0.1.0-dev.70 0.2.0-dev.1 src/version.lisp pass \
  '(minor; major;' major
run_case prerelease 1.3.0-dev.1 1.3.0-dev.2 src/runtime.lisp pass '(prerelease;' minor
run_case stable-promotion 1.3.0-dev.2 1.3.0 src/version.lisp pass '(stable;' minor

run_case correction-unpublished 1.3.0-dev.2 1.3.0-dev.2 src/runtime.lisp pass \
  'retained for unpublished correction' patch explicit absent
run_case correction-local-tag 1.3.0-dev.2 1.3.0-dev.2 src/runtime.lisp fail \
  'local tag v1.3.0-dev.2 already publishes' patch explicit local-tag
run_case correction-remote-release 1.3.0-dev.2 1.3.0-dev.2 src/runtime.lisp fail \
  'GitHub release v1.3.0-dev.2 already publishes' patch explicit remote-present
run_case correction-remote-tag 1.3.0-dev.2 1.3.0-dev.2 src/runtime.lisp fail \
  'remote tag v1.3.0-dev.2 already publishes' patch explicit remote-tag
run_case target-local-tag-reuse 1.3.0-dev.1 1.3.0-dev.2 src/runtime.lisp fail \
  'local tag v1.3.0-dev.2 already publishes target' patch explicit local-tag
run_case target-remote-release-reuse 1.3.0-dev.1 1.3.0-dev.2 src/runtime.lisp fail \
  'GitHub release v1.3.0-dev.2 already publishes target' patch explicit remote-present

run_case downgrade 1.2.3 1.2.2 src/version.lisp fail 'version downgrade:' patch
run_case major-skip 1.2.3 3.0.0 src/version.lisp fail \
  'major transition must be exactly 2.0.0 core' major
run_case major-bad-reset 1.2.3 2.1.0 src/version.lisp fail \
  'major transition must be exactly 2.0.0 core' major
run_case minor-skip 1.2.3 1.4.0 src/version.lisp fail \
  'minor transition must be exactly 1.3.0 core' minor
run_case minor-bad-reset 1.2.3 1.3.1 src/version.lisp fail \
  'minor transition must be exactly 1.3.0 core' minor
run_case patch-skip 1.2.3 1.2.5 src/version.lisp fail \
  'patch transition must be exactly 1.2.4 core' patch
run_case new-core-prerelease-skip 1.2.3 1.3.0-dev.2 src/version.lisp fail \
  'new-core prerelease must start a numeric .1 sequence' minor
run_case new-core-prerelease-unnumbered 1.2.3 1.3.0-dev src/version.lisp fail \
  'new-core prerelease must start a numeric .1 sequence' minor

# Skipping an unpublished intermediate is allowed for parallel draft allocation.
run_case prerelease-skip-unpublished 1.3.0-dev.1 1.3.0-dev.3 src/runtime.lisp pass \
  '(prerelease;' minor
# Skipping a published intermediate remains forbidden.
run_case prerelease-skip-published 1.3.0-dev.1 1.3.0-dev.3 src/runtime.lisp fail \
  'same-core prerelease skips a published intermediate' minor explicit intermediate-tag
run_case prerelease-regression 1.3.0-dev.2 1.3.0-dev.1 src/runtime.lisp fail \
  'same-core prerelease must advance' minor
run_case prerelease-large-sequence \
  1.3.0-dev.999999999999999999999999 \
  1.3.0-dev.1000000000000000000000000 \
  src/runtime.lisp pass '(prerelease;' patch
run_case malformed-current 1.2.3 1.2.4-dev.01 src/version.lisp fail \
  'current version is not strict SemVer' patch
run_case malformed-base 1.2.3-dev.01 1.2.4 src/version.lisp fail \
  'base version is not strict SemVer' patch
run_case canonical-mismatch 1.2.3 1.3.0 src/version.lisp fail \
  'version transition is minor but fixture issue #91 records patch' patch
run_case post1-minor-cannot-record-major 1.2.3 1.3.0 src/version.lisp fail \
  'version transition is minor but fixture issue #91 records major' major
run_case pre1-patch-cannot-record-major 0.1.0 0.1.1 src/version.lisp fail \
  'version transition is patch but fixture issue #91 records major' major
run_case canonical-none-prerelease 1.3.0-dev.1 1.3.0-dev.2 src/runtime.lisp fail \
  'records none for release-bearing prerelease unit' none

run_case docs-only 1.2.3 1.2.3 docs/guide.md pass \
  'version 1.2.3 unchanged; no release-bearing paths changed'
run_case site-only 1.2.3 1.2.3 site/index.html pass \
  'version 1.2.3 unchanged; no release-bearing paths changed'

run_case runtime-published 1.2.3 1.2.3 src/runtime.lisp fail 'already publishes' patch explicit local-tag
run_case installer-published 1.2.3 1.2.3 site/install fail 'already publishes' patch explicit local-tag
run_case vendor-published 1.2.3 1.2.3 vendor/library.lisp fail 'already publishes' patch explicit local-tag
run_case vendor-data-published 1.2.3 1.2.3 vendor-data/table.txt fail 'already publishes' patch explicit local-tag
run_case asdf-published 1.2.3 1.2.3 clun.asd fail 'already publishes' patch explicit local-tag
run_case release-script-published 1.2.3 1.2.3 scripts/release/package.sh fail 'already publishes' patch explicit local-tag
run_case build-script-published 1.2.3 1.2.3 scripts/build.lisp fail 'already publishes' patch explicit local-tag
run_case registry-script-published 1.2.3 1.2.3 scripts/registry.lisp fail 'already publishes' patch explicit local-tag
run_case makefile-published 1.2.3 1.2.3 Makefile fail 'already publishes' patch explicit local-tag
run_case release-workflow-published 1.2.3 1.2.3 .github/workflows/release.yml fail 'already publishes' patch explicit local-tag
run_case license-published 1.2.3 1.2.3 LICENSE fail 'already publishes' patch explicit local-tag

run_case missing-base-local 1.2.3 1.3.0 src/runtime.lisp pass '(minor;' minor missing-local
run_case missing-base-ci 1.2.3 1.3.0 src/runtime.lisp fail \
  'BASE_SHA is required in CI' minor missing-ci
run_bootstrap_case
run_future_issue_case
run_dirty_ignored_case
run_dirty_included_case
run_dirty_tagged_correction_case
run_dirty_auto_case
run_publication_reconciliation_case publication-reconciliation correct pass \
  'publication reconciliation for v1.3.0-dev.2'
run_publication_reconciliation_case publication-wrong-release-commit wrong-release-commit fail \
  'invalid publication reconciliation'
run_publication_reconciliation_case publication-installer-mutation installer-content fail \
  'invalid publication reconciliation'
run_publication_reconciliation_case publication-stale-installer-boundary installer-boundary fail \
  'invalid publication reconciliation'
run_publication_reconciliation_case publication-runtime-mutation runtime-content fail \
  'invalid publication reconciliation'
run_publication_reconciliation_case publication-wrong-tag wrong-tag fail \
  'invalid publication reconciliation'
run_publication_reconciliation_case publication-missing-tag missing-tag fail \
  'invalid publication reconciliation'
run_publication_reconciliation_case publication-remote-tag remote-tag pass \
  'publication reconciliation for v1.3.0-dev.2'
run_publication_reconciliation_case publication-remote-annotated-tag remote-annotated-tag pass \
  'publication reconciliation for v1.3.0-dev.2'
run_tag_only_recovery_case tag-only-recovery correct pass \
  'tag-only recovery for v1.3.0-dev.2'
run_tag_only_recovery_case tag-only-missing-tag missing-tag fail \
  'invalid tag-only recovery'
run_tag_only_recovery_case tag-only-lightweight-tag lightweight-tag fail \
  'invalid tag-only recovery'
run_tag_only_recovery_case tag-only-wrong-tag wrong-tag fail \
  'invalid tag-only recovery'
run_tag_only_recovery_case tag-only-wrong-release-commit wrong-release-commit fail \
  'invalid tag-only recovery'
run_tag_only_recovery_case tag-only-runtime-mutation runtime-content fail \
  'invalid tag-only recovery'
run_tag_only_recovery_case tag-only-installer-mutation installer-content fail \
  'invalid tag-only recovery'
run_tag_only_recovery_case tag-only-missing-surface missing-state fail \
  'invalid tag-only recovery'
printf 'version-transition fixtures: 69 passed\n'
