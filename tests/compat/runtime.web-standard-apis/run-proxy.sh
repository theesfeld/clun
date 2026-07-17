#!/bin/sh
# Hermetic Phase-28 HTTP proxy + HTTPS CONNECT contracts through the shipped binary gate.
# The executable path is version-checked by scripts/compat.sh; the suites load via SBCL.
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
[ -x "$clun" ] || {
  printf 'runtime.web-standard-apis proxy: %s is missing (run make build)\n' "$clun" >&2
  exit 2
}

# Prove the rebuilt binary is the one the ledger claims before Lisp suites run.
version=$("$clun" --version 2>/dev/null || true)
case "$version" in
  clun\ *) ;;
  *)
    printf 'runtime.web-standard-apis proxy: unexpected --version: %s\n' "${version:-<empty>}" >&2
    exit 1
    ;;
esac

cd "$repo_root"
sbcl --non-interactive --no-userinit --no-sysinit --load scripts/run-proxy-tests.lisp
