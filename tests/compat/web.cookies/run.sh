#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
[ -x "$clun" ] || { printf 'web.cookies server: %s is missing\n' "$clun" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { printf 'web.cookies server: curl is required\n' >&2; exit 2; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/clun-compat-cookies-server.XXXXXX")
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
    printf 'web.cookies server: server exited before publishing URL\n' >&2
    exit 1
  }
  sleep 0.1
  attempt=$((attempt + 1))
done
[ -n "$url" ] || { printf 'web.cookies server: timed out waiting for URL\n' >&2; exit 1; }
case "$url" in
  http://127.0.0.1:*/) ;;
  *) printf 'web.cookies server: malformed URL: %s\n' "$url" >&2; exit 1 ;;
esac

body=$(curl --fail --silent --show-error --http1.1 \
  -H 'Cookie: a=1' -H 'Cookie: b=2' -D "$scratch/identity.headers" \
  "${url}identity")
[ "$body" = identity-ok ] || {
  printf 'web.cookies server: request identity/lazy snapshot checks failed: %s\n' "$body" >&2
  exit 1
}
tr -d '\r' <"$scratch/identity.headers" |
  sed -n 's/^[Ss]et-[Cc]ookie:[[:space:]]*//p' >"$scratch/identity.cookies"
printf '%s\n' \
  'manual-one=1' \
  'manual-two=2' \
  'auto=5; Path=/; SameSite=Lax' >"$scratch/identity.expected"
cmp -s "$scratch/identity.expected" "$scratch/identity.cookies" || {
  diff -u "$scratch/identity.expected" "$scratch/identity.cookies" >&2 || :
  printf 'web.cookies server: manual/automatic Set-Cookie order mismatch\n' >&2
  exit 1
}

for operation in set delete; do
  body=$(curl --fail --silent --show-error --http1.1 -H 'Cookie: original=1' \
    "${url}snapshot-$operation")
  [ "$body" = "snapshot-$operation-ok" ] || {
    printf 'web.cookies server: request.headers %s snapshot mismatch: %s\n' \
      "$operation" "$body" >&2
    exit 1
  }
done

body=$(curl --fail --silent --show-error --http1.1 -D "$scratch/shared.headers" "${url}shared")
[ "$body" = shared ] || { printf 'web.cookies server: shared response body mismatch\n' >&2; exit 1; }
tr -d '\r' <"$scratch/shared.headers" |
  sed -n 's/^[Ss]et-[Cc]ookie:[[:space:]]*//p' >"$scratch/shared.cookies"
printf '%s\n' 'shared-manual=1' 'per-request=yes; Path=/; SameSite=Lax' >"$scratch/shared.expected"
cmp -s "$scratch/shared.expected" "$scratch/shared.cookies" || {
  diff -u "$scratch/shared.expected" "$scratch/shared.cookies" >&2 || :
  exit 1
}
[ "$(curl --fail --silent --show-error "${url}shared-check")" = shared-manual=1 ] || {
  printf 'web.cookies server: shared Response headers were mutated\n' >&2
  exit 1
}

body=$(curl --fail --silent --show-error --http1.1 -D "$scratch/late.headers" "${url}late")
[ "$body" = late-ok ] || { printf 'web.cookies server: mutation cutoff body mismatch\n' >&2; exit 1; }
sleep 0.05
tr -d '\r' <"$scratch/late.headers" |
  sed -n 's/^[Ss]et-[Cc]ookie:[[:space:]]*//p' >"$scratch/late.cookies"
[ "$(cat "$scratch/late.cookies")" = 'early=yes; Path=/; SameSite=Lax' ] || {
  printf 'web.cookies server: late mutation crossed commit cutoff\n' >&2
  cat "$scratch/late.cookies" >&2
  exit 1
}

[ "$(curl --fail --silent --show-error "${url}async")" = async-ok ] || {
  printf 'web.cookies server: async response mismatch\n' >&2
  exit 1
}

for route in throw reject; do
  status=$(curl --silent --show-error --output "$scratch/$route.body" \
    --dump-header "$scratch/$route.headers" --write-out '%{http_code}' "${url}$route")
  [ "$status" = 502 ] || { printf 'web.cookies server: %s status %s\n' "$route" "$status" >&2; exit 1; }
  [ "$(cat "$scratch/$route.body")" = fallback ] || {
    printf 'web.cookies server: %s fallback body mismatch\n' "$route" >&2
    exit 1
  }
done
tr -d '\r' <"$scratch/throw.headers" | grep -i -x \
  'set-cookie: error-cookie=kept; Path=/; SameSite=Lax' >/dev/null 2>&1 || {
  printf 'web.cookies server: synchronous error lost CookieMap mutations\n' >&2
  exit 1
}
tr -d '\r' <"$scratch/reject.headers" | grep -i -x \
  'set-cookie: rejected-cookie=kept; Path=/; SameSite=Lax' >/dev/null 2>&1 || {
  printf 'web.cookies server: promised error lost CookieMap mutations\n' >&2
  exit 1
}

status=$(curl --silent --show-error --output "$scratch/fake.body" --write-out '%{http_code}' "${url}fake")
[ "$status" = 502 ] && [ "$(cat "$scratch/fake.body")" = fallback ] || {
  printf 'web.cookies server: forged Response was not routed to error handler\n' >&2
  exit 1
}

status=$(curl --silent --show-error --output "$scratch/proxy-response.body" \
  --write-out '%{http_code}' "${url}proxy-response")
[ "$status" = 502 ] && [ "$(cat "$scratch/proxy-response.body")" = fallback-proxy-0 ] || {
  printf 'web.cookies server: proxied Response did not use zero-trap error fallback\n' >&2
  cat "$scratch/proxy-response.body" >&2
  exit 1
}

curl --fail --silent --show-error --head "${url}head" >"$scratch/head.headers"
tr -d '\r' <"$scratch/head.headers" | grep -i -x 'content-length: 9' >/dev/null 2>&1 || {
  printf 'web.cookies server: HEAD retained wrong representation length\n' >&2
  exit 1
}

index=1
pids=
while [ "$index" -le 8 ]; do
  curl --fail --silent --show-error --http1.1 -D "$scratch/concurrent.$index.headers" \
    "${url}shared" >"$scratch/concurrent.$index.body" &
  pids="$pids $!"
  index=$((index + 1))
done
for pid in $pids; do
  wait "$pid"
done
index=1
while [ "$index" -le 8 ]; do
  [ "$(cat "$scratch/concurrent.$index.body")" = shared ] || {
    printf 'web.cookies server: concurrent body %s mismatch\n' "$index" >&2
    exit 1
  }
  count=$(tr -d '\r' <"$scratch/concurrent.$index.headers" | grep -ic '^set-cookie:')
  [ "$count" -eq 2 ] || {
    printf 'web.cookies server: concurrent request %s emitted %s cookie fields\n' "$index" "$count" >&2
    exit 1
  }
  index=$((index + 1))
done

CLUN_COMPAT_EXECUTABLE="$clun" TMPDIR="${TMPDIR:-/tmp}" \
  sh "$repo_root/tests/compat/web.cookies/run-raw-http.sh"

printf 'web.cookies server: identity, lifecycle, ordering, proxy brands, errors, HEAD, and concurrency passed\n'
