# Phases 69–70 — Formatter and Linter

**Issue:** [#190](https://github.com/theesfeld/clun/issues/190)  
**Parent epic:** [#177](https://github.com/theesfeld/clun/issues/177)  
**Ledger:** `tooling.formatter-linter` → **Yes**  
**SemVer:** `0.1.0-dev.57` / minor

## Decision

Full port of first-party source formatting and linting in pure Common Lisp.
Bun has **no** first-party `fmt`/`lint` surface; Deno ships `deno fmt` / `deno lint`.
Clun exceeds Bun by shipping both CLI and programmatic APIs. Purity is the
implementation language, not a feature exclusion. Soft-outs are rejected.

## Surface

| Capability | Clun | Bun | Deno |
|---|---|---|---|
| CLI format | `clun fmt` / `clun format` | No | `deno fmt` |
| CLI lint | `clun lint` | No | `deno lint` |
| Programmatic format | `Clun.format` / `.check` / `.file` | No | limited |
| Programmatic lint | `Clun.lint` / `.file` / `.rules` | No | limited |
| Languages (fmt) | JS/TS/JSX, JSON, YAML, CSS | — | broad |
| Modes | check / write / stdin / ignore | — | yes |
| Lint rules | versioned recommended set (pure-CL registration) | — | yes |
| Reporters | stylish + JSON | — | yes |
| Safe fixes | eqeqeq, no-debugger (and extensible) | — | yes |

## Implementation

- `src/fmt/format.lisp` — structural token reformatter (comment/string preserving,
  format(format(x)) idempotent) + JSON pretty via `write-json` + CSS/YAML helpers
- `src/fmt/lint.lisp` — production parser + `ast->sexp` rule walk, scope model,
  recommended rules, config load, fix application
- `src/runtime/clun-fmt-lint.lisp` — `Clun.format` / `Clun.lint` JS bindings
- CLI dispatch in `src/main.lisp` / `src/cli/args.lisp`

## Evidence

- `tests/lisp/fmt/fmt-lint-tests.lisp` — core suite
- `tests/compat/tooling.formatter-linter/basic.js` — shipped-binary fixture
- Platforms: linux-x64, linux-arm64, darwin-x64, darwin-arm64 → supported

## Non-goals (this unit)

- Prettier byte-identity (own deterministic contract; not claimed)
- Arbitrary foreign lint plugins (pure-CL rule registration only)
- Full tsc-class type-aware lint
