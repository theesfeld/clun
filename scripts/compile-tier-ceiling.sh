#!/bin/sh
# Phase-25 m2 coverage gate: prove that eager mode source-compiles every
# DeltaBlue user function and that the compiled bodies execute. The generated
# CommonJS wrapper is outside the benchmark workload and is the sole exemption.
set -eu

cd "$(dirname "$0")/.."

CLUN=${CLUN:-./build/clun}
[ -x "$CLUN" ] || {
  echo "compile-tier-ceiling: $CLUN is missing or not executable; run 'make build' first" >&2
  exit 1
}

tmp_base=${TMPDIR:-/tmp}
[ -d "$tmp_base" ] || tmp_base=.
work=$(mktemp -d "$tmp_base/clun-compile-tier-ceiling.XXXXXX")
trap 'rm -rf "$work"' 0 HUP INT TERM

stdout=$work/stdout
stderr=$work/stderr
CLUN_COMPILE_TIER=eager \
CLUN_COMPILE_TIER_REPORT=1 \
CLUN_COMPILE_TIER_TRACE=1 \
CLUN_COMPILE_TIER_DETAILS=1 \
  "$CLUN" run bench/deltablue.js >"$stdout" 2>"$stderr"

report=$(awk '/^COMPILE_TIER / { print }' "$stderr")
[ "$(awk '/^COMPILE_TIER / { count++ } END { print count + 0 }' "$stderr")" -eq 1 ] || {
  cat "$stderr" >&2
  echo "compile-tier-ceiling: expected exactly one summary report" >&2
  exit 1
}

field() {
  printf '%s\n' "$report" | awk -v key="$1" '
    { for (i = 1; i <= NF; i++) { split($i, pair, "="); if (pair[1] == key) { print pair[2]; exit } } }'
}

[ "$(field mode)" = eager ] || { echo "compile-tier-ceiling: runtime did not select eager mode" >&2; exit 1; }
[ "$(field compiled)" -eq 72 ] || { echo "compile-tier-ceiling: expected 72 compiled bodies: $report" >&2; exit 1; }
[ "$(field ineligible)" -eq 1 ] || { echo "compile-tier-ceiling: expected one generated-wrapper exemption: $report" >&2; exit 1; }
[ "$(field fallback)" -eq 0 ] || { echo "compile-tier-ceiling: compilation fallback is not zero: $report" >&2; exit 1; }
[ "$(field executed)" -gt 0 ] || { echo "compile-tier-ceiling: compiled bodies did not execute: $report" >&2; exit 1; }

compiled=$(awk '/^COMPILE_TIER_FUNCTION / && / status=compiled / { count++ } END { print count + 0 }' "$stderr")
ineligible=$(awk '/^COMPILE_TIER_FUNCTION / && / status=ineligible / { count++ } END { print count + 0 }' "$stderr")
failed=$(awk '/^COMPILE_TIER_FUNCTION / && / status=compile-error / { count++ } END { print count + 0 }' "$stderr")
executed=$(awk '/^COMPILE_TIER_FUNCTION / && / status=compiled / {
  for (i = 1; i <= NF; i++) if ($i ~ /^executed=/) { split($i, pair, "="); if (pair[2] > 0) count++ }
} END { print count + 0 }' "$stderr")

[ "$compiled" -eq 72 ] || { echo "compile-tier-ceiling: named ledger has $compiled compiled bodies, expected 72" >&2; exit 1; }
[ "$ineligible" -eq 1 ] || { echo "compile-tier-ceiling: named ledger has $ineligible ineligible bodies, expected 1" >&2; exit 1; }
[ "$failed" -eq 0 ] || { echo "compile-tier-ceiling: named ledger records $failed compile errors" >&2; exit 1; }
grep -Eq '^COMPILE_TIER_FUNCTION id=require@0:[0-9]+#[0-9]+ status=ineligible executed=0 detail=function-expression$' "$stderr" || {
  cat "$stderr" >&2
  echo "compile-tier-ceiling: the sole exemption is not the generated require@0 wrapper" >&2
  exit 1
}
[ "$executed" -eq 69 ] || {
  echo "compile-tier-ceiling: named ledger shows $executed executed bodies, expected 69" >&2
  exit 1
}

# These three definitions are deliberately outside DeltaBlue's timed path. Keep
# the allowlist explicit so an accidentally unexecuted hot function cannot hide
# behind an aggregate count.
zero_execution=$(awk '/^COMPILE_TIER_FUNCTION / && / status=compiled / && / executed=0 / { print }' "$stderr")
[ "$(printf '%s\n' "$zero_execution" | sed '/^$/d' | wc -l | tr -d '[:space:]')" -eq 3 ] || {
  printf '%s\n' "$zero_execution" >&2
  echo "compile-tier-ceiling: unexpected zero-execution function set" >&2
  exit 1
}
for start in 1912 8048 8839; do
  printf '%s\n' "$zero_execution" |
    grep -Eq "^COMPILE_TIER_FUNCTION id=<anonymous>@${start}:[0-9]+#[0-9]+ status=compiled executed=0 detail=-$" || {
      printf '%s\n' "$zero_execution" >&2
      echo "compile-tier-ceiling: expected untimed function at body offset $start is missing" >&2
      exit 1
    }
done

[ "$(awk '/^CHECKSUM / { count++ } END { print count + 0 }' "$stdout")" -eq 1 ] || {
  cat "$stdout" >&2
  echo "compile-tier-ceiling: expected exactly one checksum line" >&2
  exit 1
}
grep -qx 'CHECKSUM deltablue 4551897514' "$stdout" || {
  cat "$stdout" >&2
  echo "compile-tier-ceiling: DeltaBlue checksum mismatch" >&2
  exit 1
}

printf 'compile-tier-ceiling: 72/72 DeltaBlue user bodies compiled; %s executed; wrapper-only exemption; checksum 4551897514\n' "$executed"
