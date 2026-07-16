#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
[ -x "$clun" ] || { printf 'web.cookies headers: %s is missing\n' "$clun" >&2; exit 2; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/clun-compat-cookies-headers.XXXXXX")
cleanup() {
  rm -rf "$scratch"
}
trap cleanup 0 HUP INT TERM

env CI=0 "$clun" "$repo_root/tests/compat/web.cookies/headers.js" \
  >"$scratch/headers.out" 2>"$scratch/headers.err"
cmp -s "$repo_root/tests/compat/web.cookies/headers.out" "$scratch/headers.out" || {
  diff -u "$repo_root/tests/compat/web.cookies/headers.out" "$scratch/headers.out" >&2 || :
  exit 1
}
[ ! -s "$scratch/headers.err" ] || { cat "$scratch/headers.err" >&2; exit 1; }

CLUN_COMPAT_EXECUTABLE="$clun" TMPDIR="${TMPDIR:-/tmp}" \
  sh "$repo_root/tests/compat/web.cookies/run-fetch.sh"

printf 'web.cookies headers: constructed and fetched header views passed\n'
