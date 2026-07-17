# Makefile — build | test | purity | clean for clun (PLAN.md §3.7).
# Hermetic SBCL: no user/system init files are read.

SBCL       ?= sbcl
SBCL_FLAGS := --non-interactive --no-userinit --no-sysinit

CONFORMANCE_CLASSIFICATIONS ?= tmp-test/test262-exec-classifications.tsv
CONFORMANCE_SOURCE_REVISION ?= $(shell sh scripts/conformance-source-revision.sh)
CONFORMANCE_GAPS           ?= tests/conformance/exec-gaps.tsv
CONFORMANCE_REPORT         ?= docs/conformance/test262-execution.md
CONFORMANCE_VERIFY_DIR     ?= tmp-test/conformance-buckets-verify
PHASE_25B_M5_MANIFEST      ?= tests/conformance/phase-25b-m5.tsv
PHASE_25B_M6_MANIFEST      ?= tests/conformance/phase-25b-m6.tsv
FEATURE                    ?= all

.PHONY: all build test test-lisp test-cookie-resources test-glob test-js test-tls test-crypto registry-fixture purity bench \
		bench-check compile-tier-ceiling test-installer test-release-live-check \
		public-claims-check version-transition-check test-version-transition-check \
		compat compat-validate docs-generate docs-check test-compat-tools \
		test-yaml-upstream test-yaml-upstream-full \
		roadmap-check roadmap-sync \
		roadmap-verify-live \
		conformance-exec-compare phase-25b-m5-check phase-25b-m6-check \
		conformance-buckets conformance-buckets-check \
		conformance-buckets-verify clean

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

## test-cookie-resources -- architecture-sensitive CookieMap allocation bounds.
test-cookie-resources:
	$(SBCL) $(SBCL_FLAGS) --load scripts/test-cookie-resources.lisp

## test-glob -- Phase 30 focused Lisp bounds plus shipped public API/corpus/scanner.
test-glob: build
	$(SBCL) $(SBCL_FLAGS) --load scripts/test-glob.lisp
	(cd tests/compat/filesystem.glob && ../../../build/clun api.js | cmp api.out -)
	(cd tests/compat/filesystem.glob && ../../../build/clun match.js | cmp match.out -)
	CLUN_COMPAT_EXECUTABLE="$(CURDIR)/build/clun" sh tests/compat/filesystem.glob/upstream-match.sh
	CLUN_COMPAT_EXECUTABLE="$(CURDIR)/build/clun" sh tests/compat/filesystem.glob/scan.sh
	CLUN_COMPAT_EXECUTABLE="$(CURDIR)/build/clun" sh tests/compat/filesystem.glob/adversarial.sh
	CLUN_COMPAT_EXECUTABLE="$(CURDIR)/build/clun" sh tests/compat/filesystem.glob/stress.sh
	sh scripts/glob-upstream-inventory-check.sh

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

## test-crypto — RFC/FIPS/Wycheproof KATs plus focused Ironclad generated vectors.
## Runs in its own image, keeping the socket suites' reactor fd-pressure-free.
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

## phase-25b-m5-check -- require the frozen synchronous-generator slice to have
## exactly 43 owned passes while its 12 m11 and one Phase-37 controls still fail.
phase-25b-m5-check:
	CLUN_PHASE_25B_M5_MANIFEST='$(PHASE_25B_M5_MANIFEST)' \
		$(SBCL) --dynamic-space-size 6144 $(SBCL_FLAGS) --load scripts/phase-25b-m5.lisp

## phase-25b-m6-check -- require the frozen async-generator/iteration slice to
## have 407 owned passes while its seven m11 and 95 Phase-37 controls still fail.
## Set CLUN_PHASE_25B_M6_MODE=entry to reproduce the immutable dev.5 baseline.
phase-25b-m6-check:
	CLUN_PHASE_25B_M6_MANIFEST='$(PHASE_25B_M6_MANIFEST)' \
		$(SBCL) --dynamic-space-size 6144 $(SBCL_FLAGS) --load scripts/phase-25b-m6.lisp

## conformance-exec-compare -- run the complete execution corpus with the COMPILE
## tier off and eager, then require byte-identical per-file classifications.
conformance-exec-compare:
	SBCL='$(SBCL)' sh scripts/conformance-exec-compare.sh

