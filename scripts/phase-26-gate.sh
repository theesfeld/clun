#!/bin/sh
# Phase 26 exclusive sequential gate set. Fail closed; no parallel fan-out.
set -eu

repo_root=${CLUN_PHASE26_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}
cd "$repo_root"

printf 'phase-26-gate: build\n'
make build

printf 'phase-26-gate: purity\n'
make purity

printf 'phase-26-gate: public-claims-check\n'
make public-claims-check

printf 'phase-26-gate: docs-check\n'
make docs-check

printf 'phase-26-gate: freeze-check\n'
sh scripts/compat-freeze-check.sh --check

printf 'phase-26-gate: test (perf skipped for CI-like hosts)\n'
CLUN_SKIP_PERFORMANCE_TESTS=1 make test

printf 'phase-26-gate: test-tls\n'
make test-tls

printf 'phase-26-gate: test-crypto\n'
make test-crypto

printf 'phase-26-gate: hardening smokes\n'
sh scripts/phase-26-hardening-smokes.sh

printf 'phase-26-gate: all green\n'
