# Phase 50 - Router, static files, and FileSystemRouter

Status: accepted for milestone 1 after the pinned Bun route documentation, public types, and
`bun-serve-routes.test.ts` inventory. Later milestones remain subject to their own source and adversarial
reviews before the ledger can change to `Yes`.

## Objective

Convert `server.router` from `No` to an evidence-backed `Yes` without weakening the HTTP server's existing
ordering, resource, or path-safety guarantees. The completed phase covers the first-party route table,
static and file responses, and `FileSystemRouter`. This document freezes the architecture and the milestone
boundaries; no partial milestone authorizes the public `Yes` claim.

## Provenance

| Role | Revision | Paths |
| --- | --- | --- |
| Public baseline | Bun 1.3.14, `0d9b296af33f2b851fcbf4df3e9ec89751734ba4` | `docs/runtime/http/routing.mdx`, `packages/bun-types/serve.d.ts`, `test/js/bun/http` |
| Engineering inventory | Bun 1.4.0-dev, `c1076ce95effb909bfe9f596919b5dba5567d550` | same paths plus the server route-list implementation |
| Clun integration | exact phase branch | `src/runtime/clun-router.lisp`, `src/runtime/clun-serve.lisp`, `src/runtime/web-http.lisp` |

Stable behavior defines the public compatibility baseline. Engineering-pin behavior may add compatible
coverage but cannot silently redefine the stable contract.

## Architecture

Route compilation builds an immutable trie. Each node owns exact-segment children, at most one parameter
child, terminal route entries, and terminal wildcard entries. Matching walks exact, parameter, then wildcard
branches. A method miss continues to a less-specific route rather than incorrectly terminating lookup.
Parameter names remain on terminal entries, so patterns with the same structural shape cannot corrupt one
another's `request.params` keys.

Incoming request targets are split before decoding. Each segment is decoded independently using the
runtime's bounded WHATWG replacement-mode UTF-8 decoder, so encoded `/` never changes route structure and
malformed bytes become U+FFFD. Query and fragment text never participates in matching. Absolute-form
request targets use only their path for routing; request URL authority handling remains owned by the HTTP
server contract.

Compiled tables are replaced atomically on `server.reload(options)`. Existing connections read the table,
fallback, and error-handler cells at dispatch time; no request observes a half-compiled options object.
Static `Response` values are retained by identity for the server lifetime. A method-specific `HEAD` wins;
otherwise `GET` supplies the representation while wire serialization suppresses its body.

The implementation uses no Test262 or fixture-specific branches. Trie construction and lookup are
engine-independent except for the frozen JavaScript action values at terminal entries.

## Milestones

### M1 - First-party route table

- `Clun.serve({ routes })` accepts exact, `:parameter`, and terminal `*` patterns.
- Route values may be a handler, a static `Response`, a direct `Clun.file(...)`, `false`, or a per-method
  object. Direct files are materialized by M2's bounded file-response path.
- `fetch` is optional when at least one active route exists; an unmatched request receives 404 when absent.
- `request.params` contains decoded values, including wildcard capture.
- Exact/parameter/wildcard precedence, method fallback, implicit `HEAD`, async handlers, errors, and atomic
  `server.reload` are executable through the shipped runtime.
- Invalid patterns, duplicate parameter names, invalid values, and an empty routes-without-fetch options
  object fail before binding the listener.

M1 is a production capability but leaves the ledger `No`; the row describes the complete Phase 50 surface.

### M2 - Static and file responses

- Buffered static responses receive stable ETags and conditional `304` handling.
- File-backed responses re-stat safely, implement single byte ranges and conditional modification checks,
  and stream with backpressure rather than reading an unbounded file into memory.
- Missing files become 404 without hiding unrelated errors.
- Canonical-root checks reject traversal, symlink escape, special files, and time-of-check/time-of-use swaps.

The current M2 checkpoint implements the first three items through the shipped runtime. Route values accept
direct `Clun.file(...)` objects as well as file-backed `Response` objects; explicit `slice(begin, end)` windows
cannot be escaped with a client `Range`. Regular files are opened with no-follow semantics, validated through
the opened descriptor, and emitted through one reusable 64 KiB buffer. Queued pipeline slots retain frozen
response metadata rather than open files, so a connection owns at most the descriptor for its active file
response. Disconnect, truncation, and socket-write failure close that descriptor fail-closed.

Executable coverage includes stable buffered ETags, weak/list/wildcard `If-None-Match`, `If-Modified-Since`
precedence, custom ETag and Last-Modified fields, single/suffix/open byte ranges, 416 responses, ignored
multi-ranges, user-owned Content-Range, HEAD framing, MIME selection, live file mutation/deletion, missing
file fallback, symlink/FIFO rejection, a 16 MiB multi-chunk body, and abort followed by a healthy request.
The canonical-root/traversal policy remains an M2 exit item; this checkpoint does not complete M2 or change
the public ledger.

### M3 - FileSystemRouter

- Discover and match the pinned route styles, parameters, extensions, origin, and asset prefix.
- Refresh development inventories atomically and make production inventories immutable.
- Share the glob/path primitives already proven by Phase 30 while retaining router-specific precedence.

The current M3 checkpoint installs a branded `Clun.FileSystemRouter` constructor through the shipped
runtime. It builds a deterministic Next.js-style inventory from regular files, applies configured extension
priority, filters dot/build/dependency directories and symlinks, and caps route count, traversal depth, and
query pairs. Matching covers exact, dynamic, catch-all, and optional-catch-all precedence; decoded path
parameters; string, `Request`, and absolute-URL inputs; root and nested-index aliases; origin and asset-prefix
source paths; and query/parameter projections. `reload()` constructs the replacement inventory before
publishing it, so a failed refresh retains the prior table.

The shipped-binary fixture exercises a 72-route filtered tree, 3,000 query pairs, percent-decoding exactly
once, extension defaults, empty and invalid directories, symlink exclusion, route addition/removal, and
cached-inventory identity. The same gate also retains all M1/M2 HTTP, conditional, range, bounded-streaming,
and lifecycle evidence. M4 still owns exact pinned-manifest accounting, stress/resource bounds, production
inventory policy, and four-target receipts; this checkpoint does not change the public ledger.

### M4 - Completion evidence

- Execute the complete pinned stable and engineering route/static/FileSystemRouter manifest.
- Pass malformed encoding, ambiguous precedence, traversal, symlink, range, conditional, and reload
  adversaries on all four release targets.
- Load 100,000 synthetic routes within recorded construction, lookup, and RSS bounds.
- Run build, full tests, purity, documentation, public-claim, and four-target compatibility receipt gates.

Only M4 may change `server.router` to `Yes` or close the canonical phase issue.

## Bounds And Failure Policy

- At most 100,000 routes, 1,024 segments per pattern, 1,024 parameters per pattern, and 16,384 UTF-16 code
  units per pattern.
- Duplicate parameter names and parameter names beginning with a decimal digit are rejected.
- Wildcards are terminal, capture the unmatched suffix, and never outrank exact or parameter routes.
- Compilation completes before listener creation or reload publication; failure retains the prior table.
- A handler exception or rejected promise follows the existing server error path exactly once.
- A late promise cannot write after connection teardown, and route lookup does not alter response ordering.

## Public Claim Boundary

README, landing page, release metadata, and `compat/features.tsv` continue to report `No` until every
milestone and the exact four-target gate pass. Branch progress belongs outside generated GitHub Issue
markers. The eventual compatible addition is SemVer minor; the provisional release slot is dev.20 and may
be reassigned by readiness without changing the required transition class.