## conformance-buckets -- run the execution corpus, generate both inventory
## artifacts in scratch, then publish them from that fresh complete ledger.
conformance-buckets: conformance-buckets-check
	rm -f '$(CONFORMANCE_CLASSIFICATIONS)'
	CLUN_EXEC=1 CLUN_CONFORMANCE_CLASSIFICATIONS='$(CONFORMANCE_CLASSIFICATIONS)' \
		$(SBCL) --dynamic-space-size 6144 $(SBCL_FLAGS) --load scripts/test262.lisp
	test -s '$(CONFORMANCE_CLASSIFICATIONS)'
	rm -rf '$(CONFORMANCE_VERIFY_DIR)/publish'
	mkdir -p '$(CONFORMANCE_VERIFY_DIR)/publish'
	$(SBCL) --script scripts/test262-buckets.lisp \
		--ledger '$(CONFORMANCE_CLASSIFICATIONS)' \
		--passlist tests/conformance/exec-passlist.txt \
		--gaps '$(CONFORMANCE_VERIFY_DIR)/publish/exec-gaps.tsv' \
		--report '$(CONFORMANCE_VERIFY_DIR)/publish/test262-execution.md' \
		--source-revision '$(CONFORMANCE_SOURCE_REVISION)'
	sh scripts/test262-buckets-publish.sh \
		'$(CONFORMANCE_VERIFY_DIR)/publish/exec-gaps.tsv' \
		'$(CONFORMANCE_VERIFY_DIR)/publish/test262-execution.md' \
		'$(CONFORMANCE_GAPS)' '$(CONFORMANCE_REPORT)'

## conformance-buckets-check -- exercise parser, validation, precedence, and
## digest invariants without running the 40,654-file corpus.
conformance-buckets-check:
	$(SBCL) --script scripts/test262-buckets.lisp --self-test

## conformance-buckets-verify -- rerun the complete execution corpus and reject
## checked-in public inventory artifacts that differ semantically from the live
## result. Only the fresh ledger path and source revision are ignored in compare.
conformance-buckets-verify: conformance-buckets-check
	rm -f '$(CONFORMANCE_CLASSIFICATIONS)'
	CLUN_EXEC=1 CLUN_CONFORMANCE_CLASSIFICATIONS='$(CONFORMANCE_CLASSIFICATIONS)' \
		$(SBCL) --dynamic-space-size 6144 $(SBCL_FLAGS) --load scripts/test262.lisp
	test -s '$(CONFORMANCE_CLASSIFICATIONS)'
	rm -rf '$(CONFORMANCE_VERIFY_DIR)'
	mkdir -p '$(CONFORMANCE_VERIFY_DIR)'
	$(SBCL) --script scripts/test262-buckets.lisp \
		--ledger '$(CONFORMANCE_CLASSIFICATIONS)' \
		--passlist tests/conformance/exec-passlist.txt \
		--gaps '$(CONFORMANCE_VERIFY_DIR)/exec-gaps.tsv' \
		--report '$(CONFORMANCE_VERIFY_DIR)/test262-execution.md' \
		--source-revision '$(CONFORMANCE_SOURCE_REVISION)'
	sh scripts/test262-buckets-compare.sh \
		'$(CONFORMANCE_VERIFY_DIR)/exec-gaps.tsv' \
		'$(CONFORMANCE_VERIFY_DIR)/test262-execution.md'

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

## compat -- rebuild, then run registered shipped-binary/static evidence for FEATURE=<stable-id>|all.
compat: build
	sh scripts/compat.sh run '$(FEATURE)'

## compat-validate -- validate the canonical ledger without building or using the network.
compat-validate:
	sh scripts/compat.sh validate

## docs-generate/docs-check -- render public claim blocks or verify checked-in byte identity.
docs-generate:
	sh scripts/compat.sh generate

docs-check:
	sh scripts/compat.sh check

test-compat-tools:
	sh scripts/test-compat-tools.sh

## test-yaml-upstream -- reproduce every current result in the pinned 402-case Bun YAML corpus.
test-yaml-upstream: build
	CLUN_COMPAT_EXECUTABLE="$(CURDIR)/build/clun" \
		sh tests/compat/data.yaml/upstream/bun-c1076ce95effb909bfe9f596919b5dba5567d550/run.sh

## test-yaml-upstream-full -- require the complete pinned Bun YAML corpus to pass.
test-yaml-upstream-full: build
	CLUN_YAML_REQUIRE_ALL=1 CLUN_COMPAT_EXECUTABLE="$(CURDIR)/build/clun" \
		sh tests/compat/data.yaml/upstream/bun-c1076ce95effb909bfe9f596919b5dba5567d550/run.sh

## version-transition-check -- enforce actual-impact SemVer across the pushed range.
version-transition-check:
	sh scripts/version-transition-check.sh

test-version-transition-check:
	sh scripts/test-version-transition-check.sh

test-installer:
	sh scripts/test-installer.sh

## test-release-live-check -- exercise the fail-closed Pages release-assets gate.
test-release-live-check:
	sh scripts/test-release-live-check.sh

## roadmap-check/sync -- validate the post-v0.1 ledger or reconcile its GitHub issues.
roadmap-check:
	sh scripts/roadmap.sh check

## roadmap-verify-live -- read GitHub and fail on duplicate, missing, or stale canonical issues.
roadmap-verify-live:
	sh scripts/roadmap.sh verify-live

roadmap-sync:
	sh scripts/roadmap.sh sync

## clean — remove the built binary and any in-tree fasls.
clean:
	rm -rf build
	find . -name '*.fasl' -not -path './vendor/*' -delete 2>/dev/null || true
	@echo "cleaned"
