#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
[ -x "$clun" ] || { printf 'server.http: %s is missing\n' "$clun" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { printf 'server.http: curl is required\n' >&2; exit 2; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/clun-compat-http.XXXXXX")
server_pid=
cleanup() {
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
  [ -z "$server_pid" ] || wait "$server_pid" 2>/dev/null || true
  rm -rf "$scratch"
}
trap cleanup 0 HUP INT TERM

"$clun" "$repo_root/tests/compat/server.http/server.js" >"$scratch/server.out" \
  2>"$scratch/server.err" &
server_pid=$!

attempt=0
url=
while [ "$attempt" -lt 100 ]; do
  url=$(sed -n '1p' "$scratch/server.out" 2>/dev/null || :)
  [ -z "$url" ] || break
  kill -0 "$server_pid" 2>/dev/null || {
    cat "$scratch/server.err" >&2
    printf 'server.http: server exited before publishing its URL\n' >&2
    exit 1
  }
  sleep 0.1
  attempt=$((attempt + 1))
done
[ -n "$url" ] || { printf 'server.http: timed out waiting for server URL\n' >&2; exit 1; }

case "$url" in
  http://127.0.0.1:*/) port=${url#http://127.0.0.1:}; port=${port%/} ;;
  *) printf 'server.http: unsafe or malformed server URL: %s\n' "$url" >&2; exit 1 ;;
esac
case "$port" in
  ''|*[!0-9]*) printf 'server.http: unsafe or malformed server URL: %s\n' "$url" >&2; exit 1 ;;
esac
[ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || {
  printf 'server.http: port is out of range: %s\n' "$port" >&2
  exit 1
}

body=$(curl --fail --silent --show-error -D "$scratch/headers" "${url}compat")
[ "$body" = compat-http ] || { printf 'server.http: response body mismatch\n' >&2; exit 1; }
tr -d '\r' < "$scratch/headers" |
  grep -i -x 'x-clun-evidence: present' >/dev/null 2>&1 || {
  printf 'server.http: evidence response header is missing\n' >&2
  exit 1
}
status=$(curl --silent --show-error --output "$scratch/missing" --write-out '%{http_code}' \
  "${url}missing")
[ "$status" = 404 ] || { printf 'server.http: expected 404, got %s\n' "$status" >&2; exit 1; }
[ "$(cat "$scratch/missing")" = missing ] || {
  printf 'server.http: 404 response body mismatch\n' >&2
  exit 1
}

# Streaming ReadableStream response bodies (Transfer-Encoding: chunked).
stream_body=$(curl --fail --silent --show-error -D "$scratch/stream.headers" \
  "${url}stream")
[ "$stream_body" = stream-yes ] || {
  printf 'server.http: stream body mismatch: %s\n' "$stream_body" >&2
  exit 1
}
tr -d '\r' < "$scratch/stream.headers" |
  grep -i -x 'transfer-encoding: chunked' >/dev/null 2>&1 || {
  printf 'server.http: expected Transfer-Encoding: chunked on /stream\n' >&2
  cat "$scratch/stream.headers" >&2
  exit 1
}

# Request body consumption.
echo_body=$(printf 'ping' | curl --fail --silent --show-error \
  -H 'content-type: text/plain' --data-binary @- "${url}echo")
[ "$echo_body" = echo:ping ] || {
  printf 'server.http: echo body mismatch: %s\n' "$echo_body" >&2
  exit 1
}

printf 'server.http: shipped binary served 200/header/body, 404, chunked stream, and POST echo evidence\n'
