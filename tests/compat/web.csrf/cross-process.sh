#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
clun=${CLUN_COMPAT_EXECUTABLE:-$repo_root/build/clun}
[ -x "$clun" ] || {
  printf 'web.csrf: %s is missing\n' "$clun" >&2
  exit 2
}

token=$("$clun" -e 'console.log(Clun.CSRF.generate())')
[ -n "$token" ] || {
  printf 'web.csrf: generator process returned an empty token\n' >&2
  exit 1
}

verified=$(CLUN_CSRF_TOKEN=$token "$clun" -e \
  'console.log(Clun.CSRF.verify(process.env.CLUN_CSRF_TOKEN))')
[ "$verified" = false ] || {
  printf 'web.csrf: a fresh process accepted another process default-secret token\n' >&2
  exit 1
}

printf 'web.csrf: default secrets are isolated across processes\n'
