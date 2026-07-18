# Phase 65 application shell core

Status: implemented production milestone; full Phase 65 remains in progress.

This milestone exposes `Clun.$` and the global `$` alias as an application-facing tagged-template shell.
It parses shell source in Common Lisp and launches only programs requested by the application. It never
delegates parsing or execution to a host shell. Ordinary template expressions remain typed lexer units, so
their contents cannot create operators, substitutions, redirects, globs, or extra arguments.

## Runtime contract

- Lex quoting, escaping, comments, variables, `$?`, command substitution, pipelines, redirects, logical
  operators, sequences, assignments, grouped subshells, tilde expansion, and `Clun.Glob` expansion into an
  explicit AST.
- Treat scalar interpolation as one inert argument and flatten array interpolation into inert arguments with
  a bounded nesting depth. Only an explicit `{ raw: source }` interpolation opts source text into grammar.
- Execute `echo`, `basename`, `dirname`, `seq`, `yes`, `cat`, `mkdir`, `touch`, `rm`, `mv`, `ls`, `cp`, `pwd`, `cd`, `true`, `false`, `[[`,
  `:`, `export`, `unset`, `which`, and `exit` internally. `seq` uses Bun-compatible f32 accumulation and
  non-advance termination, bounds output to one million items, and additionally supports fixed-width and
  one floating printf conversion. `yes` matches the pinned Bun byte-buffer contract by repeating its joined
  arguments directly into the target typed-array view without constructing output proportional to the target.
  It also streams from a fixed 64 KiB producer block into an otherwise external pipeline, stopping when the
  consumer closes the pipe. Standalone unbounded `yes` still fails explicitly until job output can expose a
  streaming sink. The filesystem builtins provide bounded binary concatenation, stdin,
  display/numbering controls, parents/verbose/octal-mode creation, create-or-update timestamps, guarded
  recursive deletion, symlink boundaries, force/verbose flags, root preservation, atomic same-filesystem
  moves, multi-source directory targets, no-overwrite, and verbose move output. None of these paths delegates
  to an external command. `ls` provides deterministic hidden-entry policy, multi-path and recursive output,
  symlink-safe recursion, partial failures, reverse ordering, and lstat-based long metadata. `cp` streams
  regular files through a 64 KiB buffer, preserves modes and symlinks, handles multi-source and recursive
  targets, rejects identical/self-descendant copies, and replaces observed destination symlinks instead of
  intentionally writing through them. Regular destinations are opened with `O_NOFOLLOW`, and copied modes
  are applied to the open descriptor so a replacement race cannot redirect file contents or chmod.
- Evaluate the active non-todo conditional-expression subgroup internally: nonempty/empty strings, regular
  files, directories, character devices, and string equality/inequality. The same bounded evaluator handles
  symlinks, file identity, strict integer comparisons, lexical ordering, repeated negation, `&&`/`||`
  precedence, and parenthesized grouping. Conditional expansion preserves an unquoted empty variable as an
  empty operand. Compound expressions are parsed and short-circuited internally rather than being mistaken
  for outer script operators. Equality and inequality use shell-pattern matching while retaining a
  per-character protection mask, so quoted/escaped metacharacters and ordinary template interpolations remain
  literal while unquoted literal or variable-supplied patterns remain active. The same protection contract
  applies to the unanchored `=~` regular-expression operator. Malformed evaluated regex operands return status
  2, while a malformed operand in a short-circuited branch is not compiled. Integer comparison operands use a
  bounded signed-64-bit arithmetic parser with literals through base 64, unset-as-zero recursive environment
  names, parentheses, unary operators, exponentiation, multiplication/division/remainder, addition/subtraction,
  shifts, comparisons, bitwise operators, and logical operators. Syntax errors, variable cycles, invalid shifts,
  and zero division return status 1 without invoking a language evaluator.
- Resolve external programs against the job's `PATH`, require executable permission, and use
  `sb-ext:run-program` directly. The implementation does not invoke `sh`, `bash`, or another command parser.
- Spawn every command in an external-only pipeline before waiting. Intermediate streams are connected while
  the final stdout and all stderr are file-backed, preventing parent-side pipe-capacity deadlocks.
- Resolve supported output redirects left to right as descriptor destinations. `2>&1` and `1>&2` snapshot the current
  destination, later redirects do not move the duplicated descriptor, superseded pathname redirects still
  create or truncate their targets, and `&>` / `&>>` share one destination for both output streams.
