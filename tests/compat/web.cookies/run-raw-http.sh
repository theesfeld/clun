#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
[ -x "$clun" ] || { printf 'web.cookies raw-http: %s is missing\n' "$clun" >&2; exit 2; }
command -v sbcl >/dev/null 2>&1 || { printf 'web.cookies raw-http: sbcl is required\n' >&2; exit 2; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/clun-compat-cookies-raw-http.XXXXXX")
server_pid=
cleanup() {
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
  [ -z "$server_pid" ] || wait "$server_pid" 2>/dev/null || true
  rm -rf "$scratch"
}
trap cleanup 0 HUP INT TERM

env CI=0 "$clun" "$repo_root/tests/compat/web.cookies/raw-http.js" \
  >"$scratch/server.out" 2>"$scratch/server.err" &
server_pid=$!

attempt=0
url=
while [ "$attempt" -lt 100 ]; do
  url=$(sed -n '1p' "$scratch/server.out" 2>/dev/null || :)
  [ -z "$url" ] || break
  kill -0 "$server_pid" 2>/dev/null || {
    cat "$scratch/server.err" >&2
    printf 'web.cookies raw-http: server exited before publishing URL\n' >&2
    exit 1
  }
  sleep 0.1
  attempt=$((attempt + 1))
done
[ -n "$url" ] || { printf 'web.cookies raw-http: timed out waiting for URL\n' >&2; exit 1; }

case "$url" in
  http://127.0.0.1:*/) port=${url#http://127.0.0.1:}; port=${port%/} ;;
  *) printf 'web.cookies raw-http: malformed URL: %s\n' "$url" >&2; exit 1 ;;
esac
case "$port" in
  ''|*[!0-9]*) printf 'web.cookies raw-http: malformed port: %s\n' "$port" >&2; exit 1 ;;
esac

CLUN_COOKIE_RAW_PORT=$port sbcl --noinform --disable-debugger --no-userinit --no-sysinit --script \
  "$repo_root/tests/compat/web.cookies/raw-client.lisp" \
  >"$scratch/raw.out" 2>"$scratch/raw.err"
cmp -s "$repo_root/tests/compat/web.cookies/raw-http.out" "$scratch/raw.out" || {
  diff -u "$repo_root/tests/compat/web.cookies/raw-http.out" "$scratch/raw.out" >&2 || :
  exit 1
}
[ ! -s "$scratch/raw.err" ] || { cat "$scratch/raw.err" >&2; exit 1; }

printf 'web.cookies raw-http: framing, limits, duplicates, and pipelines passed\n'
