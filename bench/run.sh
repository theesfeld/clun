#!/bin/sh
# bench/run.sh — Phase 25 benchmark harness. Drives the real build/clun binary against each
# bench/*.js benchmark and prints a table. Each benchmark self-times its steady-state workload (one
# untimed warmup + `ITERATIONS` timed iterations) and prints one line `BENCH <name> <ms> <iters>`;
# this script also measures process startup (`clun -e ''`). Results are SELF-RELATIVE: the same fixed
# workloads are re-measured after each optimization milestone, and the Phase-25 >=5x gate is the ratio
# vs the Phase-24 baseline recorded in docs/benchmarks.md. (No node/bun on this host, so no
# cross-runtime comparison — see the doc.) Reproducible via `make bench`. Override reps with REPS=N.
set -eu
cd "$(dirname "$0")/.."
CLUN=./build/clun
[ -x "$CLUN" ] || { echo "build/clun missing — run 'make build' first" >&2; exit 2; }
REPS=${REPS:-5}

echo "clun benchmark suite (best of $REPS; lower is better)"
echo "-------------------------------------------------------"

# startup: best wall-clock of `clun -e ''` over REPS (ms)
startup_best=""
i=0
while [ "$i" -lt "$REPS" ]; do
  t0=$(date +%s%N)
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
  best=""; name=""; iters=""
  i=0
  while [ "$i" -lt "$REPS" ]; do
    line=$("$CLUN" run "$f" 2>/dev/null | grep '^BENCH ' || true)
    if [ -z "$line" ]; then echo "FAIL $f produced no BENCH line" >&2; status=1; break; fi
    name=$(echo "$line" | awk '{print $2}')
    ms=$(echo "$line" | awk '{print $3}')
    iters=$(echo "$line" | awk '{print $4}')
    if [ -z "$best" ] || awk "BEGIN{exit !($ms < $best)}"; then best=$ms; fi
    i=$((i + 1))
  done
  [ -n "$best" ] && printf '%-12s %8s ms   (%s iters)\n' "$name" "$best" "$iters"
done
exit "$status"
