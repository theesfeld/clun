#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
[ -x "$clun" ] || { printf 'server.websocket: %s is missing\n' "$clun" >&2; exit 2; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/clun-compat-websocket.XXXXXX")
server_pid=
cleanup() {
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
  [ -z "$server_pid" ] || wait "$server_pid" 2>/dev/null || true
  rm -rf "$scratch"
}
trap cleanup 0 HUP INT TERM

"$clun" "$repo_root/tests/compat/server.websocket/server.js" >"$scratch/server.out" \
  2>"$scratch/server.err" &
server_pid=$!

attempt=0
url=
while [ "$attempt" -lt 100 ]; do
  url=$(sed -n '1p' "$scratch/server.out" 2>/dev/null || :)
  [ -z "$url" ] || break
  kill -0 "$server_pid" 2>/dev/null || {
    cat "$scratch/server.err" >&2
    printf 'server.websocket: server exited before publishing its URL\n' >&2
    exit 1
  }
  sleep 0.1
  attempt=$((attempt + 1))
done
[ -n "$url" ] || { printf 'server.websocket: timed out waiting for server URL\n' >&2; exit 1; }

case "$url" in
  http://127.0.0.1:*/) port=${url#http://127.0.0.1:}; port=${port%/} ;;
  *) printf 'server.websocket: unsafe or malformed server URL: %s\n' "$url" >&2; exit 1 ;;
esac
case "$port" in
  ''|*[!0-9]*) printf 'server.websocket: bad port: %s\n' "$port" >&2; exit 1 ;;
esac

cat >"$scratch/client.js" <<CLIENT
const port = ${port};
const url = "ws://127.0.0.1:" + port + "/";
let opened = false;
let echoed = false;
let pubbed = false;
let done = false;
const ws = new WebSocket(url);
const finish = (ok, why) => {
  if (done) return;
  done = true;
  if (ok) {
    console.log("server.websocket: echo+pubsub client evidence ok");
  } else {
    console.error("server.websocket: " + why, {opened, echoed, pubbed});
  }
  // Prefer exitCode so the loop can drain; setTimeout force-exit is a safety net.
  process.exitCode = ok ? 0 : 1;
  setTimeout(() => process.exit(ok ? 0 : 1), 10);
};
ws.onopen = () => {
  opened = true;
  ws.send("echo-me");
};
ws.onmessage = (ev) => {
  const data = String(ev.data);
  if (data === "echo-me" && !echoed) {
    echoed = true;
    ws.send("pub:hello-room");
    return;
  }
  if (data === "hello-room") {
    pubbed = true;
    ws.close(1000, "done");
  }
};
ws.onclose = () => {
  finish(opened && echoed && pubbed, "incomplete close");
};
ws.onerror = () => finish(false, "socket error");
setTimeout(() => finish(false, "client timeout"), 4000);
CLIENT

set +e
"$clun" "$scratch/client.js" >"$scratch/client.out" 2>"$scratch/client.err"
status=$?
set -e
if [ "$status" -ne 0 ]; then
  cat "$scratch/client.err" >&2
  cat "$scratch/client.out" >&2
  printf 'server.websocket: client failed status=%s\n' "$status" >&2
  exit 1
fi
grep -q 'echo+pubsub client evidence ok' "$scratch/client.out" || {
  cat "$scratch/client.err" >&2
  cat "$scratch/client.out" >&2
  printf 'server.websocket: missing success line\n' >&2
  exit 1
}
printf 'server.websocket: shipped binary upgrade/echo/pubsub/client evidence\n'
