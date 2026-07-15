#!/bin/sh
# Prove benchmark result equivalence between the closure interpreter and the
# eager source-compiled tier, then report same-process-style best timings.
set -eu

cd "$(dirname "$0")/.."

CLUN=${CLUN:-./build/clun}
REPS=${REPS:-9}
RAW=${BENCH_RAW:-0}

die() {
  echo "bench-check: $*" >&2
  exit 1
}

case "$REPS" in ''|*[!0-9]*|0) die "REPS must be a positive integer" ;; esac
case "$RAW" in 0|1) ;; *) die "BENCH_RAW must be 0 or 1" ;; esac
[ -x "$CLUN" ] || die "$CLUN is missing or not executable; run 'make build' first"

tmp_base=${TMPDIR:-/tmp}
[ -d "$tmp_base" ] || tmp_base=.
tmp_dir=$(mktemp -d "$tmp_base/clun-bench-check.XXXXXX") ||
  die "could not create a temporary directory under $tmp_base"
trap 'rm -rf "$tmp_dir"' 0 HUP INT TERM

is_uint() {
  case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

field_value() {
  key=$1
  line=$2
  printf '%s\n' "$line" | awk -v key="$key" '
    {
      for (i = 1; i <= NF; i++) {
        split($i, pair, "=")
        if (pair[1] == key) { print pair[2]; exit }
      }
    }'
}

run_sample() {
  mode=$1
  benchmark=$2
  expected_name=$3
  rep=$4
  stdout_file=$tmp_dir/stdout
  stderr_file=$tmp_dir/stderr

  # Per-call execution tracing is deliberately off: mode/compile/fallback
  # telemetry is emitted after dispatch and cannot perturb the timed loop.
  if ! CLUN_COMPILE_TIER="$mode" CLUN_COMPILE_TIER_REPORT=1 CLUN_COMPILE_TIER_TRACE=0 \
    "$CLUN" run "$benchmark" >"$stdout_file" 2>"$stderr_file"; then
    cat "$stdout_file" >&2
    cat "$stderr_file" >&2
    die "$expected_name ($mode sample $rep) exited unsuccessfully"
  fi

  bench_count=$(awk '/^BENCH / { count++ } END { print count + 0 }' "$stdout_file")
  checksum_count=$(awk '/^CHECKSUM / { count++ } END { print count + 0 }' "$stdout_file")
  [ "$bench_count" -eq 1 ] ||
    die "$expected_name ($mode sample $rep) emitted $bench_count BENCH lines, expected 1"
  [ "$checksum_count" -eq 1 ] ||
    die "$expected_name ($mode sample $rep) emitted $checksum_count CHECKSUM lines, expected 1"
  awk '/^BENCH / { exit !(NF == 4) }' "$stdout_file" ||
    die "$expected_name ($mode sample $rep) emitted a malformed BENCH line"
  awk '/^CHECKSUM / { exit !(NF == 3) }' "$stdout_file" ||
    die "$expected_name ($mode sample $rep) emitted a malformed CHECKSUM line"

  bench_name=$(awk '/^BENCH / { print $2 }' "$stdout_file")
  bench_ms=$(awk '/^BENCH / { print $3 }' "$stdout_file")
  bench_iters=$(awk '/^BENCH / { print $4 }' "$stdout_file")
  checksum_name=$(awk '/^CHECKSUM / { print $2 }' "$stdout_file")
  checksum=$(awk '/^CHECKSUM / { print $3 }' "$stdout_file")

  [ "$bench_name" = "$expected_name" ] ||
    die "$benchmark reported BENCH name '$bench_name', expected '$expected_name'"
  [ "$checksum_name" = "$expected_name" ] ||
    die "$benchmark reported CHECKSUM name '$checksum_name', expected '$expected_name'"
  [ -n "$checksum" ] || die "$expected_name ($mode sample $rep) emitted an empty checksum"
  if ! awk -v ms="$bench_ms" -v iters="$bench_iters" \
    'BEGIN { exit !(ms ~ /^[0-9]+([.][0-9]+)?$/ && iters ~ /^[1-9][0-9]*$/) }'; then
    die "$expected_name ($mode sample $rep) emitted malformed BENCH fields"
  fi

  report_count=$(awk '/^COMPILE_TIER / { count++ } END { print count + 0 }' "$stderr_file")
  [ "$report_count" -eq 1 ] || {
    cat "$stderr_file" >&2
    die "$expected_name ($mode sample $rep) emitted $report_count compile-tier reports, expected 1"
  }
  report=$(awk '/^COMPILE_TIER / { print }' "$stderr_file")
  report_mode=$(field_value mode "$report")
  compiled=$(field_value compiled "$report")
  ineligible=$(field_value ineligible "$report")
  fallback=$(field_value fallback "$report")
  executed=$(field_value executed "$report")
  [ "$report_mode" = "$mode" ] ||
    die "$expected_name requested mode=$mode but runtime reported mode=$report_mode"
  for value in "$compiled" "$ineligible" "$fallback" "$executed"; do
    is_uint "$value" || die "$expected_name ($mode) emitted malformed telemetry: $report"
  done
  if [ "$mode" = eager ]; then
    [ "$compiled" -gt 0 ] || die "$expected_name eager run compiled zero functions"
    [ "$fallback" -eq 0 ] ||
      die "$expected_name eager run had $fallback unexpected compilation fallbacks"
    if [ "$expected_name" = deltablue ]; then
      [ "$compiled" -eq 72 ] ||
        die "deltablue eager timing sample compiled $compiled user bodies, expected 72"
      [ "$ineligible" -eq 1 ] ||
        die "deltablue eager timing sample had $ineligible ineligible bodies, expected wrapper-only 1"
    fi
  fi

  sample_key=$mode-$expected_name
  checksum_file=$tmp_dir/$sample_key.checksum
  iters_file=$tmp_dir/$sample_key.iters
  best_file=$tmp_dir/$sample_key.best
  if [ -f "$checksum_file" ]; then
    expected_checksum=$(cat "$checksum_file")
    [ "$checksum" = "$expected_checksum" ] ||
      die "$expected_name $mode checksum changed: $expected_checksum != $checksum"
  else
    printf '%s\n' "$checksum" >"$checksum_file"
  fi
  if [ -f "$iters_file" ]; then
    expected_iters=$(cat "$iters_file")
    [ "$bench_iters" = "$expected_iters" ] ||
      die "$expected_name $mode iteration count changed: $expected_iters != $bench_iters"
  else
    printf '%s\n' "$bench_iters" >"$iters_file"
  fi
  if [ ! -f "$best_file" ] ||
    awk -v sample="$bench_ms" -v best="$(cat "$best_file" 2>/dev/null || true)" \
      'BEGIN { exit !(best == "" || sample < best) }'; then
    printf '%s\n' "$bench_ms" >"$best_file"
  fi

  if [ "$RAW" -eq 1 ]; then
    printf 'sample mode=%s benchmark=%s rep=%s ms=%s checksum=%s compiled=%s ineligible=%s fallback=%s executed=%s\n' \
      "$mode" "$expected_name" "$rep" "$bench_ms" "$checksum" "$compiled" "$ineligible" \
      "$fallback" "$executed"
  fi
}

printf 'benchmark mode equivalence (%s samples per mode; lower is better)\n' "$REPS"
printf '%-12s %-18s %12s %12s %12s\n' benchmark checksum off-best-ms eager-best-ms off/eager
printf '%-12s %-18s %12s %12s %12s\n' --------- -------- ----------- ------------- ---------

for benchmark in bench/richards.js bench/deltablue.js bench/splay.js; do
  name=${benchmark#bench/}
  name=${name%.js}
  for mode in off eager; do
    rep=1
    while [ "$rep" -le "$REPS" ]; do
      run_sample "$mode" "$benchmark" "$name" "$rep"
      rep=$((rep + 1))
    done
  done

  off_checksum=$(cat "$tmp_dir/off-$name.checksum")
  eager_checksum=$(cat "$tmp_dir/eager-$name.checksum")
  [ "$off_checksum" = "$eager_checksum" ] ||
    die "$name result diverged between off and eager: $off_checksum != $eager_checksum"
  off_iters=$(cat "$tmp_dir/off-$name.iters")
  eager_iters=$(cat "$tmp_dir/eager-$name.iters")
  [ "$off_iters" = "$eager_iters" ] ||
    die "$name iteration count diverged between off and eager: $off_iters != $eager_iters"
  off_best=$(cat "$tmp_dir/off-$name.best")
  eager_best=$(cat "$tmp_dir/eager-$name.best")
  ratio=$(awk -v off="$off_best" -v eager="$eager_best" \
    'BEGIN { if (eager == 0) print "inf"; else printf "%.2fx", off / eager }')
  printf '%-12s %-18s %12s %12s %12s\n' \
    "$name" "$off_checksum" "$off_best" "$eager_best" "$ratio"
done

echo "bench-check: off/eager checksums and compile-tier telemetry passed"
