#!/bin/sh
# Full-corpus differential gate for the Phase-25 COMPILE tier. This deliberately
# runs without CLUN_GEN, so it can validate but never rewrite either pass-list.
set -eu

root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
cd "$root"

tmp_parent=${TMPDIR:-/tmp}
if [ ! -d "$tmp_parent" ]; then
  tmp_parent=.
fi
work=$(mktemp -d "$tmp_parent/clun-conformance-compare.XXXXXX")
trap 'rm -rf "$work"' 0 HUP INT TERM

off="$work/off.tsv"
eager="$work/eager.tsv"
sbcl=${SBCL:-sbcl}
unset CLUN_GEN

run_mode() {
  mode=$1
  output=$2
  printf '%s\n' "== test262 execution classifications: COMPILE tier $mode =="
  CLUN_EXEC=1 \
  CLUN_COMPILE_TIER=$mode \
  CLUN_COMPILE_TIER_TRACE=0 \
  CLUN_CONFORMANCE_CLASSIFICATIONS=$output \
    "$sbcl" --dynamic-space-size 6144 --non-interactive --no-userinit --no-sysinit \
      --load scripts/test262.lisp
}

run_mode off "$off"
run_mode eager "$eager"

if ! cmp -s "$off" "$eager"; then
  printf '%s\n' 'COMPILE-tier classification mismatch (off vs eager):' >&2
  diff -u "$off" "$eager" || true
  exit 1
fi

count=$(wc -l < "$off" | tr -d '[:space:]')
printf '%s\n' "COMPILE-tier classifications: identical ($count files)"
