#!/bin/sh
# shellcheck disable=SC2016

set -eu

fixture_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$fixture_dir/../../../.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
tmp_base=${TMPDIR:-$repo_root/tmp-test}
mkdir -p "$tmp_base"
work=$(mktemp -d "$tmp_base/clun-snapshots.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

[ -x "$clun" ] || {
  printf 'test-runner snapshots: executable is missing: %s\n' "$clun" >&2
  exit 2
}

test_file=$work/snapshot.test.js
snapshot_file=$work/__snapshots__/snapshot.test.js.snap
cat > "$test_file" <<'EOF'
describe("snapshot suite", () => {
  test("lifecycle", async () => {
    expect(process.env.SNAP_VALUE).toMatchSnapshot();
    expect(process.env.HINT_VALUE).toMatchSnapshot("named");
    expect({
      stable: "fixed",
      dynamic: process.env.PROPERTY_VALUE,
    }).toMatchSnapshot({ dynamic: expect.any(String) }, "properties");
    expect(process.env.INLINE_VALUE).toMatchInlineSnapshot();
    await expect(Promise.resolve(process.env.ASYNC_VALUE)).resolves.toMatchInlineSnapshot();
  });
});
EOF

run_values() {
  ci=$1
  snap=$2
  hint=$3
  inline=$4
  async=$5
  shift 5
  env CI="$ci" SNAP_VALUE="$snap" HINT_VALUE="$hint" PROPERTY_VALUE=dynamic-stable INLINE_VALUE="$inline" ASYNC_VALUE="$async" "$clun" test "$@" "$test_file"
}

if ! run_values 0 external-one hint-one inline-one async-one > "$work/create.out" 2>&1; then
  cat "$work/create.out" >&2
  printf 'test-runner snapshots: initial creation failed\n' >&2
  exit 1
fi
grep -F '(pass) snapshot suite > lifecycle' "$work/create.out" >/dev/null
grep -F ' 5 snapshots' "$work/create.out" >/dev/null
[ -f "$snapshot_file" ]
grep -F '// Bun Snapshot v1, https://bun.sh/docs/test/snapshots' "$snapshot_file" >/dev/null
grep -F 'snapshot suite lifecycle 1' "$snapshot_file" >/dev/null
grep -F 'snapshot suite lifecycle: named 1' "$snapshot_file" >/dev/null
grep -F 'snapshot suite lifecycle: properties 1' "$snapshot_file" >/dev/null
grep -F '"external-one"' "$snapshot_file" >/dev/null
grep -F '"hint-one"' "$snapshot_file" >/dev/null
grep -F 'toMatchInlineSnapshot(`"inline-one"`)' "$test_file" >/dev/null
grep -F 'toMatchInlineSnapshot(`"async-one"`)' "$test_file" >/dev/null
cp "$test_file" "$work/source.created"
cp "$snapshot_file" "$work/snapshots.created"

run_values 1 external-one hint-one inline-one async-one > "$work/reuse.out" 2>&1
cmp -s "$work/source.created" "$test_file"
cmp -s "$work/snapshots.created" "$snapshot_file"

if run_values 1 external-two hint-two inline-two async-two > "$work/mismatch.out" 2>&1; then
  printf 'test-runner snapshots: mismatched snapshots unexpectedly passed\n' >&2
  exit 1
fi
grep -F 'did not match' "$work/mismatch.out" >/dev/null
cmp -s "$work/source.created" "$test_file"
cmp -s "$work/snapshots.created" "$snapshot_file"

run_values 1 external-two hint-two inline-two async-two --update-snapshots > "$work/update.out" 2>&1
grep -F '"external-two"' "$snapshot_file" >/dev/null
grep -F '"hint-two"' "$snapshot_file" >/dev/null
grep -F 'toMatchInlineSnapshot(`"inline-two"`)' "$test_file" >/dev/null
grep -F 'toMatchInlineSnapshot(`"async-two"`)' "$test_file" >/dev/null
cp "$test_file" "$work/source.updated"
cp "$snapshot_file" "$work/snapshots.updated"

run_values 1 external-two hint-two inline-two async-two > "$work/reuse-updated.out" 2>&1
cmp -s "$work/source.updated" "$test_file"
cmp -s "$work/snapshots.updated" "$snapshot_file"

new_external=$work/new-external.test.js
cat > "$new_external" <<'EOF'
test("new external", () => {
  expect("created").toMatchSnapshot();
});
EOF
if env CI=1 "$clun" test "$new_external" > "$work/new-external-ci.out" 2>&1; then
  printf 'test-runner snapshots: CI unexpectedly created an external snapshot\n' >&2
  exit 1
fi
grep -F 'new snapshots are disabled in CI' "$work/new-external-ci.out" >/dev/null
[ ! -e "$work/__snapshots__/new-external.test.js.snap" ]
env CI=1 "$clun" test -u "$new_external" > "$work/new-external-update.out" 2>&1
[ -f "$work/__snapshots__/new-external.test.js.snap" ]
env CI=1 "$clun" test "$new_external" > "$work/new-external-reuse.out" 2>&1

new_inline=$work/new-inline.test.js
cat > "$new_inline" <<'EOF'
test("new inline", () => {
  expect("created inline").toMatchInlineSnapshot();
});
EOF
cp "$new_inline" "$work/new-inline.original"
if env CI=1 "$clun" test "$new_inline" > "$work/new-inline-ci.out" 2>&1; then
  printf 'test-runner snapshots: CI unexpectedly created an inline snapshot\n' >&2
  exit 1
fi
grep -F 'new snapshots are disabled in CI' "$work/new-inline-ci.out" >/dev/null
cmp -s "$work/new-inline.original" "$new_inline"
env CI=1 "$clun" test -u "$new_inline" > "$work/new-inline-update.out" 2>&1
grep -F 'toMatchInlineSnapshot(`"created inline"`)' "$new_inline" >/dev/null
cp "$new_inline" "$work/new-inline.updated"
env CI=1 "$clun" test "$new_inline" > "$work/new-inline-reuse.out" 2>&1
cmp -s "$work/new-inline.updated" "$new_inline"

bad_property=$work/bad-property.test.js
cat > "$bad_property" <<'EOF'
test("bad property matcher", () => {
  expect({ dynamic: 1 }).toMatchSnapshot({ dynamic: expect.any(String) });
});
EOF
if env CI=0 "$clun" test "$bad_property" > "$work/bad-property.out" 2>&1; then
  printf 'test-runner snapshots: a failed property matcher unexpectedly passed\n' >&2
  exit 1
fi
grep -F 'toMatchSnapshot(propertyMatchers)' "$work/bad-property.out" >/dev/null
[ ! -e "$work/__snapshots__/bad-property.test.js.snap" ]

printf 'test-runner snapshots: create, reuse, mismatch, CI denial, update, async inline, hints, and property validation passed\n'
