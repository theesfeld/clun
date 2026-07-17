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
- Execute `echo`, `basename`, `dirname`, `seq`, `cat`, `mkdir`, `touch`, `rm`, `mv`, `ls`, `cp`, `pwd`, `cd`, `true`, `false`,
  `:`, `export`, `unset`, `which`, and `exit` internally. `seq` uses Bun-compatible f32 accumulation and
  non-advance termination, bounds output to one million items, and additionally supports fixed-width and
  one floating printf conversion. The filesystem builtins provide bounded binary concatenation, stdin,
  display/numbering controls, parents/verbose/octal-mode creation, create-or-update timestamps, guarded
  recursive deletion, symlink boundaries, force/verbose flags, root preservation, atomic same-filesystem
  moves, multi-source directory targets, no-overwrite, and verbose move output. None of these paths delegates
  to an external command. `ls` provides deterministic hidden-entry policy, multi-path and recursive output,
  symlink-safe recursion, partial failures, reverse ordering, and lstat-based long metadata. `cp` streams
  regular files through a 64 KiB buffer, preserves modes and symlinks, handles multi-source and recursive
  targets, rejects identical/self-descendant copies, and replaces observed destination symlinks instead of
  intentionally writing through them. Regular destinations are opened with `O_NOFOLLOW`, and copied modes
  are applied to the open descriptor so a replacement race cannot redirect file contents or chmod.
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
echo, exit, sequence, binary cat, mkdir, touch, guarded recursive rm, and mv builtins. The mv fixture covers
all six active scenarios in the pinned `commands/mv.test.ts`, plus usage, flags, and no-overwrite behavior.
It also freezes ls directory, hidden, long, recursive, multi-file, partial-error, invalid-option, and broken-link
behavior, plus cp file, directory-target, multi-source, recursive, no-overwrite, symlink, and error behavior.
`tests/lisp/runtime/shell-tests.lisp` separately
owns parser and built-in behavior without an external process dependency.

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
and memory stress, and Linux/macOS x64/arm64 receipts. Recursive `rm` still requires a portable
descriptor-relative traversal before the directory-to-symlink replacement race can be considered closed on
all release targets. Those residuals remain owned by Issue #39.
