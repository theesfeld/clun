#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
[ -x "$clun" ] || { printf 'server.router: %s is missing\n' "$clun" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { printf 'server.router: curl is required\n' >&2; exit 2; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/clun-compat-router.XXXXXX")
printf '0123456789ABCDEF' >"$scratch/file.txt"
: >"$scratch/empty.txt"
printf '\000\001\002\003\377\376\375' >"$scratch/binary.bin"
printf '{"message":"test","number":42}\n' >"$scratch/data.json"
printf 'Hello \344\270\226\347\225\214 \360\237\214\215 \303\251mojis' >"$scratch/unicode.txt"
dd if=/dev/zero of="$scratch/large.bin" bs=1048576 count=16 2>/dev/null
ln -s "$scratch/file.txt" "$scratch/file-link.txt"
mkfifo "$scratch/file.fifo"
mkdir -p "$scratch/pages/posts/wow" "$scratch/pages/optional" \
  "$scratch/pages/files" "$scratch/outside" "$scratch/invalid-pages" \
  "$scratch/empty-pages" "$scratch/stress-pages"
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
if [ "$(uname -s)" = Linux ]; then
  mkdir -p "$scratch/raw-pages"
  raw_byte=$(printf '\377')
  printf 'export default 1;\n' >"$scratch/raw-pages/a${raw_byte}.tsx"
  printf 'export default 2;\n' >"$scratch/raw-pages/ab.tsx"
  printf 'export default 3;\n' >"$scratch/raw-pages/${raw_byte}.tsx"
fi
index=0
while [ "$index" -lt 128 ]; do
  mkdir -p "$scratch/stress-pages/route$index"
  printf 'export default %s;\n' "$index" >"$scratch/stress-pages/route$index/index.tsx"
  index=$((index + 1))
done
mkdir -p "$scratch/stress-pages/[a]/[b]/[c]"
printf 'export default 1;\n' >"$scratch/stress-pages/[a]/[b]/[c]/[d].tsx"
server_pid=
cleanup() {
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
  [ -z "$server_pid" ] || wait "$server_pid" 2>/dev/null || true
  rm -rf "$scratch"
}
trap cleanup 0 HUP INT TERM

CLUN_ROUTER_FILE="$scratch/file.txt" \
CLUN_ROUTER_EMPTY="$scratch/empty.txt" \
CLUN_ROUTER_BINARY="$scratch/binary.bin" \
CLUN_ROUTER_JSON="$scratch/data.json" \
CLUN_ROUTER_UNICODE="$scratch/unicode.txt" \
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

"$clun" "$repo_root/tests/compat/server.router/server-fetch.js" \
  | grep -x 'server.router: server.fetch API passed' >/dev/null

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
assert_body legacy-static legacy-static
curl --silent --show-error --head "${url}legacy-static" >"$scratch/legacy-static-head"
tr -d '\r' <"$scratch/legacy-static-head" | grep -i -x 'content-length: 13' >/dev/null

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
status=$(curl --silent --show-error --dump-header "$scratch/created-headers" \
  --output "$scratch/created-body" --write-out '%{http_code}' "${url}static-created")
if [ "$status" != 201 ] || [ "$(cat "$scratch/created-body")" != created ] || \
    ! tr -d '\r' <"$scratch/created-headers" | grep -i -x 'x-created: yes' >/dev/null; then
  printf 'server.router: static custom status/header/body were not preserved\n' >&2
  exit 1
fi

for _ in 1 2 3 4 5 6 7 8 9 10; do
  assert_body static static
done

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
status=$(curl --silent --show-error --dump-header "$scratch/empty-headers" \
  --output "$scratch/empty-body" --write-out '%{http_code}' "${url}file-empty")
if [ "$status" != 200 ] || [ -s "$scratch/empty-body" ] || \
    ! tr -d '\r' <"$scratch/empty-headers" | grep -i -x 'content-length: 0' >/dev/null; then
  printf 'server.router: empty file was not a zero-byte 200 representation\n' >&2
  exit 1
fi
status=$(curl --silent --show-error --output "$scratch/empty-400-body" \
  --write-out '%{http_code}' "${url}file-empty-400")
[ "$status" = 400 ] && [ ! -s "$scratch/empty-400-body" ] || {
  printf 'server.router: empty file custom status was not preserved\n' >&2
  exit 1
}
curl --fail --silent --show-error --output "$scratch/binary-body" "${url}file-binary"
cmp "$scratch/binary.bin" "$scratch/binary-body"
assert_body file-json '{"message":"test","number":42}'
assert_body file-unicode 'Hello 世界 🌍 émojis'
status=$(curl --silent --show-error --dump-header "$scratch/slice-headers" \
  --output "$scratch/slice-body" --write-out '%{http_code}' \
  -H 'Range: bytes=12-15' "${url}file-slice")
if [ "$status" != 200 ] || [ "$(cat "$scratch/slice-body")" != 56789 ] || \
    tr -d '\r' <"$scratch/slice-headers" | grep -i '^content-range:' >/dev/null; then
    printf 'server.router: Range escaped or altered the explicit file slice\n' >&2
    exit 1
fi

assert_range() {
  path=$1
  value=$2
  expected_status=$3
  expected_body=$4
  expected_range=$5
  status=$(curl --silent --show-error --dump-header "$scratch/range-headers" \
    --output "$scratch/range-body" --write-out '%{http_code}' \
    -H "Range: $value" "${url}${path}")
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

assert_range file 'bytes=0-3' 206 0123 'bytes 0-3/16'
assert_range file 'bytes=4-' 206 456789ABCDEF 'bytes 4-15/16'
assert_range file 'bytes=-4' 206 CDEF 'bytes 12-15/16'
assert_range file 'bytes=0-999' 206 0123456789ABCDEF 'bytes 0-15/16'
assert_range file 'Bytes = 2-5' 206 2345 'bytes 2-5/16'
assert_range file 'bytes=100-200' 416 '' 'bytes */16'
assert_range dynamic-file 'bytes=0-3' 206 0123 'bytes 0-3/16'
assert_range dynamic-file 'bytes=100-200' 416 '' 'bytes */16'

status=$(curl --silent --show-error --dump-header "$scratch/dynamic-range-headers" \
  --output "$scratch/dynamic-range-body" --write-out '%{http_code}' \
  -H 'Range: bytes=0-3' "${url}dynamic-range-custom")
if [ "$status" != 206 ] || [ "$(cat "$scratch/dynamic-range-body")" != 0123 ] || \
    ! tr -d '\r' <"$scratch/dynamic-range-headers" | grep -i -x 'cache-control: max-age=3600' >/dev/null || \
    ! tr -d '\r' <"$scratch/dynamic-range-headers" | grep -i -x 'x-custom: abc' >/dev/null; then
  printf 'server.router: handler range did not preserve custom headers\n' >&2
  exit 1
fi

status=$(curl --silent --show-error --dump-header "$scratch/post-range-headers" \
  --output "$scratch/post-range-body" --write-out '%{http_code}' \
  -X POST -H 'Range: bytes=0-3' "${url}dynamic-file")
if [ "$status" != 200 ] || [ "$(cat "$scratch/post-range-body")" != 0123456789ABCDEF ] || \
    tr -d '\r' <"$scratch/post-range-headers" | grep -i '^content-range:' >/dev/null; then
  printf 'server.router: non-GET Range was not ignored\n' >&2
  exit 1
fi

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
status=$(curl --silent --show-error --output "$scratch/file-custom-last-modified" \
  --write-out '%{http_code}' -H 'If-Modified-Since: Wed, 21 Oct 2015 07:28:00 GMT' \
  "${url}file-last-modified")
[ "$status" = 304 ] && [ ! -s "$scratch/file-custom-last-modified" ] || {
  printf 'server.router: custom Last-Modified did not drive conditional handling\n' >&2
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

dynamic_content_range=$(curl --silent --show-error --dump-header "$scratch/dynamic-user-range-headers" \
  --output "$scratch/dynamic-user-range-body" -H 'Range: bytes=2-5' \
  "${url}dynamic-content-range" && tr -d '\r' <"$scratch/dynamic-user-range-headers" | awk '
    BEGIN { IGNORECASE = 1 }
    /^content-range:/ { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }
  ')
[ "$dynamic_content_range" = 'bytes 0-15/100' ] && \
  [ "$(cat "$scratch/dynamic-user-range-body")" = '0123456789ABCDEF' ] || {
    printf 'server.router: handler Content-Range did not disable automatic range handling\n' >&2
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
[ "$status" = 202 ] && [ "$(cat "$scratch/deleted-file")" = "fallback:GET:${url}file" ] || {
  printf 'server.router: deleted file route did not re-stat and fall through\n' >&2
  exit 1
}
printf '0123456789ABCDEF' >"$scratch/file.txt"

for unsafe_path in missing-file symlink-file special-file; do
  status=$(curl --silent --show-error --output "$scratch/unsafe-body" --write-out '%{http_code}' \
    "${url}${unsafe_path}")
  [ "$status" = 202 ] && \
    [ "$(cat "$scratch/unsafe-body")" = "fallback:GET:${url}${unsafe_path}" ] || {
      printf 'server.router: %s did not fall through safely\n' "$unsafe_path" >&2
      exit 1
    }
done

assert_body api/users exact
assert_body api/users/alice%40example.com 'param:alice@example.com'
assert_body api/users/%C3%A9 'param:é'
assert_body api/multi/456/comments/789 '456:789'
assert_body api/unknown/deep 'wild:unknown/deep'
assert_body method 'get:GET'
assert_body method post POST

for method in GET POST PUT DELETE PATCH OPTIONS; do
  assert_body method-all "$method" "$method"
done

curl --silent --show-error --head "${url}method-all" >"$scratch/explicit-head"
tr -d '\r' <"$scratch/explicit-head" | grep -i -x 'x-explicit-head: handler' >/dev/null
curl --silent --show-error --head "${url}head-get" >"$scratch/derived-head"
tr -d '\r' <"$scratch/derived-head" | grep -i -x 'content-length: 9' >/dev/null
tr -d '\r' <"$scratch/derived-head" | grep -i -x 'x-seen-method: HEAD' >/dev/null
curl --silent --show-error --head "${url}head-static" >"$scratch/static-head"
tr -d '\r' <"$scratch/static-head" | grep -i -x 'x-explicit-head: static' >/dev/null
assert_body head-mixed mixed-post POST
status=$(curl --silent --show-error --head --output "$scratch/post-only-head" --write-out '%{http_code}' \
  "${url}post-only")
[ "$status" = 202 ] || { printf 'server.router: HEAD was incorrectly derived without GET\n' >&2; exit 1; }
status=$(curl --silent --show-error --head --output "$scratch/post-only-static-head" --write-out '%{http_code}' \
  "${url}post-only-static")
[ "$status" = 202 ] || { printf 'server.router: static HEAD was incorrectly derived without GET\n' >&2; exit 1; }

actual=$(curl --fail --silent --show-error -H 'x-test: present' "${url}echo-header")
[ "$actual" = present ] || { printf 'server.router: request header was not preserved\n' >&2; exit 1; }
actual=$(curl --fail --silent --show-error -X POST --data-binary 'body-content' "${url}echo-body")
[ "$actual" = body-content ] || { printf 'server.router: request body was not preserved\n' >&2; exit 1; }
actual=$(curl --fail --silent --show-error "${url}echo-query?foo=bar&baz=qux")
[ "$actual" = "${url}echo-query?foo=bar&baz=qux" ] || {
  printf 'server.router: request query was not preserved: %s\n' "$actual" >&2
  exit 1
}

many_path=many
index=1
while [ "$index" -le 65 ]; do
  many_path="$many_path/value$index"
  index=$((index + 1))
done
assert_body "$many_path" '65:value1:value65'

absolute_body=$(curl --fail --silent --show-error \
  --request-target 'https://spoofed.example/absolute/secret?x=1' \
  -H "Host: 127.0.0.1" "$url")
[ "$absolute_body" = 'http://127.0.0.1/absolute/secret?x=1' ] || {
  printf 'server.router: absolute-form target routing/Host URL derivation failed: %s\n' \
    "$absolute_body" >&2
  exit 1
}

status=$(curl --silent --show-error --output "$scratch/put" --write-out '%{http_code}' \
  -X PUT "${url}method")
[ "$status" = 202 ] && [ "$(cat "$scratch/put")" = "fallback:PUT:${url}method" ] || {
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
status=$(curl --silent --show-error --output "$scratch/async-error" --write-out '%{http_code}' \
  "${url}async-error")
[ "$status" = 500 ] && [ "$(cat "$scratch/async-error")" = 'error:async-route-failure' ] || {
  printf 'server.router: async route error did not reach the error handler\n' >&2
  exit 1
}

status=$(curl --silent --show-error --output "$scratch/skip" --write-out '%{http_code}' \
  "${url}skip")
[ "$status" = 202 ] && [ "$(cat "$scratch/skip")" = "fallback:GET:${url}skip" ] || {
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
CLUN_ROUTER_STRESS_PAGES="$scratch/stress-pages" \
  "$clun" "$repo_root/tests/compat/server.router/filesystem-stress.js"
if [ "$(uname -s)" = Linux ]; then
  CLUN_ROUTER_RAW_PAGES="$scratch/raw-pages" \
    "$clun" "$repo_root/tests/compat/server.router/filesystem-raw-filenames.js"
fi
"$clun" "$repo_root/tests/compat/server.router/validation.js"

printf 'server.router: routes, static/file caching, ranges, bounded streaming, safety, async, fallback, HEAD, and reload passed\n'
