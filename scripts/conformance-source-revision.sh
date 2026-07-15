#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

head=$(git rev-parse --verify HEAD)
printf '%s\n' "$head" | grep -Eq '^[0-9a-f]{40}$' || {
  printf 'conformance-source-revision: invalid HEAD: %s\n' "$head" >&2
  exit 2
}

execution_status=$(git status --porcelain --untracked-files=all -- \
  clun.asd \
  src \
  vendor \
  vendor-data/test262 \
  scripts/registry.lisp \
  scripts/test262.lisp \
  tests/conformance/exec-passlist.txt)

if [ -n "$execution_status" ]; then
  printf 'working-tree@%s\n' "$head"
else
  printf '%s\n' "$head"
fi
