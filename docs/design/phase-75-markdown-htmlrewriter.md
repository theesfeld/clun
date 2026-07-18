# Phase 75 — Markdown + HTMLRewriter (pure-CL checkpoint)

**Issue:** [#49](https://github.com/theesfeld/clun/issues/49) (phase) · [#135](https://github.com/theesfeld/clun/issues/135) (Yes child)  
**Branch:** `feat/issue-49-markdown-yes`  
**SemVer:** minor · candidate `0.1.0-dev.34`

## Scope of this unit

Ship Bun-compatible pure-CL surfaces:

| API | Shape |
|-----|--------|
| `Clun.markdown.html(source, options?)` | GFM-friendly Markdown → HTML string |
| `Clun.markdown.render(source, callbacks, options?)` | Callback-driven render |
| `Clun.markdown.react(source, options?)` | Minimal React-shaped wrapper (`div` + `__html`) |
| `new HTMLRewriter().on(sel, handlers).transform(input)` | Element/text/comment handlers, mutations |
| `HTMLRewriter.onDocument(handlers)` | Document doctype/text/comment/end hooks |

**In this unit:** pure-CL parser/renderer/rewriter, JS bindings, Lisp + shipped-binary fixtures, purity.

**Deferred (still Phase 75):** TOML / JSON5 / JSONL module loaders, full CommonMark/GFM corpus differential, async HTMLRewriter handlers blocking transform, full CSS selector combinator set (`+`/`~`), four-target Compatibility matrix rows (the frozen homepage matrix remains 30 features; this surface is beyond-matrix).

## Purity

- No CFFI, no JS parser import, no shell-out.
- Bounded input sizes (`+max-source-length+`), token/handler caps, nesting depth.

## Evidence

- Lisp: `tests/lisp/markdown/markdown-tests.lisp`, `tests/lisp/html/rewriter-tests.lisp`
- Shipped binary: `tests/compat/data.markdown/basic.js`, `tests/compat/data.html-rewriter/basic.js`
- `make purity` clean

## Honesty

This is a **release-bearing behavioral checkpoint**, not a matrix-row `Yes` promotion. Matrix promotion would require expanding the Phase-27 30-row ledger (governance change) plus four-target Compatibility receipts. Public docs must not claim matrix `Yes` for Markdown/HTMLRewriter until that exists.
