#!/bin/sh
# e2e-formatter-linter.sh — shipped-binary smoke for tooling.formatter-linter (#190).
# Usage: examples/e2e-formatter-linter.sh [path-to-clun]
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
CLUN=${1:-"$ROOT/build/clun"}
if [ ! -x "$CLUN" ]; then
  echo "missing clun binary: $CLUN" >&2
  exit 2
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

printf 'const x=1;function f(a){return a+x}\n' >"$TMP/a.js"
printf 'var y = 1; debugger;\n' >"$TMP/b.js"
printf '{"a":1,"b":[2,3]}\n' >"$TMP/c.json"

# format --write
"$CLUN" fmt --write "$TMP/a.js" >/dev/null
"$CLUN" fmt --check "$TMP/a.js"
# format JSON
OUT=$("$CLUN" fmt "$TMP/c.json")
echo "$OUT" | grep -q '"a"'

# lint finds debugger
set +e
"$CLUN" lint "$TMP/b.js" >/tmp/clun-lint-out.$$ 2>&1
CODE=$?
set -e
grep -q no-debugger /tmp/clun-lint-out.$$
test "$CODE" -ne 0

# programmatic surface
"$CLUN" -e 'const f=Clun.format("const x=1"); if(!f.includes("const")) process.exit(1); const d=Clun.lint("debugger;"); if(!d.length) process.exit(1);'

echo "e2e-formatter-linter: ok"
