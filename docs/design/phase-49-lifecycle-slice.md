# Phase 49 — HTTP server lifecycle slice (Partial)

**Issue:** #23  
**Ledger:** `server.http` stays **Partial**  
**SemVer:** `0.1.0-dev.30` / minor within the `0.1.0` prerelease train

## Goal

Land a bounded Bun-compatible `Clun.serve` lifecycle slice without claiming full Phase 49 / `server.http` Yes.

## Scope (this unit)

| Surface | Behavior |
|---------|----------|
| `idleTimeout` | Seconds; default **10** (Bun); **0** disables; max **255**. Idle = no wire read/write; timer re-armed on data and response writes. |
| `maxRequestBodySize` | Bytes; when set, passed to the HTTP parser `max-body` budget; oversized Content-Length / bodies → **413**. Unset keeps `net:*max-body-bytes*`. |
| `server.stop(force)` | Falsy/omitted: stop accepting, drain in-flight (existing graceful). Truthy: close all active TCP connections immediately; Promise resolves when connection count hits 0. |
| Readback | `server.idleTimeout`, `server.maxRequestBodySize` |

## Non-goals

- Streaming request/response bodies
- TLS server / HTTPS serve options
- HTTP/2, Unix sockets, multi-listen, reusePort
- `server.timeout(req, seconds)` per-request override
- Full `make compat FEATURE=http-server` inventory / Yes promotion

## Tests

`tests/lisp/net/http-server-tests.lisp`:

- `net/server-max-request-body-size-413`
- `net/server-idle-timeout-closes-quiet-connection`
- `net/server-force-stop-closes-active-connection`

plus existing Phase 17 suite (graceful stop, keep-alive, pipeline, etc.).

## Implementation

- `src/runtime/clun-serve.lisp` — option parse, per-connection idle timer, active-connection list, force stop.
- Pure CL only; no CFFI / shell-outs.
