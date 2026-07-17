#!/bin/sh

set -eu

fixture_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$fixture_dir/../../../.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
tmp_base=${TMPDIR:-$repo_root/tmp-test}
mkdir -p "$tmp_base"
work=$(mktemp -d "$tmp_base/clun-test-reporters.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

[ -x "$clun" ] || {
  printf 'test-runner reporters: executable is missing: %s\n' "$clun" >&2
  exit 2
}

cat > "$work/alpha.test.js" <<'EOF'
describe('xml <&" suite', () => {
  test('pass <&"', () => {
    expect(1).toBe(1);
    expect(true).toBe(true);
  });
  test.skip('skipped', () => {});
  test.todo('todo');
});
EOF

cat > "$work/beta.test.js" <<'EOF'
test('failure', () => {
  expect(1).toBe(2);
});
EOF

if "$clun" test "$work" > "$work/default.out" 2>&1; then
  printf 'test-runner reporters: failing control run unexpectedly passed\n' >&2
  exit 1
fi

if env GITHUB_RUN_ID=17 GITHUB_SERVER_URL=https://github.example \
  GITHUB_REPOSITORY='owner/repo&x' GITHUB_SHA='abc<&"' \
  "$clun" test --reporter=junit --reporter-outfile="$work/report.xml" "$work" \
  > "$work/junit.out" 2>&1; then
  printf 'test-runner reporters: failing JUnit run unexpectedly passed\n' >&2
  exit 1
fi
cmp -s "$work/default.out" "$work/junit.out"

report=$work/report.xml
[ -f "$report" ]
grep -F '<?xml version="1.0" encoding="UTF-8"?>' "$report" >/dev/null
grep -F '<testsuites name="clun test" tests="4" assertions="3" failures="1" skipped="2" time="0">' "$report" >/dev/null
grep -F 'tests="3" assertions="2" failures="0" skipped="2" time="0" hostname=' "$report" >/dev/null
grep -F 'tests="1" assertions="1" failures="1" skipped="0" time="0" hostname=' "$report" >/dev/null
grep -F 'pass &lt;&amp;&quot;' "$report" >/dev/null
grep -F '<skipped />' "$report" >/dev/null
grep -F '<skipped message="TODO" />' "$report" >/dev/null
grep -F '<failure type="AssertionError"' "$report" >/dev/null
grep -F 'value="https://github.example/owner/repo&amp;x/actions/runs/17"' "$report" >/dev/null
grep -F 'value="abc&lt;&amp;&quot;"' "$report" >/dev/null
grep -F '</testsuites>' "$report" >/dev/null
cp "$report" "$work/report.first.xml"

if env GITHUB_RUN_ID=17 GITHUB_SERVER_URL=https://github.example \
  GITHUB_REPOSITORY='owner/repo&x' GITHUB_SHA='abc<&"' \
  "$clun" test --reporter junit --reporter-outfile "$work/report.xml" "$work" \
  > "$work/junit-second.out" 2>&1; then
  printf 'test-runner reporters: second failing JUnit run unexpectedly passed\n' >&2
  exit 1
fi
cmp -s "$work/junit.out" "$work/junit-second.out"
cmp -s "$work/report.first.xml" "$report"

for reporter in dots dot; do
  if "$clun" test --reporter="$reporter" "$work" > "$work/$reporter.out" 2>&1; then
    printf 'test-runner reporters: failing %s run unexpectedly passed\n' "$reporter" >&2
    exit 1
  fi
done
if "$clun" test --dots "$work" > "$work/dots-short.out" 2>&1; then
  printf 'test-runner reporters: failing --dots run unexpectedly passed\n' >&2
  exit 1
fi
cmp -s "$work/dots.out" "$work/dot.out"
cmp -s "$work/dots.out" "$work/dots-short.out"
grep -x '\.\.\.' "$work/dots.out" >/dev/null
grep -F '(fail) failure' "$work/dots.out" >/dev/null
grep -F ' 1 fail' "$work/dots.out" >/dev/null

if "$clun" test --reporter=junit "$work" > "$work/missing-outfile.out" 2>&1; then
  printf 'test-runner reporters: JUnit without outfile unexpectedly passed\n' >&2
  exit 1
fi
grep -F 'requires --reporter-outfile' "$work/missing-outfile.out" >/dev/null
if "$clun" test --reporter=unknown "$work" > "$work/unknown.out" 2>&1; then
  printf 'test-runner reporters: unknown reporter unexpectedly passed\n' >&2
  exit 1
fi
grep -F 'unsupported reporter format' "$work/unknown.out" >/dev/null
if "$clun" test --reporter=junit --reporter-outfile="$work/missing/report.xml" "$work" \
  > "$work/write-error.out" 2>&1; then
  printf 'test-runner reporters: unwritable JUnit path unexpectedly passed\n' >&2
  exit 1
fi
grep -F 'failed to write JUnit report' "$work/write-error.out" >/dev/null

printf 'test-runner reporters: dots, JUnit XML, escaping, overwrite, and CLI validation passed\n'
