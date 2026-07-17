#!/bin/sh

set -eu

fixture_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$fixture_dir/../../../.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
tmp_base=${TMPDIR:-$repo_root/tmp-test}
mkdir -p "$tmp_base"
work=$(mktemp -d "$tmp_base/clun-test-coverage.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

[ -x "$clun" ] || {
  printf 'test-runner coverage: executable is missing: %s\n' "$clun" >&2
  exit 2
}

cat > "$work/subject.mts" <<'EOF'
export function add(left: number, right: number): number {
  return left + right;
}

export function choose(value: boolean): string {
  if (value) {
    return "yes";
  }
  return "no";
}

export const unused = (): number => {
  return 99;
};
EOF
cat > "$work/ignored.mts" <<'EOF'
export function ignored(): number {
  return 1;
}
EOF
cat > "$work/coverage.test.mts" <<'EOF'
import { add, choose } from "./subject.mts";
import { ignored } from "./ignored.mts";

test("coverage", () => {
  expect(add(2, 3)).toBe(5);
  expect(choose(true)).toBe("yes");
  expect(ignored()).toBe(1);
});
EOF
cat > "$work/bunfig.toml" <<'EOF'
[test]
coverage = true
coverageReporter = ["text", "lcov"]
coverageDir = "reports"
coverageSkipTestFiles = true
coveragePathIgnorePatterns = ["ignored.mts"]
coverageThreshold = { lines = 0.70, functions = 0.60, statements = 0.70 }
EOF

(cd "$work" && "$clun" test coverage.test.mts) > "$work/config.out" 2>&1
grep -F 'subject.mts  |   66.67 |   75.00 | 9,13' "$work/config.out" >/dev/null
grep -F 'All files    |   66.67 |   75.00 |' "$work/config.out" >/dev/null
if grep -F 'ignored.mts' "$work/config.out" >/dev/null ||
   grep -F 'coverage.test.mts' "$work/config.out" >/dev/null; then
  printf 'test-runner coverage: ignored or test source leaked into the report\n' >&2
  exit 1
fi
grep -F 'SF:subject.mts' "$work/reports/lcov.info" >/dev/null
grep -F 'FNDA:0,unused' "$work/reports/lcov.info" >/dev/null
grep -F 'DA:13,0' "$work/reports/lcov.info" >/dev/null
grep -F 'FNF:3' "$work/reports/lcov.info" >/dev/null
grep -F 'FNH:2' "$work/reports/lcov.info" >/dev/null
grep -F 'LF:8' "$work/reports/lcov.info" >/dev/null
grep -F 'LH:6' "$work/reports/lcov.info" >/dev/null

cat > "$work/bunfig.toml" <<'EOF'
[test]
coverage = true
coverageThreshold = { lines = 0.90, functions = 0.90, statements = 0.90 }
EOF
if (cd "$work" && "$clun" test coverage.test.mts) > "$work/threshold.out" 2>&1; then
  printf 'test-runner coverage: a low-coverage threshold unexpectedly passed\n' >&2
  exit 1
fi
grep -F 'coverage for lines (80.00%) does not meet threshold (90.00%)' \
  "$work/threshold.out" >/dev/null
grep -F 'coverage for functions (75.00%) does not meet threshold (90.00%)' \
  "$work/threshold.out" >/dev/null

cat > "$work/bunfig.toml" <<'EOF'
[test]
coverage = true
coverageReporter = "text"
coverageSkipTestFiles = false
EOF
(cd "$work" && "$clun" test coverage.test.mts) > "$work/include.out" 2>&1
grep -F 'coverage.test.mts' "$work/include.out" >/dev/null

rm -rf "$work/cli-reports"
(cd "$work" && "$clun" test --coverage-reporter=lcov \
  --coverage-dir=cli-reports coverage.test.mts) > "$work/override.out" 2>&1
[ -f "$work/cli-reports/lcov.info" ]
if grep -F 'Uncovered Line #s' "$work/override.out" >/dev/null; then
  printf 'test-runner coverage: CLI reporter did not override bunfig reporters\n' >&2
  exit 1
fi

cat > "$work/common.cjs" <<'EOF'
function twice(value) {
  return value * 2;
}

function unusedCommonJS() {
  return 0;
}

module.exports = { twice, unusedCommonJS };
EOF
cat > "$work/common.test.cjs" <<'EOF'
const { twice } = require("./common.cjs");

test("CommonJS coverage", () => {
  expect(twice(6)).toBe(12);
});
EOF
(cd "$work" && "$clun" test --coverage-reporter=lcov \
  --coverage-dir=cjs-reports common.test.cjs) > "$work/cjs.out" 2>&1
grep -F 'SF:common.cjs' "$work/cjs-reports/lcov.info" >/dev/null
grep -F 'FNDA:1,twice' "$work/cjs-reports/lcov.info" >/dev/null
grep -F 'FNDA:0,unusedCommonJS' "$work/cjs-reports/lcov.info" >/dev/null

if (cd "$work" && "$clun" test --coverage-reporter=json coverage.test.mts) \
  > "$work/invalid.out" 2>&1; then
  printf 'test-runner coverage: invalid reporter unexpectedly passed\n' >&2
  exit 1
fi
grep -F "unsupported coverage reporter 'json'" "$work/invalid.out" >/dev/null

printf 'test-runner coverage: source-aligned ESM/TS/CJS, text, LCOV, filters, config, overrides, and thresholds passed\n'
