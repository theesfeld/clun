#!/bin/sh

set -eu

fixture_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$fixture_dir/../../../.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
tmp_base=${TMPDIR:-$repo_root/tmp-test}
mkdir -p "$tmp_base"
work=$(mktemp -d "$tmp_base/clun-test-sharding.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

[ -x "$clun" ] || {
  printf 'test-runner sharding: executable is missing: %s\n' "$clun" >&2
  exit 2
}

for name in a b c d e f; do
  printf 'test("%s", () => expect(true).toBe(true));\n' "$name" > "$work/$name.test.js"
done

for index in 1 2 3; do
  "$clun" test --shard="$index/3" "$work" > "$work/shard-$index.out" 2>&1
  grep -F ' 2 pass' "$work/shard-$index.out" >/dev/null
  grep -F 'Ran 2 tests across 2 files.' "$work/shard-$index.out" >/dev/null
  sed -n 's/^(pass) //p' "$work/shard-$index.out" > "$work/shard-$index.names"
done

cat > "$work/shard-1.expected" <<'EOF'
a
d
EOF
cat > "$work/shard-2.expected" <<'EOF'
b
e
EOF
cat > "$work/shard-3.expected" <<'EOF'
c
f
EOF
for index in 1 2 3; do
  cmp -s "$work/shard-$index.expected" "$work/shard-$index.names"
done

cat "$work/shard-1.names" "$work/shard-2.names" "$work/shard-3.names" \
  | sort > "$work/all.names"
cat > "$work/all.expected" <<'EOF'
a
b
c
d
e
f
EOF
cmp -s "$work/all.expected" "$work/all.names"

"$clun" test --shard 2/3 "$work" > "$work/shard-space.out" 2>&1
cmp -s "$work/shard-2.out" "$work/shard-space.out"

"$clun" test --shard=1/3 --seed=99 "$work" > "$work/random-a.out" 2>&1
"$clun" test --seed=99 --shard=1/3 "$work" > "$work/random-b.out" 2>&1
cmp -s "$work/random-a.out" "$work/random-b.out"
grep -F ' --seed=99' "$work/random-a.out" >/dev/null
grep -F 'Ran 2 tests across 2 files.' "$work/random-a.out" >/dev/null

for invalid in 0/3 4/3 1/0 1-3 word 1/2/3; do
  if "$clun" test --shard="$invalid" "$work" > "$work/invalid.out" 2>&1; then
    printf 'test-runner sharding: invalid shard %s unexpectedly passed\n' "$invalid" >&2
    exit 1
  fi
  grep -F 'Invalid shard value:' "$work/invalid.out" >/dev/null
done

printf 'test-runner sharding: disjoint coverage, both spellings, seeded replay, and validation passed\n'
