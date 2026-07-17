#!/bin/sh

set -eu

fixture_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$fixture_dir/../../../.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
tmp_base=${TMPDIR:-$repo_root/tmp-test}
mkdir -p "$tmp_base"
work=$(mktemp -d "$tmp_base/clun-test-randomize.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

[ -x "$clun" ] || {
  printf 'test-runner randomize: executable is missing: %s\n' "$clun" >&2
  exit 2
}

cat > "$work/a.test.js" <<'EOF'
describe("a outer", () => {
  test("a1", () => expect(true).toBe(true));
  describe("a inner", () => {
    test("a2", () => expect(true).toBe(true));
    test("a3", () => expect(true).toBe(true));
  });
  test("a4", () => expect(true).toBe(true));
});
EOF

cat > "$work/b.test.js" <<'EOF'
test("b1", () => expect(true).toBe(true));
test("b2", () => expect(true).toBe(true));
test("b3", () => expect(true).toBe(true));
test("b4", () => expect(true).toBe(true));
EOF

"$clun" test --seed=12345 "$work" > "$work/seed-12345-a.out" 2>&1
"$clun" test --seed 12345 "$work" > "$work/seed-12345-b.out" 2>&1
cmp -s "$work/seed-12345-a.out" "$work/seed-12345-b.out"
grep -F ' --seed=12345' "$work/seed-12345-a.out" >/dev/null
grep -F ' 8 pass' "$work/seed-12345-a.out" >/dev/null
grep -F 'Ran 8 tests across 2 files.' "$work/seed-12345-a.out" >/dev/null
sed -n '/^(pass)/p' "$work/seed-12345-a.out" > "$work/seed-12345.order"
cat > "$work/seed-12345.expected" <<'EOF'
(pass) a outer > a inner > a3
(pass) a outer > a inner > a2
(pass) a outer > a1
(pass) a outer > a4
(pass) b1
(pass) b3
(pass) b4
(pass) b2
EOF
cmp -s "$work/seed-12345.expected" "$work/seed-12345.order"

"$clun" test --seed=54321 "$work" > "$work/seed-54321.out" 2>&1
sed -n '/^(pass)/p' "$work/seed-54321.out" > "$work/seed-54321.order"
if cmp -s "$work/seed-12345.order" "$work/seed-54321.order"; then
  printf 'test-runner randomize: distinct seeds produced identical test order\n' >&2
  exit 1
fi

"$clun" test --randomize "$work" > "$work/random.out" 2>&1
generated_seed=$(sed -n 's/^ --seed=\([0-9][0-9]*\)$/\1/p' "$work/random.out")
[ -n "$generated_seed" ]
"$clun" test --seed="$generated_seed" "$work" > "$work/replay.out" 2>&1
cmp -s "$work/random.out" "$work/replay.out"

if "$clun" test --seed=invalid "$work" > "$work/invalid.out" 2>&1; then
  printf 'test-runner randomize: invalid seed unexpectedly passed\n' >&2
  exit 1
fi
grep -F 'Invalid seed value: invalid' "$work/invalid.out" >/dev/null
if "$clun" test --seed=4294967296 "$work" > "$work/overflow.out" 2>&1; then
  printf 'test-runner randomize: overflowing seed unexpectedly passed\n' >&2
  exit 1
fi
grep -F 'Invalid seed value: 4294967296' "$work/overflow.out" >/dev/null
if "$clun" test --seed > "$work/missing.out" 2>&1; then
  printf 'test-runner randomize: missing seed unexpectedly passed\n' >&2
  exit 1
fi
grep -F 'Invalid seed value:' "$work/missing.out" >/dev/null
"$clun" test --seed=4294967295 "$work" > "$work/max.out" 2>&1
grep -F ' --seed=4294967295' "$work/max.out" >/dev/null

printf 'test-runner randomize: seeded order, replay, generated seed, and validation passed\n'
