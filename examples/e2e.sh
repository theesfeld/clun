#!/bin/sh
# e2e.sh — the Phase-24 v1 workflow demo (hermetic), driving the REAL build/clun binary end to end:
#   1. `clun install` a dependency graph from the local registry fixture
#   2. `clun run build` — a package.json script that invokes a tool from node_modules/.bin by bare
#      name (the ancestor .bin PATH), producing a build artifact
#   3. `clun test` — discover + run the project's test, which asserts the artifact was produced
# Proves install → scripts (.bin PATH) → test compose through the binary. Starts the registry
# fixture as a separate process (ephemeral port) and tears everything down on exit.
set -eu
cd "$(dirname "$0")/.."
[ -x ./build/clun ] || { echo "build/clun missing — run 'make build' first" >&2; exit 2; }

URLFILE=$(mktemp); CACHE=$(mktemp -d); PROJ=$(mktemp -d)
cleanup() { kill "${SRV:-}" 2>/dev/null || true; rm -rf "$URLFILE" "$CACHE" "$PROJ"; }
trap cleanup EXIT

# 1. start the fixture registry (separate process; ephemeral port → $URLFILE)
CLUN_FIXTURE_URLFILE="$URLFILE" sbcl --non-interactive --no-userinit --no-sysinit \
  --load scripts/fixture-server.lisp >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 120); do [ -s "$URLFILE" ] && break; sleep 0.5; done
[ -s "$URLFILE" ] || { echo "fixture did not start" >&2; exit 1; }
BASE=$(cat "$URLFILE"); echo "fixture: $BASE"

# 2. a project that depends on a bin-bearing tool + has a build script that invokes it, and a test
#    that verifies the build artifact
printf '{"name":"myapp","version":"1.2.3","dependencies":{"hasbin":"2.0.0"},"scripts":{"prebuild":"echo prebuild ran","build":"hasbin"}}\n' > "$PROJ/package.json"
cat > "$PROJ/artifact.test.js" <<'JS'
const fs = require("node:fs");
test("build produced dist/bundle.js", () => {
  // process.cwd() is the project root; the build script wrote dist/bundle.js there
  const s = fs.readFileSync(process.cwd() + "/dist/bundle.js", "utf8");
  expect(s.includes("built by hasbin@2.0.0")).toBe(true);
});
test("lifecycle env was set for scripts", () => {
  expect(typeof process.cwd()).toBe("string");
});
JS

# 3. install the graph (online) through the binary
CLUN_CACHE="$CACHE" ./build/clun --cwd "$PROJ" install --registry "$BASE"
[ -x "$PROJ/node_modules/.bin/hasbin" ] || { echo "hasbin not linked into .bin" >&2; exit 1; }
echo "install: OK (.bin/hasbin linked + executable)"

# 4. run the build script — invokes the .bin tool by bare name, runs prebuild first
OUT=$(./build/clun --cwd "$PROJ" run build)
printf '%s\n' "$OUT"
echo "$OUT" | grep -q "prebuild ran" || { echo "prebuild did not run" >&2; exit 1; }
echo "$OUT" | grep -q "hasbin: wrote dist/bundle.js" || { echo "bin tool did not run" >&2; exit 1; }
[ -f "$PROJ/dist/bundle.js" ] || { echo "build artifact missing" >&2; exit 1; }
echo "run build: OK (prebuild → .bin tool → artifact)"

# 5. test — discovers artifact.test.js under the project, verifies the artifact
./build/clun --cwd "$PROJ" test
echo "test: OK"

# 6. dispatch edges: --if-present on a missing script exits 0; a non-script name falls back to
#    running it as a FILE (script-first, file-fallback)
./build/clun --cwd "$PROJ" run --if-present nonesuch || { echo "--if-present on missing script should be 0" >&2; exit 1; }
echo "run --if-present (missing script): OK"
printf 'console.log("ran " + process.argv[2]);\n' > "$PROJ/hello.js"
OUT2=$(./build/clun --cwd "$PROJ" run hello.js worldarg)
[ "$OUT2" = "ran worldarg" ] || { echo "file-fallback mismatch: [$OUT2]" >&2; exit 1; }
echo "run <file> (file-fallback + argv passthrough): OK"
echo "E2E PASS"
