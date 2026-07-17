#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
[ -x "$clun" ] || { printf 'server.router: %s is missing\n' "$clun" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { printf 'server.router: curl is required\n' >&2; exit 2; }
command -v ps >/dev/null 2>&1 || { printf 'server.router: ps is required\n' >&2; exit 2; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/clun-compat-router.XXXXXX")
printf '0123456789ABCDEF' >"$scratch/file.txt"
: >"$scratch/empty.txt"
printf '\000\001\002\003\377\376\375' >"$scratch/binary.bin"
printf '{"message":"test","number":42}\n' >"$scratch/data.json"
printf 'Hello \344\270\226\347\225\214 \360\237\214\215 \303\251mojis' >"$scratch/unicode.txt"
mkdir -p "$scratch/nested"
printf 'nested-file' >"$scratch/nested/deep.txt"
printf 'special-file' >"$scratch/special chars & file.txt"
dd if=/dev/zero of="$scratch/large.bin" bs=1048576 count=16 2>/dev/null
ln -s "$scratch/file.txt" "$scratch/file-link.txt"
mkfifo "$scratch/file.fifo"
mkdir -p "$scratch/pages/posts/wow" "$scratch/pages/optional" \
  "$scratch/pages/precedence/[id]" "$scratch/pages/precedence/static" \
  "$scratch/pages/files" "$scratch/outside" "$scratch/invalid-pages" \
  "$scratch/empty-pages" "$scratch/stress-pages"
for route in index posts posts/hey 'posts/[id]' 'posts/[...rest]' \
  'posts/wow/[[...id]]' 'optional/[[...parts]]'; do
  printf 'export default 1;\n' >"$scratch/pages/${route}.tsx"
done
printf 'export default 1;\n' >"$scratch/pages/precedence/[id]/tail.tsx"
printf 'export default 2;\n' >"$scratch/pages/precedence/static/[id].tsx"
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
CLUN_ROUTER_NESTED="$scratch/nested/deep.txt" \
CLUN_ROUTER_SPECIAL_NAME="$scratch/special chars & file.txt" \
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

server_rss_kib() {
  rss=$(LC_ALL=C ps -o rss= -p "$server_pid" | awk 'NF { print $1; exit }')
  case "$rss" in
    ''|*[!0-9]*)
      printf 'server.router: could not measure server RSS: %s\n' "$rss" >&2
      exit 1
      ;;
  esac
  printf '%s\n' "$rss"
}

assert_body static static # contract:serve.static.response
assert_body static static # contract:static.string.unchanged
assert_body legacy-static legacy-static
curl --silent --show-error --head "${url}legacy-static" >"$scratch/legacy-static-head"
tr -d '\r' <"$scratch/legacy-static-head" | grep -i -x 'content-length: 13' >/dev/null

curl --silent --show-error --dump-header "$scratch/static-headers-1" \
  --output "$scratch/static-body-1" "${url}static"
etag=$(tr -d '\r' <"$scratch/static-headers-1" | awk '
  tolower($0) ~ /^etag:/ { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }
')
[ -n "$etag" ] && [ "$(cat "$scratch/static-body-1")" = static ] || {
  printf 'server.router: static response did not publish an ETag and body\n' >&2
  exit 1
}
curl --silent --show-error --dump-header "$scratch/static-headers-2" \
  --output "$scratch/static-body-2" "${url}static"
etag_again=$(tr -d '\r' <"$scratch/static-headers-2" | awk '
  tolower($0) ~ /^etag:/ { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }
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

tr -d '\r' <"$scratch/static-headers-1" | \
  grep -i -x 'content-type: text/plain;charset=utf-8' >/dev/null
assert_body static-explicit-type typed
curl --silent --show-error --head "${url}static-explicit-type" >"$scratch/static-type-head"
tr -d '\r' <"$scratch/static-type-head" | grep -i -x 'content-type: text/foo' >/dev/null
assert_body static-json '{"a":1}'
curl --silent --show-error --head "${url}static-json" >"$scratch/static-json-head"
tr -d '\r' <"$scratch/static-json-head" | \
  grep -i -x 'content-type: application/json;charset=utf-8' >/dev/null
curl --fail --silent --show-error --output "$scratch/static-bytes-body" "${url}static-bytes"
printf '\001\002\003' >"$scratch/static-bytes-expected"
cmp "$scratch/static-bytes-expected" "$scratch/static-bytes-body"
curl --silent --show-error --head "${url}static-bytes" >"$scratch/static-bytes-head"
if tr -d '\r' <"$scratch/static-bytes-head" | grep -i '^content-type:' >/dev/null; then
  printf 'server.router: byte static response invented a Content-Type\n' >&2
  exit 1
fi
assert_body shared-a shared-static # contract:static.get
assert_body shared-b shared-static
for blob_path in static-blob-a static-blob-b; do
  assert_body "$blob_path" '<h1>hi</h1>'
  curl --silent --show-error --head "${url}${blob_path}" >"$scratch/$blob_path-head"
  tr -d '\r' <"$scratch/$blob_path-head" | \
    grep -i -x 'content-type: text/html;charset=utf-8' >/dev/null
done
assert_body static-blob-touched touched # contract:static.blob.headers-read
curl --silent --show-error --head "${url}static-blob-touched" >"$scratch/static-blob-touched-head"
tr -d '\r' <"$scratch/static-blob-touched-head" | \
  grep -i -x 'content-type: text/html;charset=utf-8' >/dev/null

status=$(curl --silent --show-error --dump-header "$scratch/redirect-headers" \
  --output "$scratch/redirect-body" --write-out '%{http_code}' "${url}redirect")
if [ "$status" != 302 ] || [ -s "$scratch/redirect-body" ] || \
    ! tr -d '\r' <"$scratch/redirect-headers" | grep -i -x 'location: /foo/bar' >/dev/null; then
  printf 'server.router: static redirect metadata/body mismatch\n' >&2
  exit 1
fi
assert_body foo/bar /foo/bar
redirected=$(curl --fail --silent --show-error --location "${url}redirect")
[ "$redirected" = /foo/bar ] || {
  printf 'server.router: static redirect did not follow to another route\n' >&2
  exit 1
}
redirected=$(curl --fail --silent --show-error --location "${url}redirect/fallback")
[ "$redirected" = "fallback:GET:${url}foo/bar/fallback" ] || {
  printf 'server.router: redirect target did not fall through to fetch\n' >&2
  exit 1
}

curl --silent --show-error --head "${url}static-big" >"$scratch/static-big-head"
tr -d '\r' <"$scratch/static-big-head" | grep -i -x 'content-length: 4194304' >/dev/null
pids=
index=1
while [ "$index" -le 12 ]; do
  curl --fail --silent --show-error --output "$scratch/static-big-$index" \
    "${url}static-big" &
  pids="$pids $!"
  index=$((index + 1))
done
for pid in $pids; do wait "$pid"; done
index=1
while [ "$index" -le 12 ]; do
  [ "$(wc -c <"$scratch/static-big-$index" | tr -d ' ')" = 4194304 ] || {
    printf 'server.router: concurrent large static response was truncated\n' >&2
    exit 1
  }
  index=$((index + 1))
done

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
  tolower($0) ~ /^last-modified:/ { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }
')
[ -n "$last_modified" ] || {
  printf 'server.router: file route omitted Last-Modified\n' >&2
  exit 1
}
curl --silent --show-error --head "${url}file-custom" >"$scratch/file-custom-head"
tr -d '\r' <"$scratch/file-custom-head" | \
  grep -i -x 'x-file: custom' >/dev/null # contract:file.custom-headers
assert_body file-direct 0123456789ABCDEF # contract:file.get
assert_body file-direct 0123456789ABCDEF # contract:file.slice.complete
status=$(curl --silent --show-error --dump-header "$scratch/empty-headers" \
  --output "$scratch/empty-body" --write-out '%{http_code}' "${url}file-empty")
if [ "$status" != 200 ] || [ -s "$scratch/empty-body" ] || \
    ! tr -d '\r' <"$scratch/empty-headers" | grep -i -x 'content-length: 0' >/dev/null; then
  printf 'server.router: empty file was not a zero-byte 200 representation\n' >&2
  exit 1
fi
status=$(curl --silent --show-error --dump-header "$scratch/dynamic-empty-get-headers" \
  --output "$scratch/dynamic-empty-get-body" --write-out '%{http_code}' "${url}dynamic-empty")
if [ "$status" != 200 ] || [ -s "$scratch/dynamic-empty-get-body" ] || \
    ! tr -d '\r' <"$scratch/dynamic-empty-get-headers" | grep -i -x 'content-length: 0' >/dev/null; then
  printf 'server.router: dynamic empty file GET response mismatch\n' >&2
  exit 1
fi
status=$(curl --silent --show-error --head --output "$scratch/dynamic-empty-head" \
  --write-out '%{http_code}' "${url}dynamic-empty")
if [ "$status" != 200 ] || \
    ! tr -d '\r' <"$scratch/dynamic-empty-head" | grep -i -x 'content-length: 0' >/dev/null; then
  printf 'server.router: dynamic empty file HEAD response mismatch\n' >&2
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
curl --silent --show-error --head "${url}file-binary" >"$scratch/binary-head"
tr -d '\r' <"$scratch/binary-head" | grep -i -x 'content-type: application/octet-stream' >/dev/null
assert_body file-json '{"message":"test","number":42}'
curl --silent --show-error --head "${url}file-json" >"$scratch/json-head"
tr -d '\r' <"$scratch/json-head" | grep -i -x 'content-type: application/json;charset=utf-8' >/dev/null
tr -d '\r' <"$scratch/json-head" | \
  grep -i -x 'content-type: application/json;charset=utf-8' >/dev/null # contract:file.mime.json
assert_body file-unicode 'Hello 世界 🌍 émojis' # contract:file.unicode
assert_body file-nested nested-file
assert_body file-special-name special-file
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
    tolower($0) ~ /^content-range:/ { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }
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
assert_range range-after-size 'bytes=4-7' 206 4567 'bytes 4-7/16'

for path in file dynamic-file; do
  status=$(curl --silent --show-error --dump-header "$scratch/multi-range-headers" \
    --output "$scratch/multi-range-body" --write-out '%{http_code}' \
    -H 'Range: bytes=0-1,4-5' "${url}${path}")
  if [ "$status" != 200 ] || \
      [ "$(cat "$scratch/multi-range-body")" != 0123456789ABCDEF ] || \
      tr -d '\r' <"$scratch/multi-range-headers" | grep -i '^content-range:' >/dev/null; then
    printf 'server.router: multi-range request was not ignored for %s\n' "$path" >&2
    exit 1
  fi
done

status=$(curl --silent --show-error --dump-header "$scratch/dynamic-range-headers" \
  --output "$scratch/dynamic-range-body" --write-out '%{http_code}' \
  -H 'Range: bytes=0-3' "${url}dynamic-range-custom")
if [ "$status" != 206 ] || [ "$(cat "$scratch/dynamic-range-body")" != 0123 ] || \
    ! tr -d '\r' <"$scratch/dynamic-range-headers" | grep -i -x 'cache-control: max-age=3600' >/dev/null || \
    ! tr -d '\r' <"$scratch/dynamic-range-headers" | grep -i -x 'x-custom: abc' >/dev/null; then
  printf 'server.router: handler range did not preserve custom headers\n' >&2
  exit 1
fi

status=$(curl --silent --show-error --dump-header "$scratch/unsatisfied-range-headers" \
  --output "$scratch/unsatisfied-range-body" --write-out '%{http_code}' \
  -H 'Range: bytes=100-200' "${url}dynamic-range-custom")
if [ "$status" != 416 ] || [ -s "$scratch/unsatisfied-range-body" ] || \
    ! tr -d '\r' <"$scratch/unsatisfied-range-headers" | grep -i -x 'cache-control: max-age=3600' >/dev/null || \
    ! tr -d '\r' <"$scratch/unsatisfied-range-headers" | grep -i -x 'x-custom: abc' >/dev/null || \
    ! tr -d '\r' <"$scratch/unsatisfied-range-headers" | grep -i -x 'accept-ranges: bytes' >/dev/null || \
    ! tr -d '\r' <"$scratch/unsatisfied-range-headers" | grep -i -F -x 'content-range: bytes */16' >/dev/null; then
  printf 'server.router: 416 response did not preserve custom and range headers\n' >&2
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
status=$(curl --silent --show-error --head --output "$scratch/file-ims-head" --write-out '%{http_code}' \
  -H 'If-Modified-Since: Thu, 31 Dec 2099 23:59:59 GMT' "${url}file")
[ "$status" = 304 ] && ! tr -d '\r' <"$scratch/file-ims-head" | grep -i '^content-length:' >/dev/null || {
  printf 'server.router: HEAD If-Modified-Since did not produce header-only 304\n' >&2
  exit 1
}
status=$(curl --silent --show-error --output "$scratch/file-ims-past" --write-out '%{http_code}' \
  -H 'If-Modified-Since: Tue, 01 Jan 1980 00:00:00 GMT' "${url}file")
[ "$status" = 200 ] && [ "$(cat "$scratch/file-ims-past")" = '0123456789ABCDEF' ] || {
  printf 'server.router: past If-Modified-Since incorrectly suppressed file\n' >&2
  exit 1
}
status=$(curl --silent --show-error --dump-header "$scratch/file-ims-range-headers" \
  --output "$scratch/file-ims-range" --write-out '%{http_code}' \
  -H 'If-Modified-Since: Thu, 31 Dec 2099 23:59:59 GMT' -H 'Range: bytes=0-3' "${url}file")
[ "$status" = 304 ] && [ ! -s "$scratch/file-ims-range" ] && \
  ! tr -d '\r' <"$scratch/file-ims-range-headers" | grep -i '^content-range:' >/dev/null || {
  printf 'server.router: If-Modified-Since did not take precedence over Range\n' >&2
  exit 1
}
status=$(curl --silent --show-error --output "$scratch/file-post-ims" --write-out '%{http_code}' \
  -X POST -H 'If-Modified-Since: Thu, 31 Dec 2099 23:59:59 GMT' "${url}dynamic-file")
[ "$status" = 200 ] && [ "$(cat "$scratch/file-post-ims")" = '0123456789ABCDEF' ] || {
  printf 'server.router: POST incorrectly applied If-Modified-Since\n' >&2
  exit 1
}
status=$(curl --silent --show-error --output "$scratch/file-star" --write-out '%{http_code}' \
  -H 'If-None-Match: *' "${url}file")
[ "$status" = 304 ] && [ ! -s "$scratch/file-star" ] || {
  printf 'server.router: file If-None-Match wildcard did not produce 304\n' >&2
  exit 1
}
status=$(curl --silent --show-error --output "$scratch/file-star-ims" --write-out '%{http_code}' \
  -H 'If-None-Match: *' -H 'If-Modified-Since: Tue, 01 Jan 1980 00:00:00 GMT' "${url}file")
[ "$status" = 304 ] && [ ! -s "$scratch/file-star-ims" ] || {
  printf 'server.router: If-None-Match wildcard lost precedence over date\n' >&2
  exit 1
}
status=$(curl --silent --show-error --output "$scratch/file-post-star" --write-out '%{http_code}' \
  -X POST -H 'If-None-Match: *' "${url}dynamic-file")
[ "$status" = 200 ] && [ "$(cat "$scratch/file-post-star")" = '0123456789ABCDEF' ] || {
  printf 'server.router: POST incorrectly applied If-None-Match\n' >&2
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
status=$(curl --silent --show-error --output "$scratch/file-custom-miss" --write-out '%{http_code}' \
  -H 'If-None-Match: "other"' "${url}file-custom")
[ "$status" = 200 ] && [ "$(cat "$scratch/file-custom-miss")" = '0123456789ABCDEF' ] || {
  printf 'server.router: nonmatching custom ETag suppressed the representation\n' >&2
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
    tolower($0) ~ /^content-range:/ { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }
  ')
[ "$content_range" = 'bytes 0-15/100' ] && \
  [ "$(cat "$scratch/user-range-body")" = '0123456789ABCDEF' ] || {
    printf 'server.router: user Content-Range did not disable automatic range handling\n' >&2
    exit 1
  }

dynamic_content_range=$(curl --silent --show-error --dump-header "$scratch/dynamic-user-range-headers" \
  --output "$scratch/dynamic-user-range-body" -H 'Range: bytes=2-5' \
  "${url}dynamic-content-range" && tr -d '\r' <"$scratch/dynamic-user-range-headers" | awk '
    tolower($0) ~ /^content-range:/ { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }
  ')
[ "$dynamic_content_range" = 'bytes 0-15/100' ] && \
  [ "$(cat "$scratch/dynamic-user-range-body")" = '0123456789ABCDEF' ] || {
    printf 'server.router: handler Content-Range did not disable automatic range handling\n' >&2
    exit 1
  }

CLUN_ROUTER_URL="$url" "$clun" \
  "$repo_root/tests/compat/server.router/static-contracts.js" |
  grep -x 'server.router: static clone and concurrent body API matrix passed' >/dev/null

curl --silent --show-error --output /dev/null "${url}large-file"
index=0
while [ "$index" -lt 5 ]; do
  curl --fail --silent --show-error --output /dev/null "${url}large-file"
  index=$((index + 1))
done
assert_body gc gc
large_rss_before=$(server_rss_kib)
index=0
while [ "$index" -lt 50 ]; do
  curl --fail --silent --show-error --output /dev/null "${url}large-file"
  index=$((index + 1))
done
assert_body gc gc
large_rss_after=$(server_rss_kib)
large_rss_growth=$((large_rss_after - large_rss_before))
[ "$large_rss_growth" -lt $((100 * 1024)) ] || {
  printf 'server.router: 50 large file responses grew RSS by %s KiB (limit <102400 KiB)\n' \
    "$large_rss_growth" >&2
  exit 1
}

index=0
while [ "$index" -lt 50 ]; do
  curl --fail --silent --show-error --output /dev/null "${url}static-big"
  index=$((index + 1))
done
assert_body gc gc
static_rss=$(server_rss_kib)
[ "$static_rss" -lt $((4092 * 1024)) ] || {
  printf 'server.router: static response RSS was %s KiB (limit <4190208 KiB)\n' \
    "$static_rss" >&2
  exit 1
}
printf 'server.router resources: 50 large-file cycles RSS delta=%s KiB; 50 static cycles RSS=%s KiB\n' \
  "$large_rss_growth" "$static_rss"

pids=
index=1
while [ "$index" -le 16 ]; do
  curl --fail --silent --show-error --output "$scratch/large-file-$index" "${url}large-file" &
  pids="$pids $!"
  index=$((index + 1))
done
for pid in $pids; do wait "$pid"; done
index=1
while [ "$index" -le 16 ]; do
  [ "$(wc -c <"$scratch/large-file-$index" | tr -d ' ')" = 16777216 ] || {
    printf 'server.router: concurrent large file response was truncated\n' >&2
    exit 1
  }
  index=$((index + 1))
done
[ "$(wc -c <"$scratch/large-file-1" | tr -d ' ')" = 16777216 ] # contract:file.concurrent
curl --silent --show-error --limit-rate 32768 --max-time 0.2 \
  --output /dev/null "${url}large-file" 2>/dev/null || true
sleep 0.1
assert_body api/users exact # contract:serve.precedence.exact

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

assert_body api/users exact # contract:serve.precedence.any
assert_body api/users/alice%40example.com 'param:alice@example.com' # contract:serve.params.single
assert_body api/users/%61lice%40example.com 'param:alice@example.com' # contract:serve.params.encoded
assert_body api/users/42 'param:42' # contract:serve.precedence.parameter
assert_body api/users/%C3%A9 'param:é' # contract:serve.params.unicode
assert_body api/multi/456/comments/789 '456:789'
assert_body api/users/alice/posts 'posts:alice'
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

assert_body reload-target original
assert_body reload-control/update reloaded:update
assert_body reload-target updated
assert_body reload-control/methods reloaded:methods
for method in GET POST PUT DELETE OPTIONS; do
  assert_body reload-method "$method response" "$method"
done
assert_body reload-control/methods-static reloaded:methods-static
for method in GET POST PUT DELETE OPTIONS; do
  assert_body reload-method "$method response 2" "$method"
done
assert_body reload-control/remove reloaded:remove
assert_body reload-target reload-fallback
assert_body reload-method reload-fallback POST

assert_body reload-control/static reloaded:static
assert_body after after
assert_body shared-a shared-static
assert_body static-blob-a '<h1>hi</h1>'
assert_body static-blob-touched touched
curl --silent --show-error --head "${url}static-blob-a" >"$scratch/static-blob-reload-head"
tr -d '\r' <"$scratch/static-blob-reload-head" | \
  grep -i -x 'content-type: text/html;charset=utf-8' >/dev/null
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
