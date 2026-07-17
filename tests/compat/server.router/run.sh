#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
[ -x "$clun" ] || { printf 'server.router: %s is missing\n' "$clun" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { printf 'server.router: curl is required\n' >&2; exit 2; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/clun-compat-router.XXXXXX")
server_pid=
cleanup() {
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
  [ -z "$server_pid" ] || wait "$server_pid" 2>/dev/null || true
  rm -rf "$scratch"
}
trap cleanup 0 HUP INT TERM

"$clun" "$repo_root/tests/compat/server.router/server.js" >"$scratch/server.out" \
  2>"$scratch/server.err" &
server_pid=$!

attempt=0
url=
while [ "$attempt" -lt 100 ]; do
  url=$(sed -n '1p' "$scratch/server.out" 2>/dev/null || :)
  [ -z "$url" ] || break
  kill -0 "$server_pid" 2>/dev/null || {
    cat "$scratch/server.err" >&2
    printf 'server.router: server exited before publishing its URL\n' >&2
    exit 1
  }
  sleep 0.1
  attempt=$((attempt + 1))
done
[ -n "$url" ] || { printf 'server.router: timed out waiting for server URL\n' >&2; exit 1; }

assert_body() {
  path=$1
  expected=$2
  method=${3:-GET}
  actual=$(curl --fail --silent --show-error -X "$method" "${url}${path}")
  [ "$actual" = "$expected" ] || {
    printf 'server.router: %s %s: expected %s, got %s\n' "$method" "$path" "$expected" "$actual" >&2
    exit 1
  }
}

assert_body static static

curl --silent --show-error --dump-header "$scratch/static-headers-1" \
  --output "$scratch/static-body-1" "${url}static"
etag=$(tr -d '\r' <"$scratch/static-headers-1" | awk '
  BEGIN { IGNORECASE = 1 }
  /^etag:/ { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }
')
[ -n "$etag" ] && [ "$(cat "$scratch/static-body-1")" = static ] || {
  printf 'server.router: static response did not publish an ETag and body\n' >&2
  exit 1
}
curl --silent --show-error --dump-header "$scratch/static-headers-2" \
  --output "$scratch/static-body-2" "${url}static"
etag_again=$(tr -d '\r' <"$scratch/static-headers-2" | awk '
  BEGIN { IGNORECASE = 1 }
  /^etag:/ { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }
')
[ "$etag_again" = "$etag" ] || {
  printf 'server.router: static response ETag changed between requests\n' >&2
  exit 1
}
status=$(curl --silent --show-error --output "$scratch/not-modified" --write-out '%{http_code}' \
  -H "If-None-Match: \"unrelated\", W/$etag" "${url}static")
[ "$status" = 304 ] && [ ! -s "$scratch/not-modified" ] || {
  printf 'server.router: static If-None-Match did not produce an empty 304\n' >&2
  exit 1
}

assert_body api/users exact
assert_body api/users/alice%40example.com 'param:alice@example.com'
assert_body api/users/%C3%A9 'param:é'
assert_body api/unknown/deep 'wild:unknown/deep'
assert_body method 'get:GET'
assert_body method post POST

status=$(curl --silent --show-error --output "$scratch/put" --write-out '%{http_code}' \
  -X PUT "${url}method")
[ "$status" = 202 ] && [ "$(cat "$scratch/put")" = 'fallback:PUT:/method' ] || {
  printf 'server.router: method miss did not reach fetch fallback\n' >&2
  exit 1
}

assert_body async async
status=$(curl --silent --show-error --output "$scratch/error" --write-out '%{http_code}' \
  "${url}error")
[ "$status" = 500 ] && [ "$(cat "$scratch/error")" = 'error:route-failure' ] || {
  printf 'server.router: route error did not reach the error handler\n' >&2
  exit 1
}

status=$(curl --silent --show-error --output "$scratch/skip" --write-out '%{http_code}' \
  "${url}skip")
[ "$status" = 202 ] && [ "$(cat "$scratch/skip")" = 'fallback:GET:/skip' ] || {
  printf 'server.router: false route did not reach fetch fallback\n' >&2
  exit 1
}

curl --silent --show-error --head "${url}method" >"$scratch/head"
tr -d '\r' <"$scratch/head" | grep -i -x 'content-length: 8' >/dev/null || {
  printf 'server.router: implicit HEAD did not retain the GET representation length\n' >&2
  exit 1
}

assert_body reload reloaded
assert_body after after
status=$(curl --silent --show-error --output "$scratch/missing" --write-out '%{http_code}' \
  "${url}missing")
[ "$status" = 404 ] && [ "$(cat "$scratch/missing")" = 'Not Found' ] || {
  printf 'server.router: route-only server did not return the built-in 404\n' >&2
  exit 1
}

printf 'server.router: routes, params, methods, ETags, conditional GET, async, errors, fallback, HEAD, and reload passed\n'
