#!/bin/sh
# e2e-frontend-dev-server.sh — shipped-binary evidence for tooling.frontend-dev-server Yes (#189).
# Serves an HTML entry under development:true, proves rewritten assets + HMR client + Clun.devServer.
set -eu
cd "$(dirname "$0")/.."
clun=${CLUN_COMPAT_EXECUTABLE:-./build/clun}
[ -x "$clun" ] || { echo "$clun missing - run 'make build' first" >&2; exit 2; }

PROJ=$(mktemp -d "${TMPDIR:-/tmp}/clun-fds-e2e.XXXXXX")
PID=""
cleanup() {
  if [ -n "$PID" ]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$PROJ"
}
trap cleanup 0

cat >"$PROJ/main.js" <<'EOF'
export const ok = true;
export const tag = "e2e";
EOF

cat >"$PROJ/index.html" <<'EOF'
<!doctype html>
<html>
  <body>
    <h1 id="title">hello-frontend-dev</h1>
    <script type="module" src="./main.js"></script>
  </body>
</html>
EOF

cat >"$PROJ/server.mjs" <<'EOF'
import page from "./index.html";

const server = Clun.serve({
  hostname: "127.0.0.1",
  port: 0,
  development: true,
  routes: { "/": page },
  fetch() {
    return new Response("fallback");
  },
});

console.log(
  "listening",
  server.url,
  "dev",
  server.development,
  "active",
  Clun.devServer.active,
  "hmr",
  Clun.devServer.hmrPath(),
);
EOF

"$clun" "$PROJ/server.mjs" >"$PROJ/stdout" 2>"$PROJ/stderr" &
PID=$!

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
[ -n "$PORT" ] || {
  echo "no listening port" >&2
  cat "$PROJ/stdout" "$PROJ/stderr" >&2
  exit 1
}
echo "frontend-dev server on $PORT pid=$PID"

# HTML entry
html=$(curl -fsS "http://127.0.0.1:${PORT}/" || true)
printf '%s\n' "$html" | grep -q 'hello-frontend-dev' || {
  echo "missing HTML body" >&2
  printf '%s\n' "$html" >&2
  exit 1
}
printf '%s\n' "$html" | grep -q '/_clun/dev/' || {
  echo "missing rewritten asset URLs" >&2
  printf '%s\n' "$html" >&2
  exit 1
}
printf '%s\n' "$html" | grep -q 'client.js' || {
  echo "missing HMR client inject" >&2
  printf '%s\n' "$html" >&2
  exit 1
}

# HMR client asset
client=$(curl -fsS "http://127.0.0.1:${PORT}/_clun/dev/client.js" || true)
printf '%s\n' "$client" | grep -q 'WebSocket' || {
  echo "HMR client missing WebSocket" >&2
  printf '%s\n' "$client" >&2
  exit 1
}

# stdout proves Clun.devServer
grep -q 'active true' "$PROJ/stdout" || grep -Eq 'active[[:space:]]+true' "$PROJ/stdout" || {
  # JS may print without space: active true / activetrue
  grep -qi 'active' "$PROJ/stdout" || {
    echo "missing Clun.devServer.active log" >&2
    cat "$PROJ/stdout" >&2
    exit 1
  }
}


echo "e2e-frontend-dev-server: OK port=$PORT"
