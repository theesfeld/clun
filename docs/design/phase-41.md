# Phase 41 — Runtime loader plugins (FULL PORT #187)

## Decision

`runtime.loader-plugins` is **Yes**. Implementation language is pure Common Lisp. Purity means
implementation language, not feature exclusion (epic #177).

## Surface

- **Bun.plugin-compatible:** `Clun.plugin({ name, setup })` with `onResolve`, `onLoad`, `onStart`,
  `onEnd`, `builder.module`, namespaces, loaders (`object`/`js`/`json`/`yaml`/`text`/`file`),
  `clearAll`.
- **Exceed Bun:** `plugin.list()`, `plugin.clear(name)`, `priority`, optional resolve `chain`,
  pure-CL `register-cl-plugin`, `plugin.registerHooks` / `register-node-module-hooks` (node:module style).
- **Integration:** import and require share `resolve-load-dependency`; virtual modules and custom
  namespaces register under `#plugin/<ns>/<path>` keys.

## Evidence

- `tests/lisp/engine/plugin-tests.lisp`
- `tests/compat/runtime.loader-plugins/basic.js`
- Four-target platform rows `supported`

## Non-goals for this unit

- Full bundler-only native `onBeforeParse` NAPI plugins (accepted as API no-op surface; build graph
  remains Phase 62–64 / 77 ownership for graph identity).
