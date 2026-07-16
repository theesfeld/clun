#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
[ -x "$clun" ] || { printf 'web.cookies public: %s is missing\n' "$clun" >&2; exit 2; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/clun-compat-cookies-public.XXXXXX")
cleanup() {
  rm -rf "$scratch"
}
trap cleanup 0 HUP INT TERM

run_fixture() {
  name=$1
  source=$repo_root/tests/compat/web.cookies/$name.js
  expected=$repo_root/tests/compat/web.cookies/$name.out
  stdout=$scratch/$name.out
  stderr=$scratch/$name.err
  status=0
  env CI=0 "$clun" "$source" >"$stdout" 2>"$stderr" || status=$?
  [ "$status" -eq 0 ] || {
    cat "$stdout" >&2 || :
    cat "$stderr" >&2 || :
    printf 'web.cookies public: %s exited %s\n' "$name" "$status" >&2
    exit 1
  }
  cmp -s "$expected" "$stdout" || {
    diff -u "$expected" "$stdout" >&2 || :
    printf 'web.cookies public: %s stdout mismatch\n' "$name" >&2
    exit 1
  }
  [ ! -s "$stderr" ] || {
    cat "$stderr" >&2
    printf 'web.cookies public: %s wrote stderr\n' "$name" >&2
    exit 1
  }
}

for fixture in basic coercion parsing map; do
  run_fixture "$fixture"
done

printf 'web.cookies public: 4 shipped-binary fixture modules passed\n'
