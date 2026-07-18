#!/bin/sh
# language.typescript Yes — non-erasable construct reject policy through shipped binary.
# Value enums, parameter properties, runtime namespaces, decorators, import=/export=,
# and angle-cast hard-error. Enum emit / runtime transforms remain Phase 39 (#13).

set -eu

fixture_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$fixture_dir/../../.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}

[ -x "$clun" ] || {
  printf 'language.typescript reject-policy: executable is missing: %s\n' "$clun" >&2
  exit 2
}

fail() {
  printf 'language.typescript reject-policy: %s\n' "$*" >&2
  exit 1
}

run_case() {
  rel=$1
  want=$2
  src=$repo_root/$rel
  [ -f "$src" ] || fail "missing fixture $rel"
  work=$(mktemp "${TMPDIR:-/tmp}/clun-ts-reject.XXXXXX")
  status=0
  (cd "$(dirname -- "$src")" && env CI=0 "$clun" "$(basename -- "$src")") \
    >"$work.stdout" 2>"$work.stderr" || status=$?
  if [ "$status" -eq 0 ]; then
    rm -f "$work.stdout" "$work.stderr"
    fail "$rel exited 0 (expected non-zero reject)"
  fi
  if ! grep -F -q -- "$want" "$work.stderr"; then
    printf 'stderr:\n' >&2
    cat "$work.stderr" >&2 || :
    rm -f "$work.stdout" "$work.stderr"
    fail "$rel stderr missing: $want"
  fi
  if [ -s "$work.stdout" ]; then
    printf 'stdout:\n' >&2
    cat "$work.stdout" >&2 || :
    rm -f "$work.stdout" "$work.stderr"
    fail "$rel wrote unexpected stdout"
  fi
  rm -f "$work.stdout" "$work.stderr"
  printf '  (pass) %s\n' "$rel"
}

run_case tests/ts/errors/enum.ts 'TypeScript enum is not supported'
run_case tests/ts/errors/const-enum.ts 'TypeScript enum is not supported'
run_case tests/ts/errors/param-prop.ts 'parameter property is not supported'
run_case tests/ts/errors/ns-runtime.ts 'namespace declaration is not supported'
run_case tests/ts/errors/module-run.ts 'namespace declaration is not supported'
run_case tests/ts/errors/decorator.ts 'decorators are not currently supported'
run_case tests/ts/errors/import-eq.ts 'import = is not supported'
run_case tests/ts/errors/export-eq.ts 'export = is not supported'
run_case tests/ts/errors/angle-cast.ts 'angle brackets is not supported'
run_case tests/ts/errors/enum-in-namespace.ts 'namespace declaration is not supported'

printf 'language.typescript reject-policy: 10 non-erasable cases rejected\n'
