# Phase 67 — Watch mode and state-preserving hot reload

**Issue:** [#188](https://github.com/theesfeld/clun/issues/188)  
**Parent epic:** [#177](https://github.com/theesfeld/clun/issues/177)  
**Ledger:** `tooling.hot-reload` → **Yes**  
**SemVer:** `0.1.0-dev.50` / minor

## Decision

Full port of Bun `--hot` / `--watch` in pure Common Lisp. Purity is the
implementation language, not a feature exclusion. Soft-outs are rejected.

## Surface

| Capability | Clun | Bun |
|---|---|---|
| `--hot` soft module reload | Yes | Yes |
| Preserve `Clun.serve` sockets + live TCP connections | Yes (identity registry + `server.reload`) | Yes |
| Preserve `globalThis` / process | Yes | Yes |
| Portable change detection without inotify/FSEvents FFI | Yes (stat-poll + coalesce) | Native watchers |
| `--watch` hard restart | Yes (in-process: stop servers, re-eval) | Process restart |
| `import.meta.hot` (accept/dispose/data/on/off/invalidate) | Yes (server runtime) | Documented as planned for `--hot` |
| `Clun.hot` introspection | Yes (exceed) | No |
| Failed-reload recovery | Yes (prior handlers/globals kept) | Partial |

## Evidence

- `tests/lisp/runtime/hot-reload-tests.lisp` — core suite
- `examples/e2e-hot-reload.sh` — shipped-binary four-target e2e
- Platforms: linux-x64, linux-arm64, darwin-x64, darwin-arm64 → supported

## Non-goals (this unit)

- Browser HMR / frontend dev server (`tooling.frontend-dev-server`, #189)
- Native inotify/FSEvents bindings (explicitly rejected by purity)
