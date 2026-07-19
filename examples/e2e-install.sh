#!/bin/sh
# e2e-install.sh — the Phase-23 binary-level install e2e (hermetic). Starts the local registry
# fixture as a separate process, then drives the REAL build/clun binary: `clun install` against the
# fixture, then `clun run` an app that require()s the installed packages, asserting exact stdout;
# then deletes node_modules and reinstalls OFFLINE (fixture killed) from clun.lock via the cache and
# re-runs. Proves install → node_modules → require → run end-to-end through the binary.
set -eu
cd "$(dirname "$0")/.."
clun=${CLUN_COMPAT_EXECUTABLE:-./build/clun}
[ -x "$clun" ] || { echo "$clun missing - run 'make build' first" >&2; exit 2; }

URLFILE=$(mktemp); CACHE=$(mktemp -d); PROJ=$(mktemp -d)
cleanup() {
  if [ -n "${SRV:-}" ]; then
    kill "$SRV" 2>/dev/null || true
    wait "$SRV" 2>/dev/null || true
  fi
  rm -rf "$URLFILE" "$CACHE" "$PROJ"
}
trap cleanup 0

# 1. start the fixture registry (separate process; ephemeral port → $URLFILE)
CLUN_FIXTURE_URLFILE="$URLFILE" sbcl --non-interactive --no-userinit --no-sysinit \
  --load scripts/fixture-server.lisp >/dev/null 2>&1 &
SRV=$!
attempt=0
while [ "$attempt" -lt 120 ]; do
  [ -s "$URLFILE" ] && break
  sleep 0.5
  attempt=$((attempt + 1))
done
[ -s "$URLFILE" ] || { echo "fixture did not start" >&2; exit 1; }
BASE=$(cat "$URLFILE"); echo "fixture: $BASE"

# 2. a project depending on a transitive graph + the diamond + dep-spec breadth
#    (npm: alias, file: local package, optionalDependencies soft-fail).
mkdir -p "$PROJ/vendor/local-pkg"
printf '{"name":"local-pkg","version":"9.9.9"}\n' > "$PROJ/vendor/local-pkg/package.json"
printf "module.exports='local-pkg@9.9.9';\n" > "$PROJ/vendor/local-pkg/index.js"
printf '%s\n' '{"name":"app","version":"1.0.0","dependencies":{"left-pad":"^1.0.0","@scope/widget":"^1.0.0","conflict-a":"1.0.0","conflict-b":"1.0.0","pad":"npm:left-pad@1.3.0","local-pkg":"file:./vendor/local-pkg"},"optionalDependencies":{"does-not-exist-xyz":"1.0.0"}}' > "$PROJ/package.json"
printf "console.log(require('left-pad'));console.log(require('@scope/widget'));console.log(require('pad'));console.log(require('local-pkg'));\n" > "$PROJ/app.cjs"

EXPECT="left-pad@1.3.0
@scope/widget@1.0.0
left-pad@1.3.0
local-pkg@9.9.9"

# 3. install (online) + run through the binary
CLUN_CACHE="$CACHE" "$clun" --cwd "$PROJ" install --registry "$BASE"
OUT=$("$clun" --cwd "$PROJ" run app.cjs)
[ "$OUT" = "$EXPECT" ] || { echo "ONLINE run mismatch:"; echo "$OUT"; exit 1; }
echo "online install + run: OK"
LOCK1=$(cat "$PROJ/clun.lock")

# 4. delete node_modules, kill the fixture, reinstall OFFLINE from the lock via the cache, re-run
rm -rf "$PROJ/node_modules"
kill "$SRV" 2>/dev/null || true
wait "$SRV" 2>/dev/null || true
kill -0 "$SRV" 2>/dev/null && { echo "fixture is still running" >&2; exit 1; }
SRV=
CLUN_CACHE="$CACHE" "$clun" --cwd "$PROJ" install
OUT2=$("$clun" --cwd "$PROJ" run app.cjs)
[ "$OUT2" = "$EXPECT" ] || { echo "OFFLINE run mismatch:"; echo "$OUT2"; exit 1; }
[ "$(cat "$PROJ/clun.lock")" = "$LOCK1" ] || { echo "clun.lock changed after offline reinstall" >&2; exit 1; }
echo "offline reinstall + run: OK (byte-identical lock)"
echo "E2E PASS"
