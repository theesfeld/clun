# Phase 65 application shell core

Status: implemented production milestone; full Phase 65 remains in progress.

This milestone exposes `Clun.$` and the global `$` alias as an application-facing tagged-template shell.
It parses shell source in Common Lisp and launches only programs requested by the application. It never
delegates parsing or execution to a host shell. Ordinary template expressions remain typed lexer units, so
their contents cannot create operators, substitutions, redirects, globs, or extra arguments.

## Runtime contract

- Lex quoting, escaping, comments, variables, `$?`, command substitution, pipelines, redirects, logical
  operators, sequences, assignments, tilde expansion, and `Clun.Glob` expansion into an explicit AST.
- Treat scalar interpolation as one inert argument and flatten array interpolation into inert arguments with
  a bounded nesting depth. Only an explicit `{ raw: source }` interpolation opts source text into grammar.
- Execute `echo`, `basename`, `dirname`, `seq`, `pwd`, `cd`, `true`, `false`, `:`, `export`, `unset`,
  `which`, and `exit` internally. `seq` uses Bun-compatible f32 accumulation and non-advance termination,
  bounds output to one million items, and additionally supports fixed-width and one floating printf
  conversion without delegating formatting to an external command.
- Resolve external programs against the job's `PATH`, require executable permission, and use
  `sb-ext:run-program` directly. The implementation does not invoke `sh`, `bash`, or another command parser.
- Spawn every command in an external-only pipeline before waiting. Intermediate streams are connected while
  the final stdout and all stderr are file-backed, preventing parent-side pipe-capacity deadlocks.
- Expose lazy job methods for cwd, environment, quiet/nothrow/throws, explicit one-shot `run`, Promise
  chaining, text, JSON, bytes, array buffers, and lines. `lines()` is a lazy async iterator with JavaScript
  split boundaries, including a trailing empty line after a final newline. Results and failures carry stdout,
  stderr, exit code, and conversion methods.
- Give `Clun.$.ShellError` its own Error-derived constructor and prototype, including meaningful
  `instanceof` behavior.

## Evidence

`tests/compat/tooling.shell/core.js` drives the shipped binary and freezes exact results for hostile scalar
interpolation, array boundaries, a 1 MiB producer/consumer pipeline, logical operators, command substitution,
cwd and environment, redirects, output/error objects, Promise chaining, helper methods, and job-local
executable lookup. `tests/compat/tooling.shell/builtins.js` freezes exact application behavior for path,
echo, exit, and sequence builtins. `tests/lisp/runtime/shell-tests.lisp` separately owns parser and built-in
behavior without an external process dependency.

```sh
make phase-65-tagged-templates-check
make phase-65-shell-core-check
make purity
```

## Remaining Phase 65 work

This milestone is substantial application behavior, but it is not the complete frozen Bun contract. The
ledger must not report `Yes` until the pinned source inventory and full applicable corpus are mapped and pass,
including remaining control/background forms and builtins, exact descriptor/coercion/error behavior, async
line and blob surfaces, ordered descriptor redirects, signal/exit ordering, cancellation, 1,000-job child/fd
and memory stress, and Linux/macOS x64/arm64 receipts. Those residuals remain owned by Issue #39.
