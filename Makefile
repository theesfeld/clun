# Makefile — build | test | purity | clean for clun (PLAN.md §3.7).
# Hermetic SBCL: no user/system init files are read.

SBCL       ?= sbcl
SBCL_FLAGS := --non-interactive --no-userinit --no-sysinit

.PHONY: all build test purity clean

all: build

## build — compile everything and save build/clun via save-lisp-and-die.
build:
	$(SBCL) $(SBCL_FLAGS) --load scripts/build.lisp

## test — run the parachute CL suites (exit nonzero on any failure).
test:
	$(SBCL) $(SBCL_FLAGS) --load scripts/test.lisp

## purity — fail on any CFFI/foreign-code token under src/ or vendor/ (§1.1).
purity:
	$(SBCL) $(SBCL_FLAGS) --load scripts/purity-scan.lisp

## conformance — test262 parse phase: 0 crashes + no pass-list regressions.
## CLUN_GEN=1 make conformance regenerates the pass-list (only grows).
conformance:
	$(SBCL) --dynamic-space-size 3072 $(SBCL_FLAGS) --load scripts/test262.lisp

## clean — remove the built binary and any in-tree fasls.
clean:
	rm -rf build
	find . -name '*.fasl' -not -path './vendor/*' -delete 2>/dev/null || true
	@echo "cleaned"
