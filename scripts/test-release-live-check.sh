#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp_parent=${TMPDIR:-/tmp}
if [ ! -d "$tmp_parent" ]; then
  tmp_parent=.
fi
work_dir=$(mktemp -d "$tmp_parent/clun-release-live-test.XXXXXX")
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fake_gh=$work_dir/gh
cat >"$fake_gh" <<'EOF'
#!/bin/sh
set -eu

case "${1:-} ${2:-}" in
  'auth status')
    [ "${FAKE_GH_MODE:-}" != auth-failure ]
    ;;
  'release view')
    [ "${3:-}" = "$FAKE_EXPECTED_TAG" ] || {
      printf 'unexpected release tag: %s\n' "${3:-}" >&2
      exit 2
    }
    count=0
    if [ -f "$FAKE_GH_COUNT" ]; then
      count=$(cat "$FAKE_GH_COUNT")
    fi
    count=$((count + 1))
    printf '%s\n' "$count" >"$FAKE_GH_COUNT"
    case ${FAKE_GH_MODE:-} in
      unavailable)
        printf 'HTTP 404: release not found\n' >&2
        exit 1
        ;;
      pending-once)
        if [ "$count" -eq 1 ]; then
          printf 'HTTP 404: release not found\n' >&2
          exit 1
        fi
        ;;
      draft)
        printf 'draft\ttrue\n'
        exit 0
        ;;
    esac
    if [ "${FAKE_GH_MODE:-}" = stable-complete ] ||
       [ "${FAKE_GH_MODE:-}" = wrong-prerelease ]; then
      printf 'published\tfalse\n'
    else
      printf 'published\ttrue\n'
    fi
    printf 'checksums.txt\tuploaded\t123\n'
    printf 'clun-linux-x64.tar.gz\tuploaded\t123\n'
    printf 'clun-linux-arm64.tar.gz\tuploaded\t123\n'
    printf 'clun-darwin-x64.tar.gz\tuploaded\t123\n'
    if [ "${FAKE_GH_MODE:-}" = empty-asset ]; then
      printf 'clun-darwin-arm64.tar.gz\tuploaded\t0\n'
    elif [ "${FAKE_GH_MODE:-}" != missing-asset ]; then
      printf 'clun-darwin-arm64.tar.gz\tuploaded\t123\n'
    fi
    ;;
  *)
    printf 'unexpected fake gh arguments: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$fake_gh"

version_file=$work_dir/version.lisp
printf '%s\n' '(defparameter *clun-version* "1.2.3-rc.4")' >"$version_file"

run_check() {
  FAKE_GH_MODE=$1 \
  FAKE_GH_COUNT=$work_dir/count \
  FAKE_EXPECTED_TAG=${3:-v1.2.3-rc.4} \
  CLUN_GH_BIN=$fake_gh \
  CLUN_RELEASE_REPO=theesfeld/clun \
  CLUN_RELEASE_VERSION_FILE=$version_file \
  CLUN_RELEASE_WAIT_SECONDS=${2:-0} \
  CLUN_RELEASE_POLL_SECONDS=1 \
    sh "$repo_root/scripts/release-live-check.sh"
}

printf '0\n' >"$work_dir/count"
run_check complete 0 >/dev/null
[ "$(cat "$work_dir/count")" -eq 1 ] || {
  printf 'release-live-check test: ready release was not a single fast query\n' >&2
  exit 1
}

for mode in unavailable draft missing-asset empty-asset wrong-prerelease; do
  printf '0\n' >"$work_dir/count"
  if run_check "$mode" 0 >"$work_dir/$mode.out" 2>&1; then
    printf 'release-live-check test: %s release unexpectedly passed\n' "$mode" >&2
    exit 1
  fi
done

printf '0\n' >"$work_dir/count"
run_check pending-once 2 >/dev/null
[ "$(cat "$work_dir/count")" -eq 2 ] || {
  printf 'release-live-check test: pending release was not retried exactly once\n' >&2
  exit 1
}

printf '%s\n' '(defparameter *clun-version* "1.2.3")' >"$version_file"
printf '0\n' >"$work_dir/count"
run_check stable-complete 0 v1.2.3 >/dev/null
[ "$(cat "$work_dir/count")" -eq 1 ] || {
  printf 'release-live-check test: stable release was not a single fast query\n' >&2
  exit 1
}
printf '%s\n' '(defparameter *clun-version* "1.2.3-rc.4")' >"$version_file"

printf '0\n' >"$work_dir/count"
if FAKE_GH_MODE=auth-failure \
   FAKE_GH_COUNT=$work_dir/count \
   FAKE_EXPECTED_TAG=v1.2.3-rc.4 \
   CLUN_GH_BIN=$fake_gh \
   CLUN_RELEASE_REPO=theesfeld/clun \
   CLUN_RELEASE_VERSION_FILE=$version_file \
     sh "$repo_root/scripts/release-live-check.sh" >/dev/null 2>&1; then
  printf 'release-live-check test: unauthenticated GitHub CLI unexpectedly passed\n' >&2
  exit 1
fi
[ "$(cat "$work_dir/count")" -eq 0 ] || {
  printf 'release-live-check test: queried a release before authenticating\n' >&2
  exit 1
}

printf 'release live-check fixtures passed\n'
