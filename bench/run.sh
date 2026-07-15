#!/bin/sh
# bench/run.sh — Phase 25 benchmark harness. Drives the real build/clun binary against each
# bench/*.js benchmark and prints a table. Each benchmark self-times its steady-state workload (one
# untimed warmup + `ITERATIONS` timed iterations) and prints `BENCH <name> <ms> <iters>` plus a separate
# deterministic `CHECKSUM <name> <digest>` line. This script also measures process startup (`clun -e
# ''`). Results are SELF-RELATIVE: the same fixed workloads are re-measured after each optimization
# milestone, and the Phase-25 >=5x gate is the ratio vs the Phase-24 baseline recorded in
# docs/benchmarks.md. Reproducible via `make bench`. Override reps with REPS=N, select the tier with
# CLUN_COMPILE_TIER=off|eager, and print individual samples with BENCH_RAW=1.
set -eu
cd "$(dirname "$0")/.."
CLUN=./build/clun
[ -x "$CLUN" ] || { echo "build/clun missing — run 'make build' first" >&2; exit 2; }
REPS=${REPS:-5}
compile_tier=${CLUN_COMPILE_TIER:-off}
compile_tier_report=${CLUN_COMPILE_TIER_REPORT:-0}
raw=${BENCH_RAW:-0}

case "$REPS" in ''|*[!0-9]*|0) echo "REPS must be a positive integer" >&2; exit 2 ;; esac
case "$raw" in 0|1) ;; *) echo "BENCH_RAW must be 0 or 1" >&2; exit 2 ;; esac

echo "clun benchmark suite (best of $REPS; lower is better)"
echo "compile tier: $compile_tier"
echo "-------------------------------------------------------"

# startup: best wall-clock of `clun -e ''` over REPS (ms)
startup_best=""
i=0
while [ "$i" -lt "$REPS" ]; do
  t0=$(date +%s%N)
  CLUN_COMPILE_TIER="$compile_tier" CLUN_COMPILE_TIER_REPORT="$compile_tier_report" \
    "$CLUN" -e '' >/dev/null 2>&1
  t1=$(date +%s%N)
  ms=$(( (t1 - t0) / 1000000 ))
  if [ -z "$startup_best" ] || [ "$ms" -lt "$startup_best" ]; then startup_best=$ms; fi
  i=$((i + 1))
done
printf '%-12s %8s ms   (clun -e "")\n' "startup" "$startup_best"

# each benchmark: best (minimum) self-reported ms over REPS
status=0
for f in bench/*.js; do
  best=""; name=""; iters=""; expected_checksum=""
  i=0
  while [ "$i" -lt "$REPS" ]; do
    if [ "$raw" -eq 1 ]; then
      output=$(CLUN_COMPILE_TIER="$compile_tier" CLUN_COMPILE_TIER_REPORT="$compile_tier_report" \
        "$CLUN" run "$f" 2>&1) || {
          echo "FAIL $f exited unsuccessfully" >&2
          printf '%s\n' "$output" >&2
          status=1
          break
        }
    else
      output=$(CLUN_COMPILE_TIER="$compile_tier" CLUN_COMPILE_TIER_REPORT="$compile_tier_report" \
        "$CLUN" run "$f" 2>/dev/null) || {
          echo "FAIL $f exited unsuccessfully" >&2
          status=1
          break
        }
    fi
    line=$(printf '%s\n' "$output" | awk '/^BENCH / { print; exit }')
    if [ -z "$line" ]; then echo "FAIL $f produced no BENCH line" >&2; status=1; break; fi
    name=$(printf '%s\n' "$line" | awk '{print $2}')
    ms=$(printf '%s\n' "$line" | awk '{print $3}')
    iters=$(printf '%s\n' "$line" | awk '{print $4}')
    checksum=$(printf '%s\n' "$output" | awk '/^CHECKSUM / { print $3; exit }')
    if [ -z "$checksum" ]; then
      echo "FAIL $f produced no CHECKSUM line" >&2
      status=1
      break
    fi
    if [ -z "$expected_checksum" ]; then
      expected_checksum=$checksum
    elif [ "$checksum" != "$expected_checksum" ]; then
      echo "FAIL $f checksum changed: $expected_checksum != $checksum" >&2
      status=1
      break
    fi
    if [ "$raw" -eq 1 ]; then
      printf 'sample mode=%s benchmark=%s rep=%s ms=%s checksum=%s\n' \
        "$compile_tier" "$name" "$((i + 1))" "$ms" "${checksum:-missing}"
      printf '%s\n' "$output" | awk '!/^BENCH / && !/^CHECKSUM / { print "detail " $0 }'
    fi
    if [ -z "$best" ] || awk "BEGIN{exit !($ms < $best)}"; then best=$ms; fi
    i=$((i + 1))
  done
  [ -n "$best" ] && printf '%-12s %8s ms   (%s iters)\n' "$name" "$best" "$iters"
done
exit "$status"
