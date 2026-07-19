# Phase 48 — Native-addon constitutional checkpoint and partial host

**Issue:** [#178](https://github.com/theesfeld/clun/issues/178)  
**Parent:** [#177](https://github.com/theesfeld/clun/issues/177) FULL PORT  
**Historical implementation slot:** `0.1.0-dev.66`

## Issue #215 adversarial disposition

**Current ledger state: Partial.** The pure-CL implementation is a useful registered-library and
addon-registry subset, but it does not satisfy the row's N-API/FFI/native-module capability. PR #213
and Issue #178 explicitly record that machine-code `.so`, `.dylib`, and `.node` loading remains
unsupported. Canonical Phase 48 Issue #22 requires the complete frozen N-API/V8/FFI corpus on all
four targets before any `Yes` claim. The earlier substitute-as-Yes disposition is superseded by the
post-fullport truth audit in Issue #215.

Clun does not load or call machine-code shared objects (`.so` / `.dylib` / `.node`). The implemented
**pure-CL host subset** provides:

| Surface | Realization |
|---------|-------------|
| `bun:ffi` | Virtual module: `FFIType`, `dlopen`, `linkSymbols`, `CFunction`, `ptr`, `CString`, `toBuffer` / `toArrayBuffer`, `read.*` / `write.*`, `JSCallback`, `viewSource`, `suffix`, `cc` |
| Pure-CL libraries | `Clun.ffi.registerLibrary` / `listLibraries`; builtin `clun_demo` |
| Linear memory | Bounds-checked pointer table + heap (Bun may crash on bad ptrs — Clun fails closed) |
| `cc()` | Pure-CL arithmetic C-like subset (no TinyCC / no C toolchain) |
| N-API class | `Clun.napi.defineAddon` / `loadAddon`, `process.dlopen` / `Clun.native.dlopen` for pure-CL addons |
| Packs | `.claddon` JSON manifests (`load-claddon-file`) |

## Missing capability boundary

Amending purity to allow CFFI / `sb-alien` / machine-code `dlopen` was **rejected**. The product law
requires pure Common Lisp. That constraint does not turn CL-implemented native-style modules or a
Bun-shaped facade into actual FFI, N-API, V8, or native C/C++ module compatibility. Phase 48 remains
open for a pure-CL implementation that meets the observable capability without a forbidden shortcut.

## Subset safety and ergonomics

- Bounds-checked memory reads/writes
- Inspectable pure-CL wrappers (`viewSource`)
- First-class library registration from JS without a toolchain
- N-API-style addon registry + `process.dlopen` for pure-CL names
- `.claddon` portable manifests

## Evidence

- `tests/lisp/ffi/ffi-tests.lisp` — engine-free + runtime suite
- `tests/compat/runtime.native-addons/basic.js` — public fixture (four-target)
- `make purity` — no CFFI / foreign tokens

These properties are useful Clun-specific additions, not evidence that the missing native ABI surface
has been exceeded. The `.claddon` loader is a shipped source checkpoint but has no explicit receipt in
either listed suite; current platform evidence therefore does not claim that path.

## Current gate

`features.tsv` row `runtime.native-addons` remains **Partial** with the machine-code and complete
N-API/V8/FFI corpus gap explicit. The four platform rows remain **unverified** for the full capability;
their receipts prove only the registered pure-CL subset. Promotion to `Yes` still requires the exact
gate in canonical Phase 48 Issue #22.
