#!/bin/sh
# e2e-install.sh — the Phase-23 binary-level install e2e (hermetic). Starts the local registry
# fixture as a separate process, then drives the REAL build/clun binary: `clun install` against the
# fixture, then `clun run` an app that require()s the installed packages, asserting exact stdout;
# then deletes node_modules and reinstalls OFFLINE (fixture killed) from clun.lock via the cache and
# re-runs. Proves install → node_modules → require → run end-to-end through the binary.
set -eu
cd "$(dirname "$0")/.."
[ -x ./build/clun ] || { echo "build/clun missing — run 'make build' first" >&2; exit 2; }

URLFILE=$(mktemp); CACHE=$(mktemp -d); PROJ=$(mktemp -d)
cleanup() { kill "${SRV:-}" 2>/dev/null || true; rm -rf "$URLFILE" "$CACHE" "$PROJ"; }
trap cleanup EXIT

# 1. start the fixture registry (separate process; ephemeral port → $URLFILE)
CLUN_FIXTURE_URLFILE="$URLFILE" sbcl --non-interactive --no-userinit --no-sysinit \
  --load scripts/fixture-server.lisp >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 120); do [ -s "$URLFILE" ] && break; sleep 0.5; done
[ -s "$URLFILE" ] || { echo "fixture did not start" >&2; exit 1; }
BASE=$(cat "$URLFILE"); echo "fixture: $BASE"

# 2. a project depending on a transitive graph + the diamond
printf '{"name":"app","version":"1.0.0","dependencies":{"left-pad":"^1.0.0","@scope/widget":"^1.0.0","conflict-a":"1.0.0","conflict-b":"1.0.0"}}\n' > "$PROJ/package.json"
printf "console.log(require('left-pad'));console.log(require('@scope/widget'));\n" > "$PROJ/app.cjs"

EXPECT="left-pad@1.3.0
@scope/widget@1.0.0"

# 3. install (online) + run through the binary
CLUN_CACHE="$CACHE" ./build/clun --cwd "$PROJ" install --registry "$BASE"
OUT=$(./build/clun --cwd "$PROJ" run app.cjs)
[ "$OUT" = "$EXPECT" ] || { echo "ONLINE run mismatch:"; echo "$OUT"; exit 1; }
echo "online install + run: OK"
LOCK1=$(cat "$PROJ/clun.lock")

# 4. delete node_modules, kill the fixture, reinstall OFFLINE from the lock via the cache, re-run
rm -rf "$PROJ/node_modules"
kill "$SRV" 2>/dev/null || true; SRV=
CLUN_CACHE="$CACHE" ./build/clun --cwd "$PROJ" install
OUT2=$(./build/clun --cwd "$PROJ" run app.cjs)
[ "$OUT2" = "$EXPECT" ] || { echo "OFFLINE run mismatch:"; echo "$OUT2"; exit 1; }
[ "$(cat "$PROJ/clun.lock")" = "$LOCK1" ] || { echo "clun.lock changed after offline reinstall" >&2; exit 1; }
echo "offline reinstall + run: OK (byte-identical lock)"
echo "E2E PASS"
