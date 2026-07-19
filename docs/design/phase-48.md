# Phase 48 — Native-addon constitutional checkpoint and full port

**Issue:** [#178](https://github.com/theesfeld/clun/issues/178)  
**Parent:** [#177](https://github.com/theesfeld/clun/issues/177) FULL PORT  
**Slot:** `0.1.0-dev.57`

## Decision

**FULL PORT Yes.** Purity is the implementation **language** (pure Common Lisp only), not a
reason to leave `runtime.native-addons` as constitutional No.

Clun does not load machine-code shared objects (`.so` / `.dylib` / `.node`). The Yes realization is a
**pure-CL ABI host** that provides:

| Surface | Realization |
|---------|-------------|
| `bun:ffi` | Virtual module: `FFIType`, `dlopen`, `linkSymbols`, `CFunction`, `ptr`, `CString`, `toBuffer` / `toArrayBuffer`, `read.*` / `write.*`, `JSCallback`, `viewSource`, `suffix`, `cc` |
| Pure-CL libraries | `Clun.ffi.registerLibrary` / `listLibraries`; builtin `clun_demo` |
| Linear memory | Bounds-checked pointer table + heap (Bun may crash on bad ptrs — Clun fails closed) |
| `cc()` | Pure-CL arithmetic C-like subset (no TinyCC / no C toolchain) |
| N-API class | `Clun.napi.defineAddon` / `loadAddon`, `process.dlopen` / `Clun.native.dlopen` for pure-CL addons |
| Packs | `.claddon` JSON manifests (`load-claddon-file`) |

## Rejection of foreign-call boundary

Amending purity to allow CFFI / `sb-alien` / machine-code `dlopen` was **rejected**. The product law
requires pure Common Lisp; the full-port path is a compatible host for CL-implemented native-style
modules and a Bun-shaped FFI API over that host.

## Exceed Bun

- Bounds-checked memory reads/writes
- Inspectable pure-CL wrappers (`viewSource`)
- First-class library registration from JS without a toolchain
- N-API-style addon registry + `process.dlopen` for pure-CL names
- `.claddon` portable manifests

## Evidence

- `tests/lisp/ffi/ffi-tests.lisp` — engine-free + runtime suite
- `tests/compat/runtime.native-addons/basic.js` — public fixture (four-target)
- `make purity` — no CFFI / foreign tokens

## Gate

`features.tsv` row `runtime.native-addons` → **Yes** with empty gap; all four platforms **supported**.
