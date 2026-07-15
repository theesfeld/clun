#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
version_file=${CLUN_RELEASE_VERSION_FILE:-$repo_root/src/version.lisp}
gh_bin=${CLUN_GH_BIN:-gh}
wait_seconds=${CLUN_RELEASE_WAIT_SECONDS:-0}
poll_seconds=${CLUN_RELEASE_POLL_SECONDS:-30}

fail() {
  printf 'release-live-check: %s\n' "$*" >&2
  exit 1
}

case $wait_seconds in
  ''|*[!0-9]*) fail "CLUN_RELEASE_WAIT_SECONDS must be a nonnegative integer" ;;
esac
case $poll_seconds in
  ''|*[!0-9]*|0) fail "CLUN_RELEASE_POLL_SECONDS must be a positive integer" ;;
esac

[ -f "$version_file" ] || fail "version file does not exist: $version_file"
versions=$(sed -n 's/^(defparameter \*clun-version\* "\([^"]*\)".*/\1/p' "$version_file")
version_count=$(printf '%s\n' "$versions" | awk 'NF { count++ } END { print count + 0 }')
[ "$version_count" -eq 1 ] ||
  fail "$version_file must contain exactly one nonempty *clun-version*"
version=$(printf '%s\n' "$versions" | sed -n '1p')
tag="v$version"

command -v "$gh_bin" >/dev/null 2>&1 || fail "GitHub CLI is required: $gh_bin"
"$gh_bin" auth status --hostname github.com >/dev/null 2>&1 ||
  fail "GitHub CLI is not authenticated for github.com"

repo=${CLUN_RELEASE_REPO:-${GITHUB_REPOSITORY:-}}
if [ -z "$repo" ]; then
  repo=$("$gh_bin" repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) ||
    fail "could not determine the GitHub repository; set CLUN_RELEASE_REPO"
fi
case $repo in
  *[!A-Za-z0-9_./-]*|*/*/*|/*|*/|'') fail "invalid GitHub repository: $repo" ;;
  */*) ;;
  *) fail "GitHub repository must be OWNER/REPO: $repo" ;;
esac

tmp_parent=${TMPDIR:-/tmp}
if [ ! -d "$tmp_parent" ]; then
  tmp_parent=.
fi
scratch_dir=$(mktemp -d "$tmp_parent/clun-release-live.XXXXXX") ||
  fail "could not create a scratch directory"
trap 'rm -rf "$scratch_dir"' 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
snapshot=$scratch_dir/release.tsv
query_error=$scratch_dir/query-error

required_assets='checksums.txt
clun-linux-x64.tar.gz
clun-linux-arm64.tar.gz
clun-darwin-x64.tar.gz
clun-darwin-arm64.tar.gz'
pending_reason=

inspect_release() {
  : >"$snapshot"
  : >"$query_error"
  if ! "$gh_bin" release view "$tag" \
    --repo "$repo" \
    --json isDraft,isPrerelease,assets \
    --jq '(if .isDraft then "draft" else "published" end) + "\t" + (.isPrerelease | tostring), (.assets[] | [.name, .state, (.size | tostring)] | @tsv)' \
    >"$snapshot" 2>"$query_error"; then
    detail=$(sed -n '1p' "$query_error")
    if [ -n "$detail" ]; then
      pending_reason="release query unavailable: $detail"
    else
      pending_reason="release is not published yet"
    fi
    return 1
  fi

  IFS="$(printf '\t')" read -r release_state release_prerelease release_extra < "$snapshot"
  [ -z "$release_extra" ] || {
    pending_reason="GitHub returned an invalid release status response"
    return 2
  }
  case $release_state in
    draft)
      pending_reason="release exists but is still a draft"
      return 1
      ;;
    published) ;;
    *)
      pending_reason="GitHub returned an invalid release response"
      return 2
      ;;
  esac
  case $release_prerelease in
    true|false) ;;
    *)
      pending_reason="GitHub returned an invalid prerelease status"
      return 2
      ;;
  esac
  version_without_build=${version%%+*}
  case $version_without_build in
    *-*) expected_prerelease=true ;;
    *) expected_prerelease=false ;;
  esac
  if [ "$release_prerelease" != "$expected_prerelease" ]; then
    pending_reason="release prerelease status is $release_prerelease; expected $expected_prerelease for $version"
    return 1
  fi

  missing=
  old_ifs=$IFS
  IFS='
'
  for asset in $required_assets; do
    if ! awk -F '\t' -v required="$asset" '
      $1 == required && $2 == "uploaded" && $3 ~ /^[0-9]+$/ && ($3 + 0) > 0 {
        matches++
      }
      END { exit(matches == 1 ? 0 : 1) }
    ' "$snapshot"; then
      if [ -n "$missing" ]; then
        missing="$missing, $asset"
      else
        missing=$asset
      fi
    fi
  done
  IFS=$old_ifs

  if [ -n "$missing" ]; then
    pending_reason="missing, duplicate, empty, or unready assets: $missing"
    return 1
  fi
  return 0
}

start=$(date +%s)
deadline=$((start + wait_seconds))
attempt=1

while :; do
  if inspect_release; then
    printf 'release-live-check: %s is published with all required assets in %s\n' \
      "$tag" "$repo"
    exit 0
  else
    inspect_status=$?
  fi

  [ "$inspect_status" -ne 2 ] || fail "$pending_reason"
  now=$(date +%s)
  elapsed=$((now - start))
  if [ "$now" -ge "$deadline" ]; then
    fail "$tag was not ready after ${elapsed}s: $pending_reason"
  fi

  remaining=$((deadline - now))
  sleep_for=$poll_seconds
  if [ "$sleep_for" -gt "$remaining" ]; then
    sleep_for=$remaining
  fi
  printf 'release-live-check: attempt %s: %s; retrying in %ss\n' \
    "$attempt" "$pending_reason" "$sleep_for"
  sleep "$sleep_for"
  attempt=$((attempt + 1))
done
