#!/bin/sh
# language.typescript Yes — byte-exact strip + error catalog harness (Phase 09 corpus).

set -eu

fixture_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$fixture_dir/../../.." && pwd)

# Prefer the same SBCL invocation as Makefile.
SBCL=${SBCL:-sbcl}
SBCL_FLAGS=${SBCL_FLAGS:---non-interactive --no-userinit --no-sysinit}

cd "$repo_root"
# shellcheck disable=SC2086
$SBCL $SBCL_FLAGS --load scripts/run-ts-strip.lisp
