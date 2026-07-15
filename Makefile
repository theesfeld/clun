# Makefile — build | test | purity | clean for clun (PLAN.md §3.7).
# Hermetic SBCL: no user/system init files are read.

SBCL       ?= sbcl
SBCL_FLAGS := --non-interactive --no-userinit --no-sysinit

.PHONY: all build test test-lisp test-js test-tls test-crypto registry-fixture purity bench \
		bench-check compile-tier-ceiling test-installer public-claims-check roadmap-check roadmap-sync \
		conformance-exec-compare clean

all: build

## build — compile FASLs in a disposable image, then save build/clun from a clean image.
## Keeping those processes separate prevents cold-build compiler state from bloating the executable.
build:
	$(SBCL) $(SBCL_FLAGS) --load scripts/registry.lisp --eval '(asdf:compile-system :clun)'
	$(SBCL) $(SBCL_FLAGS) --load scripts/build.lisp

## test — parachute CL suites + the tests/js + tests/ts harnesses (need the binary).
test: test-lisp test-ts test-js

test-lisp:
	$(SBCL) $(SBCL_FLAGS) --load scripts/test.lisp

## test-js — run the tests/js + tests/ts/runtime fixtures against build/clun.
test-js: build
	$(SBCL) $(SBCL_FLAGS) --load scripts/run-js-fixtures.lisp

## test-ts — the TS type-strip conformance harness (strip/ byte-exact + errors/).
test-ts:
	$(SBCL) $(SBCL_FLAGS) --load scripts/run-ts-strip.lisp

## test-tls — run pure-tls's own self-contained fiveam suites (Phase-19 gate).
## Separate gate step; NOT part of the default `test' target.  Excludes the
## interop suites (network/openssl/boringssl/resumption/cancel-integration/
## trust-store) that need drakma / external binaries / live network.
test-tls:
	$(SBCL) --dynamic-space-size 4096 $(SBCL_FLAGS) --load scripts/run-pure-tls-suites.lisp

## test-crypto — RFC/FIPS known-answer tests over ironclad (Phase-19 gate).  Own image
## (ironclad is not a clun/tests dep), so the socket suites' reactor stays fd-pressure-free.
test-crypto:
	$(SBCL) --dynamic-space-size 3072 $(SBCL_FLAGS) --load scripts/run-crypto-kats.lisp

## registry-fixture — start the Phase-21 in-process npm registry fixture on an ephemeral
## port, print its inventory, verify every tarball against its dist.integrity + one real
## over-the-wire round-trip.  The reusable entry point install tests (Phases 22–23) drive.
registry-fixture:
	$(SBCL) $(SBCL_FLAGS) --load scripts/registry-fixture.lisp

## purity — fail on any CFFI/foreign-code token under src/ or vendor/ (§1.1).
purity:
	$(SBCL) $(SBCL_FLAGS) --load scripts/purity-scan.lisp

## conformance — test262 parse phase: 0 crashes + no pass-list regressions.
## CLUN_GEN=1 make conformance regenerates the pass-list (only grows).
conformance:
	$(SBCL) --dynamic-space-size 3072 $(SBCL_FLAGS) --load scripts/test262.lisp

## conformance-exec — test262 EXECUTION phase (Phase 03+): run harness+test in a
## fresh realm, both modes; gates on 0 crashes + no exec-passlist regressions.
conformance-exec:
	CLUN_EXEC=1 $(SBCL) --dynamic-space-size 6144 $(SBCL_FLAGS) --load scripts/test262.lisp

## conformance-exec-compare -- run the complete execution corpus with the COMPILE
## tier off and eager, then require byte-identical per-file classifications.
conformance-exec-compare:
	SBCL='$(SBCL)' sh scripts/conformance-exec-compare.sh

## bench — Phase 25 benchmark suite (richards/deltablue/splay + startup) against build/clun.
## Self-relative (clun-vs-clun on a fixed workload); the >=5x gate is the ratio vs the Phase-24
## baseline in docs/benchmarks.md. Override reps with REPS=N.
bench: build
	sh bench/run.sh

## bench-check -- prove off/eager result identity, telemetry integrity, and record the
## best of nine source-tier ceiling samples for each Phase-25 benchmark.
bench-check: build
	sh scripts/bench-check.sh

## compile-tier-ceiling -- prove all 72 DeltaBlue user bodies compile, the only
## ineligible function is the generated untimed module wrapper, and compiled code executes.
compile-tier-ceiling: build
	sh scripts/compile-tier-ceiling.sh

## public-claims-check -- keep release/version/conformance facts aligned across docs and Pages.
public-claims-check:
	sh scripts/public-claims-check.sh

test-installer:
	sh scripts/test-installer.sh

## roadmap-check/sync -- validate the post-v0.1 ledger or reconcile its GitHub issues.
roadmap-check:
	sh scripts/roadmap.sh check

roadmap-sync:
	sh scripts/roadmap.sh sync

## clean — remove the built binary and any in-tree fasls.
clean:
	rm -rf build
	find . -name '*.fasl' -not -path './vendor/*' -delete 2>/dev/null || true
	@echo "cleaned"
