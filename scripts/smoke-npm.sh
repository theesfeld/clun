#!/bin/sh
# Live, non-hermetic Phase-28 smoke. Compatibility and Release require it;
# local developers may invoke it explicitly because network state is external.
#
# This exercises the user-visible package-manager path, not just the registry
# transport in isolation:
#   1. both `clun add <pkg>` and Bun-compatible `clun install <pkg>` resolve
#      public metadata, edit package.json, download release tarballs over the
#      experimental bounded TLS profile, check SRI, write clun.lock, and
#      materialise node_modules (including a transitive dependency graph);
#   2. both installed packages execute through Clun; and
#   3. frozen reinstalls succeed from the content-addressed cache while the
#      configured registry is deliberately unreachable, without rewriting
#      package.json or clun.lock.
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
[ -x "$clun" ] || {
  printf 'smoke-npm: %s is missing (run make build)\n' "$clun" >&2
  exit 2
}

scratch=$(mktemp -d "${TMPDIR:-/tmp}/clun-smoke-npm.XXXXXX")
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$scratch/cache" "$scratch/add-project" "$scratch/install-project"
# A non-empty SSL_CERT_FILE path wins over every system/custom CA fallback in
# Clun. The file itself is deliberately empty, so pure-tls rejects construction
# of any HTTPS transport instead of silently loading public roots. Frozen
# reinstalls can therefore pass only when every tarball comes from CLUN_CACHE.
: >"$scratch/no-public-trust.pem"
mkdir -p "$scratch/no-public-trust-dir"

printf '%s\n' '{"name":"clun-public-npm-smoke","version":"0.0.0","private":true}' \
  >"$scratch/add-project/package.json"
printf '%s\n' 'console.log(require("is-odd")(3));' \
  >"$scratch/add-project/smoke.cjs"

CLUN_CACHE="$scratch/cache" "$clun" --cwd "$scratch/add-project" add is-odd@3.0.1
output=$($clun --cwd "$scratch/add-project" run smoke.cjs)
[ "$output" = true ] || {
  printf 'smoke-npm: add-installed package output mismatch: %s\n' "$output" >&2
  exit 1
}
grep -F '"is-odd": "3.0.1"' "$scratch/add-project/package.json" >/dev/null
grep -F '"node_modules/is-odd"' "$scratch/add-project/clun.lock" >/dev/null
grep -F '"version": "3.0.1"' "$scratch/add-project/clun.lock" >/dev/null
grep -F '"node_modules/is-number"' "$scratch/add-project/clun.lock" >/dev/null
grep -F '"resolved": "https://registry.npmjs.org/' \
  "$scratch/add-project/clun.lock" >/dev/null
test -d "$scratch/add-project/node_modules/is-odd"
test -d "$scratch/add-project/node_modules/is-number"
grep -F '"integrity": "sha512-' "$scratch/add-project/clun.lock" >/dev/null
find "$scratch/cache/sha512" -type f -name '*.tgz' -size +0c | grep . >/dev/null
cp "$scratch/add-project/package.json" "$scratch/add-package.online.json"
cp "$scratch/add-project/clun.lock" "$scratch/add-clun.online.lock"

rm -rf "$scratch/add-project/node_modules"
SSL_CERT_FILE="$scratch/no-public-trust.pem" \
SSL_CERT_DIR="$scratch/no-public-trust-dir" \
CLUN_CACHE="$scratch/cache" "$clun" --cwd "$scratch/add-project" install \
  --frozen-lockfile --registry http://127.0.0.1:1/
offline_output=$($clun --cwd "$scratch/add-project" run smoke.cjs)
[ "$offline_output" = true ] || {
  printf 'smoke-npm: offline add-installed package output mismatch: %s\n' "$offline_output" >&2
  exit 1
}
cmp "$scratch/add-package.online.json" "$scratch/add-project/package.json"
cmp "$scratch/add-clun.online.lock" "$scratch/add-project/clun.lock"

printf '%s\n' '{"name":"clun-public-npm-install-smoke","version":"0.0.0","private":true}' \
  >"$scratch/install-project/package.json"
printf '%s\n' 'console.log(require("left-pad")("x", 3, "0"));' \
  >"$scratch/install-project/smoke.cjs"

CLUN_CACHE="$scratch/cache" "$clun" --cwd "$scratch/install-project" \
  install left-pad@1.3.0
install_output=$($clun --cwd "$scratch/install-project" run smoke.cjs)
[ "$install_output" = 00x ] || {
  printf 'smoke-npm: install-argument package output mismatch: %s\n' "$install_output" >&2
  exit 1
}
grep -F '"left-pad": "1.3.0"' "$scratch/install-project/package.json" >/dev/null
grep -F '"node_modules/left-pad"' "$scratch/install-project/clun.lock" >/dev/null
grep -F '"version": "1.3.0"' "$scratch/install-project/clun.lock" >/dev/null
grep -F '"resolved": "https://registry.npmjs.org/' \
  "$scratch/install-project/clun.lock" >/dev/null
test -d "$scratch/install-project/node_modules/left-pad"
grep -F '"integrity": "sha512-' "$scratch/install-project/clun.lock" >/dev/null
cp "$scratch/install-project/package.json" "$scratch/install-package.online.json"
cp "$scratch/install-project/clun.lock" "$scratch/install-clun.online.lock"

rm -rf "$scratch/install-project/node_modules"
SSL_CERT_FILE="$scratch/no-public-trust.pem" \
SSL_CERT_DIR="$scratch/no-public-trust-dir" \
CLUN_CACHE="$scratch/cache" "$clun" --cwd "$scratch/install-project" install \
  --frozen-lockfile --registry http://127.0.0.1:1/
offline_install_output=$($clun --cwd "$scratch/install-project" run smoke.cjs)
[ "$offline_install_output" = 00x ] || {
  printf 'smoke-npm: offline install-argument package output mismatch: %s\n' \
    "$offline_install_output" >&2
  exit 1
}
cmp "$scratch/install-package.online.json" "$scratch/install-project/package.json"
cmp "$scratch/install-clun.online.lock" "$scratch/install-project/clun.lock"

printf '%s\n' \
  'smoke-npm: public add/install-package + SRI execution + byte-identical transport-denied frozen reinstalls passed'
