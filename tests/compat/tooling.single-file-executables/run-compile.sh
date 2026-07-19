#!/bin/sh
# Issue #181 — end-to-end pure-CL single-file executable compile + run + verify.
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-"$root/build/clun"}
work=$(mktemp -d "${TMPDIR:-/tmp}/clun-sfe-compat.XXXXXX")
trap 'rm -rf "$work"' EXIT

cat >"$work/app.js" <<'EOF'
console.log("sfe-run-ok");
console.log("argv", process.argv.slice(2).join(","));
EOF

printf 'asset-body\n' >"$work/data.txt"

out="$work/app.bin"
"$clun" build --compile "$work/app.js" --outfile "$out" --asset "$work/data.txt"

# Image-dumped SFE must be executable.
test -x "$out"

# Metadata from the dumped image.
"$out" --sfe-info | grep -q 'format=CLUNSEA'
"$out" --sfe-info | grep -q 'packaging=image'

# Act as Clun CLI (exceeds Bun BUN_BE_BUN).
CLUN_BE_CLUN=1 "$out" --version | grep -q '^clun '

# Embedded entry runs without a separate Clun install.
run_out=$("$out" extra-arg)
printf '%s\n' "$run_out" | grep -q 'sfe-run-ok'
printf '%s\n' "$run_out" | grep -q 'extra-arg'

# Pure-CL verify (unsigned image SFE is valid with algo=none).
"$clun" build --verify "$out" | grep -q 'ok=T'
"$out" --sfe-verify | grep -q 'ok=T'

# Cross-target native (same host triple) via explicit --target.
host_os=$(uname -s | tr '[:upper:]' '[:lower:]')
host_arch=$(uname -m)
case "$host_arch" in
  x86_64|amd64) host_arch=x64 ;;
  aarch64|arm64) host_arch=arm64 ;;
esac
target="clun-${host_os}-${host_arch}"
out2="$work/app-target.bin"
"$clun" build --compile "$work/app.js" --outfile "$out2" --target "$target"
test -x "$out2"
"$out2" | grep -q 'sfe-run-ok'

# JS API: Clun.compile.executable
cat >"$work/api.js" <<EOF
(async () => {
  const r = await Clun.compile.executable({
    entry: "$work/app.js",
    outfile: "$work/from-api.bin",
  });
  if (!r.success) throw new Error("compile failed");
  if (!r.outfile) throw new Error("missing outfile");
  console.log("api-ok", r.target, r.modules, r.assets, r.signed);
})();
EOF
api_out=$("$clun" "$work/api.js")
printf '%s\n' "$api_out" | grep -q 'api-ok'

printf 'sfe-compile-suite-ok\n'
