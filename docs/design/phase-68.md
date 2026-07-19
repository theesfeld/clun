# Phase 68 — Frontend development server and HMR

**Issue:** [#189](https://github.com/theesfeld/clun/issues/189)  
**Parent epic:** [#177](https://github.com/theesfeld/clun/issues/177)  
**Ledger:** `tooling.frontend-dev-server` → **Yes**  
**SemVer:** `0.1.0-dev.54` / minor

## Decision

Full port of Bun’s HTML-entry frontend development server and browser HMR in pure
Common Lisp. Purity is the implementation language, not a feature exclusion.
Soft-outs are rejected.

## Surface

| Capability | Clun | Bun |
|---|---|---|
| HTML module imports as routes | Yes | Yes |
| On-demand script/style transform graph | Yes (TS/JSX/CSS via pure-CL hooks) | Yes (bundled) |
| `development: true \| { hmr, console, origin, root }` | Yes | Yes |
| Browser HMR WebSocket + injected client | Yes | Yes |
| CSS hot path + full-reload fallback | Yes | Yes |
| Path isolation / origin allow-list | Yes (exceed) | Partial |
| Pure-CL stat-poll watcher (no FSEvents FFI) | Yes (exceed) | Native watchers |
| `Clun.devServer` introspection | Yes (exceed) | No |
| Soft integrate with `tooling.hot-reload` when present | Yes | N/A |

## Evidence

- `tests/lisp/runtime/frontend-dev-server-tests.lisp` — core suite
- `examples/e2e-frontend-dev-server.sh` — shipped-binary four-target e2e
- Platforms: linux-x64, linux-arm64, darwin-x64, darwin-arm64 → supported

## Non-goals (this unit)

- Full production `Bun.build` bundler graph (`tooling.bundler`, #180)
- Playwright browser automation in CI (covered by protocol + HTTP fixtures)
)
