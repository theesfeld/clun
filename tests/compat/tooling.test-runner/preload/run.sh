#!/bin/sh

set -eu

fixture_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$fixture_dir/../../../.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
tmp_base=${TMPDIR:-$repo_root/tmp-test}
mkdir -p "$tmp_base"
work=$(mktemp -d "$tmp_base/clun-test-preload.XXXXXX")
cleanup() {
  [ "${CLUN_KEEP_TEST_TMP:-0}" = 1 ] || rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

[ -x "$clun" ] || {
  printf 'test-runner preload: executable is missing: %s\n' "$clun" >&2
  exit 2
}

mkdir -p "$work/config"
cat > "$work/config/config-a.mjs" <<'EOF'
globalThis.preloadOrder = ["config-a"];
globalThis.realmLoads = 1;
expect.extend({
  toBeConfigured(received) {
    return { pass: received === "configured", message: () => "not configured" };
  },
});
beforeAll(() => console.log("suite-start"));
beforeEach(() => console.log("setup-before"));
afterEach(() => console.log("setup-after"));
afterAll(() => console.log("suite-end"));
EOF
cat > "$work/config/config-b.mjs" <<'EOF'
preloadOrder.push("config-b");
realmLoads += 1;
mock.module("./dependency.mjs", () => ({ value: "mocked-before-import" }));
EOF
cat > "$work/config/cli.mjs" <<'EOF'
preloadOrder.push("cli");
realmLoads += 1;
EOF
cat > "$work/config/dependency.mjs" <<'EOF'
export const value = "original";
EOF
cat > "$work/config/a.test.mjs" <<'EOF'
import { value } from "./dependency.mjs";
beforeAll(() => console.log("a-start"));
beforeEach(() => console.log("a-before"));
afterEach(() => console.log("a-after"));
afterAll(() => console.log("a-end"));
test("a", () => {
  console.log("a-body");
  expect(preloadOrder).toEqual(["config-a", "config-b", "cli"]);
  expect(realmLoads).toBe(3);
  expect("configured").toBeConfigured();
  expect(value).toBe("mocked-before-import");
});
EOF
cat > "$work/config/b.test.mjs" <<'EOF'
import { value } from "./dependency.mjs";
beforeAll(() => console.log("b-start"));
beforeEach(() => console.log("b-before"));
afterEach(() => console.log("b-after"));
afterAll(() => console.log("b-end"));
test("b", () => {
  console.log("b-body");
  expect(preloadOrder).toEqual(["config-a", "config-b", "cli"]);
  expect(realmLoads).toBe(3);
  expect("configured").toBeConfigured();
  expect(value).toBe("mocked-before-import");
});
EOF
cat > "$work/config/bunfig.toml" <<'EOF'
name = "ignored # value"

[install]
test.preload = "./must-not-load.mjs"

[test]
preload = [
  "./config-a.mjs", # basic string and comment
  './config-b.mjs',
]
EOF

(cd "$work/config" && "$clun" test --preload ./cli.mjs a.test.mjs b.test.mjs) \
  > "$work/config.out" 2>&1
sed -n '/suite-start/,/suite-end/p' "$work/config.out" > "$work/config.order"
cat > "$work/config.expected" <<'EOF'
suite-start
a-start
setup-before
a-before
a-body
a-after
setup-after
(pass) a
a-end
b-start
setup-before
b-before
b-body
b-after
setup-after
(pass) b
b-end
suite-end
EOF
cmp -s "$work/config.expected" "$work/config.order"
grep -F ' 2 pass' "$work/config.out" >/dev/null
grep -F ' 8 expect() calls' "$work/config.out" >/dev/null

mkdir -p "$work/dotted"
cat > "$work/dotted/setup.mjs" <<'EOF'
globalThis.fromDottedConfig = "yes";
EOF
cat > "$work/dotted/dotted.test.js" <<'EOF'
test("dotted scalar config", () => expect(fromDottedConfig).toBe("yes"));
EOF
cat > "$work/dotted/bunfig.toml" <<'EOF'
test.preload = "./setup.mjs"
EOF
(cd "$work/dotted" && "$clun" test dotted.test.js) > "$work/dotted.out" 2>&1
grep -F '(pass) dotted scalar config' "$work/dotted.out" >/dev/null

mkdir -p "$work/aliases"
cat > "$work/aliases/one.mjs" <<'EOF'
globalThis.aliases = ["one"];
EOF
cat > "$work/aliases/two.mjs" <<'EOF'
aliases.push("two");
EOF
cat > "$work/aliases/alias.test.js" <<'EOF'
test("require aliases", () => expect(aliases).toEqual(["one", "two"]));
EOF
(cd "$work/aliases" && "$clun" test -r=./one.mjs --require ./two.mjs alias.test.js) \
  > "$work/aliases.out" 2>&1
grep -F '(pass) require aliases' "$work/aliases.out" >/dev/null

mkdir -p "$work/bail"
cat > "$work/bail/setup.mjs" <<'EOF'
afterAll(() => console.log("bail-suite-end"));
EOF
cat > "$work/bail/a.test.js" <<'EOF'
test("fails", () => expect(1).toBe(2));
EOF
cat > "$work/bail/b.test.js" <<'EOF'
test("must not run", () => console.log("unexpected-second-file"));
EOF
if (cd "$work/bail" && "$clun" test --bail --preload ./setup.mjs .) \
  > "$work/bail.out" 2>&1; then
  printf 'test-runner preload: bail fixture unexpectedly passed\n' >&2
  exit 1
fi
grep -F 'bail-suite-end' "$work/bail.out" >/dev/null
if grep -F 'unexpected-second-file' "$work/bail.out" >/dev/null; then
  printf 'test-runner preload: bail ran a later file\n' >&2
  exit 1
fi

mkdir -p "$work/setup-bail"
cat > "$work/setup-bail/setup.mjs" <<'EOF'
beforeAll(() => { throw new Error("setup failed"); });
afterAll(() => console.log("setup-failure-suite-end"));
EOF
cat > "$work/setup-bail/a.test.js" <<'EOF'
test("must not run", () => console.log("unexpected-first-body"));
EOF
cat > "$work/setup-bail/b.test.js" <<'EOF'
test("must not load", () => console.log("unexpected-second-body"));
EOF
if (cd "$work/setup-bail" && "$clun" test --bail --preload ./setup.mjs .) \
  > "$work/setup-bail.out" 2>&1; then
  printf 'test-runner preload: failing beforeAll unexpectedly passed\n' >&2
  exit 1
fi
grep -F 'Error: setup failed' "$work/setup-bail.out" >/dev/null
grep -F 'setup-failure-suite-end' "$work/setup-bail.out" >/dev/null
if grep -F 'unexpected-' "$work/setup-bail.out" >/dev/null; then
  printf 'test-runner preload: failing beforeAll executed a test body\n' >&2
  exit 1
fi

if "$clun" test --preload > "$work/missing-argument.out" 2>&1; then
  printf 'test-runner preload: missing argument unexpectedly passed\n' >&2
  exit 1
fi
grep -F 'requires a module path' "$work/missing-argument.out" >/dev/null

mkdir -p "$work/invalid"
cat > "$work/invalid/invalid.test.js" <<'EOF'
test("not reached", () => {});
EOF
cat > "$work/invalid/bunfig.toml" <<'EOF'
[test]
preload = [123]
EOF
if (cd "$work/invalid" && "$clun" test invalid.test.js) > "$work/invalid.out" 2>&1; then
  printf 'test-runner preload: invalid bunfig unexpectedly passed\n' >&2
  exit 1
fi
grep -F 'test.preload entries must be strings' "$work/invalid.out" >/dev/null

if (cd "$work/invalid" && rm bunfig.toml && "$clun" test --preload ./missing.mjs invalid.test.js) \
  > "$work/missing-module.out" 2>&1; then
  printf 'test-runner preload: missing module unexpectedly passed\n' >&2
  exit 1
fi
grep -F '(failed to load)' "$work/missing-module.out" >/dev/null

cat > "$work/invalid/registers-test.mjs" <<'EOF'
test("registered by preload", () => {});
EOF
if (cd "$work/invalid" && "$clun" test --preload ./registers-test.mjs invalid.test.js) \
  > "$work/preload-test.out" 2>&1; then
  printf 'test-runner preload: preload test registration unexpectedly passed\n' >&2
  exit 1
fi
grep -F 'Cannot use test() during preload.' "$work/preload-test.out" >/dev/null

printf 'test-runner preload: CLI, bunfig, lifecycle, realm, matcher, mock, bail, and error contracts passed\n'
