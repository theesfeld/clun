# Phase 48 — Native-addon host: pure-CL process/hook + machine load boundary

**Issues:** [#22](https://github.com/theesfeld/clun/issues/22) (phase), [#265](https://github.com/theesfeld/clun/issues/265) (machine load/hook), [#178](https://github.com/theesfeld/clun/issues/178) (pure-CL subset)  
**Release train:** `0.2.0-dev.7` (candidate; includes secrets Yes + colored CLI + this unit)

## Operator decision (2026-07-20)

| Layer | Rule |
|-------|------|
| **Clun implementation** | Pure Common Lisp. No CFFI shortcuts for Clun features (TLS, crypto, vault, …). |
| **User addons** | Users load real machine-code shared libraries (`.so` / `.dylib` / `.node`). Clun **processes and hooks** them in CL (typed specs, marshalling, registry, errors). |

Purity is **not** a ban on user-loaded native code. The impurity is the user’s binary.

## Implementation

| Surface | Realization |
|---------|-------------|
| Allowlisted boundary | `src/ffi/machine-boundary.lisp` — sole file permitted to contain foreign load/call tokens (`make purity` skips it) |
| Pure-CL host | `src/ffi/core.lisp` — libraries, heap, N-API registry, `.claddon`, Bun.ffi-shaped API |
| JS surface | `bun:ffi`, `Clun.ffi`, `Clun.native`, `Clun.napi`, `process.dlopen` |
| Machine path | `dlopen` → `dlsym` → typed trampoline call; system libc smoke via `abs` |
| Pure-CL path | Registered libraries, virtual memory, defineAddon / load-addon |

## Ledger

`runtime.native-addons` = **Yes** with four-target `supported` platform rows and fixture evidence that exercises machine-code `abs` on system C libraries plus the pure-CL host suite.

## Evidence

- `tests/lisp/ffi/ffi-tests.lisp` — includes `ffi/machine-libc-abs`
- `tests/compat/runtime.native-addons/basic.js` — pure-CL + `machine abs:42`
- `make purity` — allowlist skip for the boundary module only

## Non-goals (still honest)

- Full V8 C++ API parity without further evidence
- Implementing Clun product features by linking C libraries
- OS keychain via FFI (secrets Yes is pure-CL vault)
