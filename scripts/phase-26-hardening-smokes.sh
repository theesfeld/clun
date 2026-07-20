#!/bin/sh
# Phase 26 hardening smokes — document-scroll not required; pure CLI/runtime gates.
# Exclusive sequential. Fail closed. No network except local loopback.
set -eu

repo_root=${CLUN_PHASE26_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}
cd "$repo_root"

fail() {
  printf 'phase-26-hardening-smokes: %s\n' "$*" >&2
  exit 1
}

CLUN=${CLUN_COMPAT_EXECUTABLE:-"$repo_root/build/clun"}
[ -x "$CLUN" ] || fail "missing executable: $CLUN (run make build first)"

scratch=$(mktemp -d "${TMPDIR:-/tmp}/clun-phase26.XXXXXX")
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT INT TERM

printf 'phase-26-hardening-smokes: backtrace discipline\n'
# Missing file must be a human error, never a raw SBCL/Lisp stack without --backtrace.
out=$("$CLUN" "$scratch/does-not-exist.js" 2>&1) && fail "missing file should exit nonzero" || true
printf '%s\n' "$out" | grep -Eqi 'backtrace|debugger invoked|unhandled' &&
  fail "bare Lisp backtrace leaked without --backtrace: $out" || true
printf '%s\n' "$out" | grep -Eqi 'not found|no such|cannot find|cannot open|module|error' ||
  fail "missing-file error lacked human message: $out"

# JS throw must show JS error, not Lisp frames.
printf 'throw new Error("phase26-smoke");\n' >"$scratch/throw.js"
out=$("$CLUN" "$scratch/throw.js" 2>&1) && fail "throw should exit nonzero" || true
printf '%s\n' "$out" | grep -F 'phase26-smoke' >/dev/null ||
  fail "JS Error message missing: $out"
printf '%s\n' "$out" | grep -Eqi 'SB-[A-Z]|debugger invoked' &&
  fail "Lisp/SBCL frame leaked on JS throw: $out" || true

printf 'phase-26-hardening-smokes: resource plateau (loop open/close)\n'
# Bounded open/close of temporary files via JS — steady-state, no crash.
# Embed scratch dir without external JSON encoders (node for quoting).
scratch_js=$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$scratch")
cat >"$scratch/plateau.js" <<EOF
const fs = require("fs");
const path = require("path");
const dir = $scratch_js;
let last = 0;
for (let i = 0; i < 400; i++) {
  const p = path.join(dir, "p-" + i + ".txt");
  fs.writeFileSync(p, "x" + i);
  const s = fs.readFileSync(p, "utf8");
  if (s !== "x" + i) throw new Error("read mismatch " + i);
  fs.unlinkSync(p);
  last = i;
}
console.log("plateau-ok " + (last + 1));
EOF
out=$("$CLUN" "$scratch/plateau.js" 2>&1) ||
  fail "resource plateau failed: $out"
printf '%s\n' "$out" | grep -F 'plateau-ok 400' >/dev/null ||
  fail "resource plateau unexpected output: $out"

printf 'phase-26-hardening-smokes: interruption (SIGINT long-running eval)\n'
# Keep the event loop busy; SIGINT must exit without Lisp debugger noise.
cat >"$scratch/busy.js" <<'EOF'
let n = 0;
const id = setInterval(() => {
  n++;
  if (n === 1) console.log("busy-ready");
}, 50);
EOF
log="$scratch/busy.log"
"$CLUN" "$scratch/busy.js" >"$log" 2>&1 &
pid=$!
ready=0
for _ in $(seq 1 80); do
  if grep -q 'busy-ready' "$log" 2>/dev/null; then
    ready=1
    break
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
[ "$ready" = 1 ] || {
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  fail "busy process never ready: $(cat "$log" 2>/dev/null || true)"
}
kill -INT "$pid" 2>/dev/null || true
exited=0
for _ in $(seq 1 80); do
  if ! kill -0 "$pid" 2>/dev/null; then
    exited=1
    break
  fi
  sleep 0.05
done
if [ "$exited" != 1 ]; then
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  fail "SIGINT did not stop busy process within timeout"
fi
wait "$pid" 2>/dev/null || true
if grep -Eqi 'debugger invoked|SB-SYS:|unhandled condition' "$log"; then
  fail "interrupt path leaked Lisp debugger noise: $(cat "$log")"
fi

printf 'phase-26-hardening-smokes: partial-install recovery\n'
# Failed add of a nonsense package must not destroy the package root.
pkgdir="$scratch/pkg"
mkdir -p "$pkgdir"
printf '%s\n' '{"name":"phase26-partial","version":"1.0.0"}' >"$pkgdir/package.json"
(
  cd "$pkgdir"
  out=$("$CLUN" add "definitely-not-a-real-package-zzzz-phase26-$$" 2>&1) &&
    fail "bogus package add should fail" || true
  printf '%s\n' "$out" | grep -Eqi 'not found|registry|error|fail|ENOENT|ENOTFOUND' ||
    fail "bogus add lacked human error: $out"
  [ -f package.json ] || fail "package.json missing after failed add"
  # package.json must remain parseable JSON (no require in -e realm)
  node -e 'JSON.parse(require("fs").readFileSync("package.json","utf8")); console.log("pkg-ok")' \
    2>&1 | grep -F 'pkg-ok' >/dev/null ||
    fail "package.json unreadable after failed add"
)

printf 'phase-26-hardening-smokes: long-run server smoke (bounded)\n'
cat >"$scratch/long.js" <<'EOF'
const server = Clun.serve({
  port: 0,
  fetch() {
    return new Response("ok");
  },
});
const port = Number(server.port);
let hits = 0;
const deadline = Date.now() + 1200;
(async () => {
  while (Date.now() < deadline) {
    const res = await fetch("http://127.0.0.1:" + port + "/");
    const body = await res.text();
    if (!body.includes("ok")) throw new Error("bad body: " + body);
    hits++;
  }
  console.log("long-ok " + hits);
  await server.stop();
  process.exit(0);
})().catch((err) => {
  console.error(String((err && err.stack) || err));
  process.exit(1);
});
EOF
out=$("$CLUN" "$scratch/long.js" 2>&1) || fail "long-run server smoke failed: $out"
printf '%s\n' "$out" | grep -E 'long-ok [1-9][0-9]*' >/dev/null ||
  fail "long-run unexpected: $out"

printf 'phase-26-hardening-smokes: all smokes passed\n'
