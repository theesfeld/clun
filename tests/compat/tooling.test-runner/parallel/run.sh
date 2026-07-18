#!/bin/sh
# shellcheck disable=SC2016
set -eu

fixture_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$fixture_dir/../../../.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
tmp_base=${TMPDIR:-$repo_root/tmp-test}
mkdir -p "$tmp_base"
work=$(mktemp -d "$tmp_base/clun-parallel.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

[ -x "$clun" ] || {
  printf 'test-runner parallel: executable is missing: %s\n' "$clun" >&2
  exit 2
}

cat > "$work/a.test.js" <<'JS'
test("a1", () => { expect(1).toBe(1); });
test("a2", () => { expect(2).toBe(2); });
JS
cat > "$work/b.test.js" <<'JS'
test("b1", () => { expect("b").toBe("b"); });
test("b2", async () => {
  await Promise.resolve(1);
  expect(true).toBe(true);
});
JS
cat > "$work/c.test.js" <<'JS'
test("c1", () => { expect([1, 2]).toEqual([1, 2]); });
JS

serial_out=$work/serial.out
parallel_out=$work/parallel.out
"$clun" test "$work" >"$serial_out" 2>"$work/serial.err"
serial_code=$?
"$clun" test --parallel=2 "$work" >"$parallel_out" 2>"$work/parallel.err"
parallel_code=$?

extract() {
  # last matching summary field
  awk -v key="$1" '
    $0 ~ ("^ " key "$") || $0 ~ ("^ [0-9]+ " key "$") {
      for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) v = $i
    }
    END { print v + 0 }
  ' "$2"
}

s_pass=$(extract pass "$serial_out")
s_fail=$(extract fail "$serial_out")
p_pass=$(extract pass "$parallel_out")
p_fail=$(extract fail "$parallel_out")
s_ran=$(grep -E '^Ran ' "$serial_out" | tail -n1)
p_ran=$(grep -E '^Ran ' "$parallel_out" | tail -n1)

# Parallel must keep isolation: each file's tests pass independently.
grep -Fq '(pass) a1' "$parallel_out"
grep -Fq '(pass) b2' "$parallel_out"
grep -Fq '(pass) c1' "$parallel_out"

if [ "$serial_code" -ne 0 ] || [ "$parallel_code" -ne 0 ]; then
  printf 'test-runner parallel: nonzero exit serial=%s parallel=%s\n' \
    "$serial_code" "$parallel_code" >&2
  exit 1
fi
if [ "$s_pass" -ne 5 ] || [ "$p_pass" -ne 5 ] || [ "$s_fail" -ne 0 ] || [ "$p_fail" -ne 0 ]; then
  printf 'test-runner parallel: count mismatch serial=%s/%s parallel=%s/%s\n' \
    "$s_pass" "$s_fail" "$p_pass" "$p_fail" >&2
  printf 'serial:\n%s\nparallel:\n%s\n' "$(cat "$serial_out")" "$(cat "$parallel_out")" >&2
  exit 1
fi
if [ "$s_ran" != "$p_ran" ]; then
  printf 'test-runner parallel: Ran line mismatch\n  serial: %s\n  parallel: %s\n' \
    "$s_ran" "$p_ran" >&2
  exit 1
fi

# Invalid worker count is rejected.
if "$clun" test --parallel=0 "$work" >/dev/null 2>"$work/bad.err"; then
  printf 'test-runner parallel: expected --parallel=0 to fail\n' >&2
  exit 1
fi
grep -Fq 'Invalid parallel worker count' "$work/bad.err"

printf 'parallel multi-file: serial/parallel agree (5 pass / 0 fail / 3 files); invalid count rejected\n'
