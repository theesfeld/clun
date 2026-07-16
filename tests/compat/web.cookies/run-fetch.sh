#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
[ -x "$clun" ] || { printf 'web.cookies fetch: %s is missing\n' "$clun" >&2; exit 2; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/clun-compat-cookies-fetch.XXXXXX")
server_pid=
cleanup() {
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
  [ -z "$server_pid" ] || wait "$server_pid" 2>/dev/null || true
  rm -rf "$scratch"
}
trap cleanup 0 HUP INT TERM

env CI=0 "$clun" "$repo_root/tests/compat/web.cookies/server.js" \
  >"$scratch/server.out" 2>"$scratch/server.err" &
server_pid=$!

attempt=0
url=
while [ "$attempt" -lt 100 ]; do
  url=$(sed -n '1p' "$scratch/server.out" 2>/dev/null || :)
  [ -z "$url" ] || break
  kill -0 "$server_pid" 2>/dev/null || {
    cat "$scratch/server.err" >&2
    printf 'web.cookies fetch: server exited before publishing URL\n' >&2
    exit 1
  }
  sleep 0.1
  attempt=$((attempt + 1))
done
[ -n "$url" ] || { printf 'web.cookies fetch: timed out waiting for URL\n' >&2; exit 1; }

env CI=0 "$clun" "$repo_root/tests/compat/web.cookies/fetch.js" "$url" \
  >"$scratch/fetch.out" 2>"$scratch/fetch.err"
cmp -s "$repo_root/tests/compat/web.cookies/fetch.out" "$scratch/fetch.out" || {
  diff -u "$repo_root/tests/compat/web.cookies/fetch.out" "$scratch/fetch.out" >&2 || :
  exit 1
}
[ ! -s "$scratch/fetch.err" ] || { cat "$scratch/fetch.err" >&2; exit 1; }

printf 'web.cookies fetch: duplicate Set-Cookie fields survived fetch\n'