- Stream an internal `yes` producer into an otherwise external pipeline without invoking a host `yes` binary.
  The producer uses bounded memory, observes downstream pipe closure, and preserves the last-command status.
- Isolate mutable cwd, environment, termination, and status state for every stage of a multi-command builtin
  pipeline. Immediate builtins that do not consume stdin close an upstream `yes` producer without materializing
  output, while the last stage still determines the pipeline exit code.
- Parse nested parenthesized groups recursively and execute them with copied environment, cwd, termination,
  and status state. Group stdin is propagated through the bounded pipeline executor, group output composes
  with surrounding pipelines, and group-local `exit`, assignments, and directory changes never leak outward.
- Parse `if` / `elif` / `else` / `fi` as recursive compound-command nodes rather than keyword-shaped simple
  commands. Conditions and branches retain ordered stdout and stderr, the selected branch determines status,
  a false condition without an alternative returns zero, `!` negates command status, and redirects apply to
  the whole compound command. Reserved words are structural only at command boundaries.
- Expose lazy job methods for cwd, environment, quiet/nothrow/throws, explicit one-shot `run`, Promise
  chaining, text, JSON, bytes, array buffers, and lines. `lines()` is a lazy async iterator with JavaScript
  split boundaries, including a trailing empty line after a final newline. Results and failures carry stdout,
  stderr, exit code, and conversion methods.
- Expose `new Clun.$.Shell()` as a callable shell tag with instance-local environment, cwd, and throw
  defaults. Child configuration is isolated from the realm default tag in both directions, and calling the
  class without `new` throws before creating an instance.
- Expand `Clun.$.braces()` with a bounded token/AST implementation: nested alternatives, adjacent-group
  products, surrounding text, escaped delimiters, empty input, and debug token/parse JSON. More than 256
  groups or 65,536 results is rejected before recursive expansion or result allocation can exhaust resources.
- Give `Clun.$.ShellError` its own Error-derived constructor and prototype, including meaningful
  `instanceof` behavior.

## Evidence

The finite upstream boundary is checked in under `tests/compat/tooling.shell/upstream/`: Bun 1.3.14 at
`0d9b296af33f2b851fcbf4df3e9ec89751734ba4` and Bun 1.4.0-dev at
`c1076ce95effb909bfe9f596919b5dba5567d550`. The snapshots contain 211 exact files spanning both complete
shell test trees, stable and engineering runtime/parser source roots, public bridge files, documentation,
types, fixtures, and upstream licenses. `upstream-files.tsv` binds every file to a SHA-256 digest and
`shell-upstream-inventory-check.sh` verifies the boundary offline.

`upstream-corpus.tsv` enumerates 1,630 lexical test sites from those exact snapshots. The initial conservative
disposition was 1,598 pending and 32 explicitly inactive at the pinned revisions. The current executable
mapping is 1,433 covered, 165 pending, and 32 upstream-inactive. `upstream-coverage.tsv` binds each credited
inventory ID to a checked-in shipped-binary fixture; regeneration rejects duplicate, stale, or unknown IDs,
and the corpus validator rejects missing evidence. `shell-upstream-corpus-check.sh` rejects inventory drift
or an unexplained disposition. Its `--yes` mode is the finite closure gate: it rejects any pending row and
also requires supported evidence receipts on Linux/macOS x64/arm64.

