#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
[ -x "$clun" ] || { printf 'web.cookies security: %s is missing\n' "$clun" >&2; exit 2; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/clun-compat-cookies-security.XXXXXX")
cleanup() {
  rm -rf "$scratch"
}
trap cleanup 0 HUP INT TERM

env CI=0 "$clun" "$repo_root/tests/compat/web.cookies/security.js" \
  >"$scratch/security.out" 2>"$scratch/security.err"
cmp -s "$repo_root/tests/compat/web.cookies/security.out" "$scratch/security.out" || {
  diff -u "$repo_root/tests/compat/web.cookies/security.out" "$scratch/security.out" >&2 || :
  exit 1
}
[ ! -s "$scratch/security.err" ] || { cat "$scratch/security.err" >&2; exit 1; }

printf 'web.cookies security: injection, isolation, malformed input, and scaling passed\n'
