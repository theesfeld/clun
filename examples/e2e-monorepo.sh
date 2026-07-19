#!/bin/sh
# e2e-monorepo.sh — shipped-binary evidence for package-manager.monorepo Yes.
# Builds a multi-package monorepo, installs with workspace: + catalog: + filters,
# runs concurrent filtered scripts, and verifies live workspace symlinks.
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

# 2. monorepo tree
mkdir -p "$PROJ/packages/pkg-a" "$PROJ/packages/pkg-b" "$PROJ/packages/pkg-c"
cat > "$PROJ/package.json" <<'EOF'
{
  "name": "mono",
  "version": "1.0.0",
  "workspaces": {
    "packages": ["packages/*"],
    "catalog": { "left-pad": "^1.0.0" }
  },
  "dependencies": {
    "pkg-a": "workspace:*"
  },
  "scripts": {
    "hello": "echo root-hello"
  }
}
EOF
cat > "$PROJ/packages/pkg-a/package.json" <<'EOF'
{
  "name": "pkg-a",
  "version": "1.0.0",
  "dependencies": {
    "pkg-b": "workspace:*",
    "left-pad": "catalog:"
  },
  "scripts": {
    "build": "echo build-a",
    "hello": "echo hello-a"
  }
}
EOF
echo "module.exports='pkg-a';" > "$PROJ/packages/pkg-a/index.js"
cat > "$PROJ/packages/pkg-b/package.json" <<'EOF'
{
  "name": "pkg-b",
  "version": "2.0.0",
  "scripts": {
    "build": "echo build-b",
    "hello": "echo hello-b"
  }
}
EOF
echo "module.exports='pkg-b';" > "$PROJ/packages/pkg-b/index.js"
cat > "$PROJ/packages/pkg-c/package.json" <<'EOF'
{
  "name": "pkg-c",
  "version": "3.0.0",
  "scripts": {
    "hello": "echo hello-c"
  }
}
EOF
printf "console.log(require('pkg-a'));console.log(require('pkg-b'));console.log(require('left-pad'));\n" \
  > "$PROJ/app.cjs"

# 3. full monorepo install
CLUN_CACHE="$CACHE" "$clun" --cwd "$PROJ" install --registry "$BASE"
[ -e "$PROJ/node_modules/pkg-a" ] || { echo "missing node_modules/pkg-a" >&2; exit 1; }
[ -e "$PROJ/node_modules/pkg-b" ] || { echo "missing node_modules/pkg-b" >&2; exit 1; }
[ -e "$PROJ/node_modules/left-pad" ] || { echo "missing catalog left-pad" >&2; exit 1; }
# workspace packages must be symlinks (live link)
[ -L "$PROJ/node_modules/pkg-a" ] || { echo "pkg-a is not a symlink" >&2; exit 1; }
[ -L "$PROJ/node_modules/pkg-b" ] || { echo "pkg-b is not a symlink" >&2; exit 1; }
echo "workspace symlink install: OK"

OUT=$("$clun" --cwd "$PROJ" run app.cjs)
echo "$OUT" | grep -q 'pkg-a' || { echo "require pkg-a failed: $OUT" >&2; exit 1; }
echo "$OUT" | grep -q 'pkg-b' || { echo "require pkg-b failed: $OUT" >&2; exit 1; }
echo "$OUT" | grep -q 'left-pad@' || { echo "require left-pad failed: $OUT" >&2; exit 1; }
echo "require graph: OK"

# 4. filtered concurrent scripts (exclude pkg-c)
FILTER_OUT=$("$clun" --cwd "$PROJ" run --parallel --concurrency 4 \
  --filter 'pkg-*' --filter '!pkg-c' hello)
echo "$FILTER_OUT" | grep -q 'hello-a' || { echo "missing hello-a in: $FILTER_OUT" >&2; exit 1; }
echo "$FILTER_OUT" | grep -q 'hello-b' || { echo "missing hello-b in: $FILTER_OUT" >&2; exit 1; }
echo "$FILTER_OUT" | grep -q 'hello-c' && { echo "pkg-c should be filtered out" >&2; exit 1; }
echo "filtered concurrent run: OK"

# 5. filtered install for a single package
rm -rf "$PROJ/node_modules" "$PROJ/clun.lock"
CLUN_CACHE="$CACHE" "$clun" --cwd "$PROJ" install --registry "$BASE" --filter pkg-b
[ -e "$PROJ/node_modules/pkg-b" ] || { echo "filtered install missing pkg-b" >&2; exit 1; }
echo "filtered install: OK"

echo "MONOREPO E2E PASS"
