#!/bin/sh
# e2e-hot-reload.sh — shipped-binary evidence for tooling.hot-reload Yes (#188).
# Spawns `clun --hot`, proves handler body updates without process restart, and
# proves the same PID keeps serving across soft reloads (state-preserving).
set -eu
cd "$(dirname "$0")/.."
clun=${CLUN_COMPAT_EXECUTABLE:-./build/clun}
[ -x "$clun" ] || { echo "$clun missing - run 'make build' first" >&2; exit 2; }

PROJ=$(mktemp -d "${TMPDIR:-/tmp}/clun-hot-e2e.XXXXXX")
PID=""
cleanup() {
  if [ -n "$PID" ]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$PROJ"
}
trap cleanup 0

write_server() {
  tag=$1
  # Always-assign tag so soft reload changes the response body.
  # Avoid ??= (not yet in Clun parser); use || for counters.
  cat > "$PROJ/server.mjs" <<EOF
globalThis.reloads = (globalThis.reloads || 0) + 1;
globalThis.tag = "${tag}";

const server = Clun.serve({
  hostname: "127.0.0.1",
  port: 0,
  fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === "/meta") {
      return new Response(
        JSON.stringify({
          tag: globalThis.tag,
          reloads: globalThis.reloads,
          hotMode: Clun.hot.mode,
          hotReloads: Clun.hot.reloads(),
        }),
        { headers: { "content-type": "application/json" } },
      );
    }
    return new Response("body:" + globalThis.tag + ":r" + globalThis.reloads);
  },
});

console.log("listening", server.url);
EOF
}

write_server v1

"$clun" --hot --no-clear-screen "$PROJ/server.mjs" >"$PROJ/stdout" 2>"$PROJ/stderr" &
PID=$!

# Wait for "listening http://127.0.0.1:PORT/"
PORT=""
attempt=0
while [ "$attempt" -lt 200 ]; do
  if [ -f "$PROJ/stdout" ]; then
    line=$(grep -E 'listening http://127\.0\.0\.1:[0-9]+/' "$PROJ/stdout" 2>/dev/null | tail -n 1 || true)
    if [ -n "$line" ]; then
      PORT=$(printf '%s\n' "$line" | sed -n 's/.*127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p')
      [ -n "$PORT" ] && break
    fi
  fi
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "server exited early" >&2
    cat "$PROJ/stdout" >&2 || true
    cat "$PROJ/stderr" >&2 || true
    exit 1
  fi
  sleep 0.05
  attempt=$((attempt + 1))
done
[ -n "$PORT" ] || { echo "no listening port" >&2; cat "$PROJ/stdout" "$PROJ/stderr" >&2; exit 1; }
echo "hot server on $PORT pid=$PID"

fetch() {
  path=$1
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 3 "http://127.0.0.1:${PORT}${path}"
  else
    "$clun" -p "await (await fetch('http://127.0.0.1:${PORT}${path}')).text()"
  fi
}

BODY1=$(fetch /)
echo "body1=$BODY1"
case "$BODY1" in
  body:v1:r1) ;;
  *) echo "unexpected initial body: $BODY1" >&2; exit 1 ;;
esac

META1=$(fetch /meta)
echo "meta1=$META1"
case "$META1" in
  *'"hotMode":"hot"'*) ;;
  *) echo "Clun.hot.mode missing/wrong: $META1" >&2; exit 1 ;;
esac

# Soft-reload source rewrite.
write_server v2

attempt=0
BODY2=""
while [ "$attempt" -lt 200 ]; do
  BODY2=$(fetch / 2>/dev/null || true)
  case "$BODY2" in
    body:v2:r*) break ;;
  esac
  sleep 0.05
  attempt=$((attempt + 1))
done
echo "body2=$BODY2"
case "$BODY2" in
  body:v2:r*) ;;
  *) echo "soft reload did not apply new handler: $BODY2" >&2
     cat "$PROJ/stderr" >&2 || true
     exit 1 ;;
esac

META2=$(fetch /meta)
echo "meta2=$META2"
printf '%s' "$META2" | grep -q '"tag":"v2"' || {
  echo "meta tag not v2 after reload: $META2" >&2
  exit 1
}
printf '%s' "$META2" | grep -q '"hotReloads":0' && {
  echo "Clun.hot.reloads still 0 after soft reload: $META2" >&2
  exit 1
}
printf '%s' "$META2" | grep -q '"hotMode":"hot"' || {
  echo "hotMode not hot after reload: $META2" >&2
  exit 1
}

if ! kill -0 "$PID" 2>/dev/null; then
  echo "process died during hot reload" >&2
  exit 1
fi

# Second soft reload + same PID contract.
write_server v3
attempt=0
BODY3=""
while [ "$attempt" -lt 200 ]; do
  BODY3=$(fetch / 2>/dev/null || true)
  case "$BODY3" in
    body:v3:r*) break ;;
  esac
  sleep 0.05
  attempt=$((attempt + 1))
done
echo "body3=$BODY3"
case "$BODY3" in
  body:v3:r*) ;;
  *) echo "second soft reload failed: $BODY3" >&2; exit 1 ;;
esac

if ! kill -0 "$PID" 2>/dev/null; then
  echo "process restarted (watch-like) instead of soft --hot" >&2
  exit 1
fi
echo "pid-stable=$PID"
echo "e2e-hot-reload: OK"
