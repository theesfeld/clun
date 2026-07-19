#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
bin=${1:-"$root/build/clun"}
# ok must pass
"$bin" tsc "$root/tests/ts/typecheck/ok.ts" >/tmp/clun-tsc-ok.out 2>/tmp/clun-tsc-ok.err
# bad must fail with diagnostics
if "$bin" tsc "$root/tests/ts/typecheck/bad-assign.ts" >/tmp/clun-tsc-bad.out 2>/tmp/clun-tsc-bad.err; then
  echo "expected typecheck failure" >&2
  exit 1
fi
grep -q "not assignable" /tmp/clun-tsc-bad.err
echo "typecheck-ok"
