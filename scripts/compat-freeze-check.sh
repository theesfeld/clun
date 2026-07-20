#!/bin/sh
# Phase 82 / Phase 73 freeze check.
#
# PLAN.md names this `make compat-freeze --check`. The exhaustive Bun public-surface
# freeze is represented by the checked-in compatibility ledger (baselines, features,
# platforms, references) plus `make compat-validate` ownership rules. This script:
#   1. Validates the ledger (zero unowned / invalid primary phases).
#   2. Pins the two Bun baselines required by §1.5 (stable 1.3.14 + engineering c1076ce95e).
#   3. Requires every landing-matrix feature to be Yes with a roadmap primary phase.
#   4. Proves the freeze set is byte-stable across two consecutive validate passes.
#
# Usage:
#   sh scripts/compat-freeze-check.sh
#   sh scripts/compat-freeze-check.sh --check   # same behavior (PLAN gate alias)
set -eu

cd "$(dirname "$0")/.."

case "${1:-}" in
  ""|--check) ;;
  -h|--help)
    printf 'usage: %s [--check]\n' "$0"
    exit 0
    ;;
  *)
    printf 'compat-freeze-check: unknown argument: %s\n' "$1" >&2
    exit 2
    ;;
esac

fail() {
  printf 'compat-freeze-check: %s\n' "$*" >&2
  exit 1
}

[ -f compat/baselines.tsv ] || fail "missing compat/baselines.tsv"
[ -f compat/features.tsv ] || fail "missing compat/features.tsv"
[ -f docs/roadmap.tsv ] || fail "missing docs/roadmap.tsv"

# 1–2. Ledger validity + frozen Bun baselines present
sh scripts/compat.sh validate || fail "compat validate failed"

bun_stable=$(awk -F '\t' 'NR > 1 && $1 == "bun-stable-1.3.14" { print $5 }' compat/baselines.tsv)
bun_eng=$(awk -F '\t' 'NR > 1 && $1 == "bun-engineering-c1076ce95e" { print $5 }' compat/baselines.tsv)

[ "$bun_stable" = "0d9b296af33f2b851fcbf4df3e9ec89751734ba4" ] ||
  fail "bun-stable-1.3.14 revision drifted (got '${bun_stable:-empty}')"
[ "$bun_eng" = "c1076ce95effb909bfe9f596919b5dba5567d550" ] ||
  fail "bun-engineering-c1076ce95e revision drifted (got '${bun_eng:-empty}')"

# 3. Every matrix feature is Yes with a primary phase (no Partial / No residual)
feature_stats=$(awk -F '\t' '
  NR == 1 { next }
  {
    total++
    state[$6]++
    if ($15 == "" || $15 == "-") bad_phase++
    if ($6 != "Yes") not_yes++
  }
  END {
    printf "total=%d yes=%d partial=%d no=%d other=%d bad_phase=%d\n",
      total + 0, state["Yes"] + 0, state["Partial"] + 0, state["No"] + 0,
      total - (state["Yes"] + state["Partial"] + state["No"]), bad_phase + 0
  }
' compat/features.tsv)

eval "$feature_stats"
[ "${total:-0}" -ge 30 ] || fail "expected >=30 features, got ${total:-0}"
[ "${yes:-0}" -eq "${total:-0}" ] ||
  fail "freeze requires all features Yes (yes=${yes:-0} total=${total:-0} partial=${partial:-0} no=${no:-0})"
[ "${bad_phase:-0}" -eq 0 ] || fail "${bad_phase} feature(s) missing primary_phase"

# 4. Byte-stable freeze set across two validate passes (PLAN: two clean scans)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT HUP TERM
hash_freeze() {
  # Order-stable digest of the freeze surfaces only (not generated README/site).
  {
    cat compat/baselines.tsv
    cat compat/features.tsv
    cat compat/platforms.tsv
    cat compat/references.tsv
    cat compat/release.tsv
    cat docs/roadmap.tsv
  } | sha256sum | awk '{ print $1 }'
}

h1=$(hash_freeze)
sh scripts/compat.sh validate >/dev/null
h2=$(hash_freeze)
[ "$h1" = "$h2" ] || fail "freeze set drifted between two consecutive validate scans ($h1 vs $h2)"

printf 'compat-freeze-check: ok — %s features all Yes; baselines bun-stable-1.3.14 + bun-engineering-c1076ce95e pinned; digest %s\n' \
  "$total" "$h1"
