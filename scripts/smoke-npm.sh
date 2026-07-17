#!/bin/sh
# Opt-in live Phase-28 smoke. Network state is never part of the hermetic gate.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
[ -x "$clun" ] || {
  printf 'smoke-npm: %s is missing (run make build)\n' "$clun" >&2
  exit 2
}

scratch=$(mktemp -d "${TMPDIR:-/tmp}/clun-smoke-npm.XXXXXX")
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$scratch/cache" "$scratch/project"

printf '%s\n' '{"name":"clun-public-npm-smoke","version":"0.0.0","private":true,"dependencies":{"is-number":"7.0.0"}}' \
  >"$scratch/project/package.json"
printf '%s\n' 'console.log(require("is-number")("42"));' \
  >"$scratch/project/smoke.cjs"

CLUN_CACHE="$scratch/cache" "$clun" --cwd "$scratch/project" install
output=$($clun --cwd "$scratch/project" run smoke.cjs)
[ "$output" = true ] || {
  printf 'smoke-npm: installed package output mismatch: %s\n' "$output" >&2
  exit 1
}
grep -F '"version": "7.0.0"' "$scratch/project/clun.lock" >/dev/null
grep -F '"integrity": "sha512-' "$scratch/project/clun.lock" >/dev/null
find "$scratch/cache/sha512" -type f -name '*.tgz' -size +0c | grep . >/dev/null

printf 'smoke-npm: installed and executed is-number@7.0.0 with registry SRI verified\n'
