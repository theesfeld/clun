#!/bin/sh

set -eu

if [ "$#" -ne 3 ]; then
  printf 'usage: %s <archive> <version> <target>\n' "$0" >&2
  exit 2
fi

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
archive=$1
version=${2#v}
target=$3
archive_size=$(wc -c <"$archive" | tr -d '[:space:]')
[ "$archive_size" -le 104857600 ] || {
  printf 'packaged-updater-test: archive is larger than the 100 MiB updater transport limit\n' >&2
  exit 1
}
root=$(mktemp -d "${TMPDIR:-/tmp}/clun-packaged-update.XXXXXX")
cleanup() { rm -rf "$root"; }
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

CLUN_PACKAGED_UPDATE_ARCHIVE=$archive \
CLUN_PACKAGED_UPDATE_VERSION=$version \
CLUN_PACKAGED_UPDATE_TARGET=$target \
CLUN_PACKAGED_UPDATE_ROOT=$root \
XDG_CACHE_HOME="$root/cache" \
  sbcl --dynamic-space-size 4096 --non-interactive --no-userinit --no-sysinit \
    --load "$repo_root/scripts/test-packaged-updater.lisp"

[ -L "$root/bin/clun" ] || {
  printf 'packaged-updater-test: stable launcher is not a symlink\n' >&2
  exit 1
}
[ "$(PATH="$root/bin:$PATH" clun --version)" = "clun $version" ] || {
  printf 'packaged-updater-test: PATH launcher did not execute packaged bundle\n' >&2
  exit 1
}
[ -f "$root/old/bin/clun" ] || {
  printf 'packaged-updater-test: updater did not retain the prior target\n' >&2
  exit 1
}

case "$target" in
  linux-*)
    bundle="$root/releases/$version/$target"
    [ -f "$bundle/lib/LOADER" ] && [ -x "$bundle/libexec/clun" ] || {
      printf 'packaged-updater-test: Linux sidecars are missing\n' >&2
      exit 1
    }
    ;;
esac

printf 'packaged updater fixture passed for %s (%s bytes; 104857600-byte limit)\n' \
  "$target" "$archive_size"