`tests/compat/tooling.shell/core.js` drives the shipped binary and freezes exact results for hostile scalar
interpolation, array boundaries, a 1 MiB producer/consumer pipeline, logical operators, command substitution,
cwd and environment, ordered descriptor redirects, output/error objects, Promise chaining, helper methods, and job-local
executable lookup. It also freezes callable `$.Shell` instances, constructor behavior, prototype identity,
bidirectional default isolation, nested brace products, debug output, and brace resource bounds.
`tests/compat/tooling.shell/builtins.js` freezes exact application behavior for path,
echo, exit, sequence, binary cat, mkdir, touch, guarded recursive rm, and mv builtins. The mv fixture covers
all six active scenarios in the pinned `commands/mv.test.ts`, plus usage, flags, and no-overwrite behavior.
It also freezes ls directory, hidden, long, recursive, multi-file, partial-error, invalid-option, and broken-link
behavior, plus cp file, directory-target, multi-source, recursive, no-overwrite, symlink, and error behavior.
The fixture also executes all three active pinned `commands/yes.test.ts` cases, a typed-array view-offset case,
an internal `yes | head` streaming case, and the explicit standalone unbounded-output boundary. The core
fixture independently drains 1 MiB from that internal producer to prove behavior beyond pipe capacity.
It also freezes active `pipeline_stack.test.ts` behavior for last-command status, `exit`, cwd and environment
isolation, immediate `yes` sinks, and a 20-stage builtin pipeline.
`tests/compat/tooling.shell/upstream-low-hanging.js` executes 104 exact stable and engineering inventory IDs
through `build/clun`: every pinned site for basename, dirname, exit, true, false, bounded-buffer yes, and
pathological command lookup, plus both revisions' brace helper cases and the engineering brace resource
bound. It also executes all three engineering brace-plus-glob composition sites, including interpolation
protection that keeps a comma inside one literal branch.
`tests/compat/tooling.shell/upstream-assignments.js` executes all 76 exact stable and engineering inventory IDs.
Assignment-only pipeline stages are isolated environment boundaries that forward their incoming bytes, so
middle and trailing assignment stages preserve pipeline data without leaking variables. The grouped
assignment pipeline runs through the recursive subshell AST rather than an approximation.
`tests/compat/tooling.shell/upstream-seq.js` executes 70 exact stable and engineering `seq` and focused
condition inventory IDs, including usage and option errors, non-finite number rejection, empty file predicates,
separators and terminators, descending ranges, f32 stalled progress, and command-substitution output. No
aggregate credit is used.
`tests/compat/tooling.shell/upstream-echo.js` executes all 41 exact `echo` IDs across the two baselines,
including invalid flags as data and the engineering two-or-more-trailing-newline regressions.
`tests/compat/tooling.shell/upstream-cp.js` executes all 32 exact `cp` IDs through hermetic file, overwrite,
multi-source, same-file, directory, verbose, repeated-source, and recursive cases.
`tests/compat/tooling.shell/upstream-ls.js` executes the deterministic `ls` IDs across both baselines,
including recursive and hidden listings, flags, multiple paths, unusual filenames, diagnostics, broken
symlinks, and the permission-sensitive `chmod 000` sites closed under PR #102.
`tests/compat/tooling.shell/upstream-mv-rm.js` executes 20 exact `mv` and `rm` IDs. The engineering concurrent
directory-to-symlink swap race remains pending until the actual mutation race is exercised.
`tests/compat/tooling.shell/upstream-pipeline-stack.js` executes 120 exact stable and engineering IDs for
builtin and subprocess stages, nested groups, depth, logical and sequential drains, errors, substitutions,
assignments, `seq`, and bounded `yes` streaming. The `pwd | cd | pwd` pair is covered with cwd isolation
(pipeline stdout is the last stage only; intermediate `cd` does not rewrite siblings' cwd).
`tests/compat/tooling.shell/upstream-lifecycle.js` executes 46 exact stable and engineering lifecycle and
pipeline residual IDs: default and concurrent `yes | head` epipe drains, 1 MiB non-blocking `echo | cat`
pipelines (literal and raw), hang policy fixtures under `$.throws`, concurrent external `true` load, bounded
parse/argv leak stress, sentinel byte round-trips (including raw injection without crash), and pure-CL
multi-chunk pipe write/read completion contracts that stand in for upstream LD_PRELOAD fault-injection sites.
`tests/compat/tooling.shell/upstream-control-flow.js` executes 124 exact stable and engineering IDs. It binds
all six pipeline-condition sites plus pinned `bunshell` branch paths, `elif` chains, false conditions,
linebreak placements, multi-command conditions and bodies, branch exit status, reserved-word arguments, and
whole-compound redirection to shipped-binary assertions. Background-command and brace-group cases remain
pending rather than being approximated.
`tests/compat/tooling.shell/upstream-file-io.js` executes all 51 exact stable and engineering file-I/O IDs.
Redirect targets are expanded and opened before command execution, so an open failure suppresses command
side effects and produces a status `1` result instead of an unrelated JavaScript rejection. The fixture also
freezes empty and large writes, truncation, append, quoted filenames, pipeline delivery, `/dev/null`, merged
stdout/stderr targets, and completion after the redirect writer's last external reference is dropped.
`tests/compat/tooling.shell/upstream-public-api.js` executes 50 exact IDs across `bunshell-instance`,
`bunshell-default`, `bunshell-file`, `shelloutput`, `throw`, `lazy`, and `yield` in both frozen baselines. A
runtime-branded Blob owns bounded copied bytes and Promise-based text/bytes/ArrayBuffer conversion. Shell
stdin accepts Blob, Buffer, Uint8Array, and Response bodies; bounded typed arrays accept stdout; `.blob()` is
available on ShellPromise, ShellOutput, and ShellError. The same fixture freezes isolated Shell defaults,
lazy start, local/global throw policy, Clun.file interpolation, 10,000-value expansion, and applicable
`/dev/full` recovery. The underlying filesystem writer preserves write errno instead of leaking raw stream
conditions across the JavaScript boundary.
`tests/compat/tooling.shell/upstream-exec.js` closes all 18 exact IDs from both pinned `exec.test.ts`
baselines. The `clun exec <script>` CLI dispatches through the same Common Lisp parser and executor as
`Clun.$`, with no host shell. It preserves cwd and environment, writes arbitrary stdout and stderr bytes,
normalizes command lookup failure to the CLI contract, resolves the current Clun executable when `PATH` is
empty, and freezes help, large output, builtin diagnostics, default `cd`, and a non-ASCII cwd through the
shipped binary.
`tests/compat/tooling.shell/upstream-positionals.js` closes all 10 exact IDs from both pinned
`env.positionals.test.ts` baselines. Application shell tags expose the realm's `process.argv` through `$0`
to `$9`; `clun run` executes standalone `.bun.sh` files with the script path at `$0` and user arguments at
the remaining positions. Missing values expand empty, `$10` composes `$1` with a literal zero, and Unicode
arguments round trip through the shipped binary.
`tests/compat/tooling.shell/upstream-language.js` executes 207 exact IDs across both pinned
`bunshell.test.ts` baselines. Nested interpolation arrays are accepted through depth 100 and rejected
synchronously beyond it. Backslash-newline pairs are removed by the lexer outside single quotes, empty
command substitutions retain their exit status, and `echo` distinguishes one trailing newline from runs of
two or more. Dollar and historical backtick command substitutions now preserve quoted multiline output;
backticks remove line continuations before parsing their bodies. The fixture also freezes escape output and
round trips, inert special-character interpolation, compact operators, Unicode and Latin-1 values, tilde
expansion, continuation behavior, concurrent stdout, JS object interpolation, empty scripts, concatenated
command substitutions, Uint8Array/Buffer redirects, and unmatched-glob failure (assignment position keeps
the pattern; command position errors with `clun: no matches found`) through the shipped binary.
`tests/compat/tooling.shell/upstream-lex-parse.js` executes 101 of 102 exact stable and engineering
`lex.test.ts` / `parse.test.ts` inventory IDs through observable shell behavior: words, quotes, left-to-right
assignment expansion, braces, logical and pipeline operators, redirects including buffer targets, dollar and
backtick substitutions, if/elif/else, background-form rejection matching Bun's unsupported message, and
JS object-reference errors in quotes and command position. The engineering multi-error
newline-separated diagnostics site remains pending.
The conditional fixture freezes the active `shell-seq-condexpr.test.ts` empty-path regressions and the
non-todo `bunshell.test.ts` unary/string cases, including both conditional pipeline positions. It additionally
freezes the pinned GNU-bash-derived compound-expression cases for repeated negation, short-circuit operators,
operator precedence, compact/spaced grouping, lexical string ordering, glob equality, quoted and escaped
patterns, variable-supplied patterns, regex matching and syntax failures, and inert template interpolation.
It also freezes expression precedence, parentheses, based numbers, variable recursion, signed wrapping, bitwise
operators, malformed arithmetic, cycles, and zero division for integer comparisons.
`tests/lisp/runtime/shell-tests.lisp` separately
owns parser and built-in behavior without an external process dependency.

```sh
make phase-65-tagged-templates-check
make phase-65-shell-core-check
make shell-upstream-corpus-check
make shell-upstream-yes-check # intentionally blocked until the phase is complete
make purity
```

## Remaining Phase 65 work

This milestone is substantial application behavior, but it is not the complete frozen Bun contract. The
source and lexical-site inventories are now finite and immutable; their pending rows still require exact
mapping, production closure, and executable evidence. The ledger must not report `Yes` until the full
applicable corpus is mapped and passes,
including remaining control/background forms and builtins, shared-stream
interleaving and coercion behavior, async
line and blob surfaces, signal/exit ordering, cancellation, 1,000-job child/fd
and memory stress, and Linux/macOS x64/arm64 receipts. General concurrent builtin streaming and standalone
unbounded job-output sinks are still required. Recursive `rm` still requires a portable
descriptor-relative traversal before the directory-to-symlink replacement race can be considered closed on
all release targets. Those residuals remain owned by Issue #39.
