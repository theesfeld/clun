# Phase 17 — HTTP server + `Clun.serve`

Objective (§5, §3.2, §3.6): Bun-shaped HTTP/1.1 serving — an own incremental parser, Request/Response/
Headers web classes (shared with Phase-18 fetch), `Clun.serve({port,hostname,fetch,error}) →
Server{stop,url,port}`, keep-alive, chunked both ways, 16 KB header / configurable body limits (431/413),
HEAD, Date header, `Clun.file` responses, 503 shedding. **Gate:** curl interop; malformed-request suite;
≥30k req/s loopback with real parsing + a JS handler; graceful shutdown drains in-flight; 1k-request RSS
plateau; examples/serve.ts smoke logged.

## 1. Layering

- **`src/net/http-parser.lisp` (clun.net, pure CL, no engine)** — an incremental request parser fed the
  octets the Phase-16 socket delivers. Highest §6 risk (adversarial lengths) → unit-tested standalone.
- **`src/runtime/web/` (clun.runtime, engine-facing)** — the JS classes `Headers`, `Request`, `Response`
  (installed as realm globals; reused by fetch in Phase 18).
- **`src/runtime/clun-serve.lisp` (clun.runtime)** — `Clun.serve`: wires the socket layer + parser + JS
  classes + the user's JS `fetch` handler; owns keep-alive, limits, graceful stop, 503 shedding.

## 2. The parser — "accumulate then parse" (robust over a byte-FSM)

`make-http-parser (&key (max-header 16384) (max-body (* 100 1024 1024)))`; `parser-feed (p octets) →
(values event data)`, event ∈ `:need-more | :request | :error`.
- Accumulate delivered octets into an adjustable buffer. **Headers phase:** scan for CRLFCRLF. Not found
  and buffer > max-header → `(:error 431)`. Found at p → parse the request line (`METHOD SP target SP
  HTTP/1.x`; reject anything else → 400) + header lines (`Name: value`, folding rejected, dup headers
  comma-joined; a bad line → 400). Determine framing: `Transfer-Encoding: chunked` (chunked) else
  `Content-Length: N` (validated non-negative integer; bad → 400; > max-body → 413) else no body.
- **Body phase:** content-length → wait for N bytes past the header terminator; chunked → de-chunk
  (hex size CRLF data CRLF … `0` CRLF CRLF; a size > remaining-body-budget → 413; malformed → 400). When
  the body is complete → `(:request REQ)`; leftover bytes (a pipelined next request) stay buffered and the
  parser resets for the next request (keep-alive). Everything is bounded by max-header + max-body — no
  unbounded growth, never a crash (§6): every malformed shape is a classified `:error <code>`.
- `REQ`: method, target, version, headers (alist of lowercased-name . value), body (octet vector),
  keep-alive-p (HTTP/1.1 default keep-alive unless `Connection: close`; HTTP/1.0 close unless
  `Connection: keep-alive`).

## 3. Web classes (`Headers`/`Request`/`Response`)

Built in CL against the engine object API (like node/events). **Headers**: a case-insensitive multimap
(get/set/append/has/delete/entries/keys/values/forEach + `@@iterator`); Set-Cookie kept distinct.
**Request**: `method`, `url`, `headers`, and buffered-body accessors `text()`/`json()`/`arrayBuffer()`/
`bytes()` (Promises over the parsed body octets). **Response**: `new Response(body?, {status,statusText,
headers})`, `Response.json(v,init)`, static, `.ok`/`.status`/`.headers`; body is a string / typed-array /
ArrayBuffer / `Clun.file` (buffered — read fully with Content-Length; chunked-file streaming is 🟡).

## 4. `Clun.serve` — fully async on the reactor

`Clun.serve(opts) → server`. `tcp-listen` on `{hostname (default 0.0.0.0/127.0.0.1), port}`; each
connection gets a parser. `on-data` feeds the parser; on `(:request req)` build a JS `Request`, call the
user `fetch(request)`. The handler may return a `Response` synchronously (write immediately) or a
`Promise<Response>` — attach `.then(write, onError)` (runs as a microtask; see §5). A handler throw / a
rejected promise / a non-Response → call the user `error` handler (or a default 500). **Serialize**:
status line + `Date` + the Response headers + framing (`Content-Length` for a known-length buffered body,
else `Transfer-Encoding: chunked`); HEAD writes headers only. **Keep-alive**: reuse the connection unless
`Connection: close` or the response opts out; a keep-alive idle timeout closes stale sockets.
**Limits**: parser 431/413 → a canned error response + close. **503 shedding**: above a max-in-flight /
max-connections cap, respond 503 + close. `server.stop()` (graceful): stop accepting, let in-flight
requests finish, close idle keep-alive sockets, resolve a Promise when the connection count hits 0.
`server.url`/`server.port` from the listener's real (port-0-resolved) port.

## 5. Loop change: drain microtasks after the reactor

The reactor dispatches fd handlers directly (not via `run-at-dispatch`), so a microtask queued inside a
socket `on-data` (e.g. an async fetch handler's `.then`) would not drain until an unrelated
timer/task/completion ran. `run-loop` gains a `drain-microtasks` call right after `reactor-poll`, making
"after the reactor" a proper dispatch point. This is additive (idempotent when the queue is empty) and
leaves Phase-05/06 ordering intact (nextTick-before-microtask still holds within the drain).

## 6. Gate + risks

CL parachute: parser unit + adversarial suite; an in-process integration test (a `Clun.serve` instance +
the Phase-16 `tcp-connect` as the client, both on one loop) covering GET/POST/keep-alive/chunked/HEAD/
404/500/limits; a curl-interop test (`sb-ext:run-program "curl"`) if curl is present (skipped-with-log
otherwise); a throughput measurement (≥30k req/s with a trivial JS handler); a graceful-shutdown test;
an RSS-plateau check. Risks: the async response path (microtask drain), chunked de-framing edge cases,
and hitting 30k req/s single-threaded (mitigated by a fast synchronous-Response path + minimal allocation).
Deferred 🟡: streaming/duplex bodies, routes/static, TLS server (Phase 20), WebSocket, HTTP/2.
