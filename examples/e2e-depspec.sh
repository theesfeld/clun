#!/bin/sh
# e2e-depspec.sh — dependency-spec residual evidence for package-manager.npm Yes (#131).
# Hermetic: local registry fixture + pure-CL file: package + optional soft-fail + dist-tag +
# offline reinstall. Proves registry ranges, scoped names, optionalDependencies, and file:
# through the shipped binary on every release target.
set -eu
cd "$(dirname "$0")/.."
clun=${CLUN_COMPAT_EXECUTABLE:-./build/clun}
[ -x "$clun" ] || { echo "$clun missing - run 'make build' first" >&2; exit 2; }

URLFILE=$(mktemp); CACHE=$(mktemp -d); PROJ=$(mktemp -d); LOCAL=$(mktemp -d)
cleanup() {
  if [ -n "${SRV:-}" ]; then
    kill "$SRV" 2>/dev/null || true
    wait "$SRV" 2>/dev/null || true
  fi
  rm -rf "$URLFILE" "$CACHE" "$PROJ" "$LOCAL"
}
trap cleanup 0

# 1. fixture registry
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

# 2. local file: package
printf '%s\n' '{"name":"local-pkg","version":"9.9.9","main":"index.js"}' >"$LOCAL/package.json"
printf '%s\n' "module.exports = 'file-ok';" >"$LOCAL/index.js"

# 3. project: registry range + dist-tag + scoped + optional miss + file:
# optional missing package must soft-fail; required deps must install.
cat >"$PROJ/package.json" <<EOF
{
  "name": "depspec-app",
  "version": "1.0.0",
  "dependencies": {
    "left-pad": "^1.0.0",
    "@scope/widget": "latest",
    "local-pkg": "file:$LOCAL"
  },
  "optionalDependencies": {
    "definitely-missing-optional-pkg-zzzz": "^1.0.0"
  }
}
EOF
printf '%s\n' \
  "console.log(require('left-pad'));" \
  "console.log(require('@scope/widget'));" \
  "console.log(require('local-pkg'));" \
  >"$PROJ/app.cjs"

EXPECT="left-pad@1.3.0
@scope/widget@1.0.0
file-ok"

# 4. online install + run
CLUN_CACHE="$CACHE" "$clun" --cwd "$PROJ" install --registry "$BASE"
OUT=$("$clun" --cwd "$PROJ" run app.cjs)
[ "$OUT" = "$EXPECT" ] || { echo "ONLINE depspec mismatch:"; echo "$OUT"; exit 1; }
echo "depspec online install + run: OK"
test -f "$PROJ/node_modules/local-pkg/package.json"
test ! -e "$PROJ/node_modules/definitely-missing-optional-pkg-zzzz"
LOCK1=$(cat "$PROJ/clun.lock")

# 5. offline reinstall (fixture killed)
rm -rf "$PROJ/node_modules"
kill "$SRV" 2>/dev/null || true
wait "$SRV" 2>/dev/null || true
SRV=
CLUN_CACHE="$CACHE" "$clun" --cwd "$PROJ" install
OUT2=$("$clun" --cwd "$PROJ" run app.cjs)
[ "$OUT2" = "$EXPECT" ] || { echo "OFFLINE depspec mismatch:"; echo "$OUT2"; exit 1; }
[ "$(cat "$PROJ/clun.lock")" = "$LOCK1" ] || { echo "clun.lock changed after offline reinstall" >&2; exit 1; }
echo "depspec offline reinstall + run: OK (byte-identical lock)"
echo "DEPSPEC E2E PASS"
