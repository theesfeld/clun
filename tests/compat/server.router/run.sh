#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
[ -x "$clun" ] || { printf 'server.router: %s is missing\n' "$clun" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { printf 'server.router: curl is required\n' >&2; exit 2; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/clun-compat-router.XXXXXX")
printf '0123456789ABCDEF' >"$scratch/file.txt"
dd if=/dev/zero of="$scratch/large.bin" bs=1048576 count=16 2>/dev/null
ln -s "$scratch/file.txt" "$scratch/file-link.txt"
mkfifo "$scratch/file.fifo"
mkdir -p "$scratch/pages/posts/wow" "$scratch/pages/optional" \
  "$scratch/pages/files" "$scratch/outside" "$scratch/invalid-pages" \
  "$scratch/empty-pages"
for route in index posts posts/hey 'posts/[id]' 'posts/[...rest]' \
  'posts/wow/[[...id]]' 'optional/[[...parts]]'; do
  printf 'export default 1;\n' >"$scratch/pages/${route}.tsx"
done
index=0
while [ "$index" -lt 65 ]; do
  printf 'export default %s;\n' "$index" >"$scratch/pages/files/a${index}.tsx"
  index=$((index + 1))
done
printf 'ignored\n' >"$scratch/pages/ignored.txt"
printf 'outside\n' >"$scratch/outside/escape.tsx"
ln -s "$scratch/outside" "$scratch/pages/escape"
printf 'invalid\n' >"$scratch/invalid-pages/[foo.tsx"
server_pid=
cleanup() {
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
  [ -z "$server_pid" ] || wait "$server_pid" 2>/dev/null || true
  rm -rf "$scratch"
}
trap cleanup 0 HUP INT TERM

CLUN_ROUTER_FILE="$scratch/file.txt" \
CLUN_ROUTER_LARGE="$scratch/large.bin" \
CLUN_ROUTER_MISSING="$scratch/missing.txt" \
CLUN_ROUTER_SYMLINK="$scratch/file-link.txt" \
CLUN_ROUTER_SPECIAL="$scratch/file.fifo" \
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

curl --silent --show-error --dump-header "$scratch/file-headers" \
  --output "$scratch/file-body" "${url}file"
[ "$(cat "$scratch/file-body")" = '0123456789ABCDEF' ] || {
  printf 'server.router: file route body mismatch\n' >&2
  exit 1
}
file_headers=$(tr -d '\r' <"$scratch/file-headers")
printf '%s\n' "$file_headers" | grep -i -x 'content-length: 16' >/dev/null
printf '%s\n' "$file_headers" | grep -i -x 'content-type: text/plain;charset=utf-8' >/dev/null
last_modified=$(printf '%s\n' "$file_headers" | awk '
  BEGIN { IGNORECASE = 1 }
  /^last-modified:/ { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }
')
[ -n "$last_modified" ] || {
  printf 'server.router: file route omitted Last-Modified\n' >&2
  exit 1
}
assert_body file-direct 0123456789ABCDEF
status=$(curl --silent --show-error --dump-header "$scratch/slice-headers" \
  --output "$scratch/slice-body" --write-out '%{http_code}' \
  -H 'Range: bytes=12-15' "${url}file-slice")
if [ "$status" != 200 ] || [ "$(cat "$scratch/slice-body")" != 56789 ] || \
    tr -d '\r' <"$scratch/slice-headers" | grep -i '^content-range:' >/dev/null; then
    printf 'server.router: Range escaped or altered the explicit file slice\n' >&2
    exit 1
fi

assert_range() {
  value=$1
  expected_status=$2
  expected_body=$3
  expected_range=$4
  status=$(curl --silent --show-error --dump-header "$scratch/range-headers" \
    --output "$scratch/range-body" --write-out '%{http_code}' \
    -H "Range: $value" "${url}file")
  actual_body=$(cat "$scratch/range-body")
  actual_range=$(tr -d '\r' <"$scratch/range-headers" | awk '
    BEGIN { IGNORECASE = 1 }
    /^content-range:/ { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }
  ')
  [ "$status" = "$expected_status" ] && [ "$actual_body" = "$expected_body" ] && \
    [ "$actual_range" = "$expected_range" ] || {
      printf 'server.router: range %s: got status=%s body=%s range=%s\n' \
        "$value" "$status" "$actual_body" "$actual_range" >&2
      exit 1
    }
}

assert_range 'bytes=0-3' 206 0123 'bytes 0-3/16'
assert_range 'bytes=4-' 206 456789ABCDEF 'bytes 4-15/16'
assert_range 'bytes=-4' 206 CDEF 'bytes 12-15/16'
assert_range 'Bytes = 2-5' 206 2345 'bytes 2-5/16'
assert_range 'bytes=100-200' 416 '' 'bytes */16'

status=$(curl --silent --show-error --output "$scratch/file-ims" --write-out '%{http_code}' \
  -H 'If-Modified-Since: Thu, 31 Dec 2099 23:59:59 GMT' "${url}file")
[ "$status" = 304 ] && [ ! -s "$scratch/file-ims" ] || {
  printf 'server.router: file If-Modified-Since did not produce 304\n' >&2
  exit 1
}
status=$(curl --silent --show-error --output "$scratch/file-star" --write-out '%{http_code}' \
  -H 'If-None-Match: *' "${url}file")
[ "$status" = 304 ] && [ ! -s "$scratch/file-star" ] || {
  printf 'server.router: file If-None-Match wildcard did not produce 304\n' >&2
  exit 1
}
status=$(curl --silent --show-error --output "$scratch/file-precedence" --write-out '%{http_code}' \
  -H 'If-None-Match: "not-a-match"' \
  -H 'If-Modified-Since: Thu, 31 Dec 2099 23:59:59 GMT' "${url}file")
[ "$status" = 200 ] && [ "$(cat "$scratch/file-precedence")" = '0123456789ABCDEF' ] || {
  printf 'server.router: If-None-Match did not take precedence over If-Modified-Since\n' >&2
  exit 1
}
status=$(curl --silent --show-error --output "$scratch/file-custom" --write-out '%{http_code}' \
  -H 'If-None-Match: "file-custom"' "${url}file-custom")
[ "$status" = 304 ] && [ ! -s "$scratch/file-custom" ] || {
  printf 'server.router: custom file ETag did not produce 304\n' >&2
  exit 1
}
content_range=$(curl --silent --show-error --dump-header "$scratch/user-range-headers" \
  --output "$scratch/user-range-body" -H 'Range: bytes=2-5' "${url}file-content-range" && \
  tr -d '\r' <"$scratch/user-range-headers" | awk '
    BEGIN { IGNORECASE = 1 }
    /^content-range:/ { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }
  ')
[ "$content_range" = 'bytes 0-15/100' ] && \
  [ "$(cat "$scratch/user-range-body")" = '0123456789ABCDEF' ] || {
    printf 'server.router: user Content-Range did not disable automatic range handling\n' >&2
    exit 1
  }

curl --silent --show-error --output /dev/null "${url}large-file"
curl --silent --show-error --limit-rate 32768 --max-time 0.2 \
  --output /dev/null "${url}large-file" 2>/dev/null || true
sleep 0.1
assert_body api/users exact

printf 'updated-file' >"$scratch/file.txt"
assert_body file updated-file
rm "$scratch/file.txt"
status=$(curl --silent --show-error --output "$scratch/deleted-file" --write-out '%{http_code}' \
  "${url}file")
[ "$status" = 202 ] && [ "$(cat "$scratch/deleted-file")" = 'fallback:GET:/file' ] || {
  printf 'server.router: deleted file route did not re-stat and fall through\n' >&2
  exit 1
}
printf '0123456789ABCDEF' >"$scratch/file.txt"

for unsafe_path in missing-file symlink-file special-file; do
  status=$(curl --silent --show-error --output "$scratch/unsafe-body" --write-out '%{http_code}' \
    "${url}${unsafe_path}")
  [ "$status" = 202 ] && \
    [ "$(cat "$scratch/unsafe-body")" = "fallback:GET:/${unsafe_path}" ] || {
      printf 'server.router: %s did not fall through safely\n' "$unsafe_path" >&2
      exit 1
    }
done

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

CLUN_ROUTER_PAGES="$scratch/pages" \
CLUN_ROUTER_INVALID_PAGES="$scratch/invalid-pages" \
CLUN_ROUTER_EMPTY_PAGES="$scratch/empty-pages" \
  "$clun" "$repo_root/tests/compat/server.router/filesystem.js"

printf 'server.router: routes, static/file caching, ranges, bounded streaming, safety, async, fallback, HEAD, and reload passed\n'
