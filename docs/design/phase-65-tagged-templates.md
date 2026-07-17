# Phase 65 tagged-template prerequisite

Status: implemented engine slice; Phase 65 remains in progress.

This slice implements ECMAScript tagged-template execution because Bun-compatible `$` shell interpolation
must begin at the language call boundary. It does not expose `$`, execute commands, or change the
`tooling.shell` compatibility status. The shell row can become `Yes` only after the complete Phase 65
contract and its Linux/macOS x64/arm64 gates pass.

## Runtime contract

- Evaluate the tag reference first and preserve the base object as `this` for member and super-member tags.
- Reject a non-callable tag before creating a template object or evaluating any substitution.
- Evaluate substitutions exactly once from left to right, then call the tag with the template object first.
- Create one cooked array and one `raw` array per syntactic template site and realm, then reuse their identity.
- Define `raw` as non-writable, non-enumerable, and non-configurable; freeze both arrays.
- Preserve invalid tagged escapes as `undefined` cooked entries while retaining their exact raw code units.
- Normalize CR and CRLF to LF in raw template values as required by Template Raw Value semantics.

The realm owns an identity-keyed template registry. AST identity distinguishes syntactic sites, while the
realm lifetime bounds the cache and prevents template objects from crossing realms. The lexer now recognizes
the realm-aware JavaScript condition used by invalid Unicode escapes; untagged invalid escapes continue to
throw.

## Evidence and gates

The focused Lisp test covers ordinary calls, site identity, frozen descriptors, receiver binding, computed
member and substitution order, invalid escapes, and non-callable short-circuiting. The shipped-binary fixture
at `tests/compat/tooling.shell/tagged-template.js` repeats the security-relevant observable contract and is
registered as prerequisite evidence without asserting shell completion.

The frozen Test262 `language/expressions/tagged-template` directory has 27 files. This slice produces 23 pass,
one fail, three skip, zero timeout, and zero crash. The single failure,
`cache-eval-inner-function.js`, depends on the existing direct-eval lexical-environment residual owned outside
this slice. `cache-realm.js` is skipped by the cross-realm policy and the two TCO rows by the tail-call policy.
The focused gate freezes both the denominator and every classification:

```sh
make phase-65-tagged-templates-check
make compat FEATURE=tooling.shell
```

## Remaining Phase 65 work

The canonical Phase 65 issue still owns the public `$` tag, interpolation escaping, shell parser and AST,
variables and quoting, expansion and glob integration, substitutions, pipelines, redirects, logical and
control forms, background jobs, builtins, process execution, output conversion, cwd/env options, quiet and
nothrow modes, `ShellError`, platform dispositions, injection proofs, concurrent backpressure, signal and exit
ordering, leak stress, and four-target release evidence. Until all of that passes, public status stays `No`.
