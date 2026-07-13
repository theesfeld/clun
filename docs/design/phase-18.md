# Phase 18 — HTTP client, fetch, URL

Objective (§5, §3.2): `fetch` against real (plaintext) servers + the WHATWG URL/URLSearchParams classes.
**Gate:** fetch vs the Phase-17 server — JSON round-trip, redirect chains, 4xx/5xx, gzip, abort→AbortError,
timeouts within 1.5×; a URL corpus (WPT-derived subset).

## 1. Layers

- **`src/runtime/web-url.lisp` (clun.runtime)** — the `URL` + `URLSearchParams` JS classes (a WHATWG URL
  parser in CL) + `node:url` (legacy parse/format) + the existing fileURLToPath/pathToFileURL. Self-
  contained + heavily unit-testable (no network).
- **`src/net/http-client.lisp` (clun.net, pure CL)** — a reactor HTTP/1.1 client over the Phase-16
  `tcp-connect`: send a request, parse the response (a response parser added to http-parser.lisp),
  de-chunk, gunzip (chipz), follow redirects, enforce timeouts, support abort. Callback-based.
- **`src/runtime/web-fetch.lisp` (clun.runtime)** — the `fetch(input, init)` global tying URL + the client
  + Headers/Request/Response (Phase 17) + AbortSignal (Phase 14) together; returns a `Promise<Response>`.

## 2. URL parser (WHATWG subset)

A CL state-machine-ish parser producing components: scheme, username, password, host, port, path (list),
query, fragment. Special schemes (http/https/ws/wss/ftp/file) get default-port elision + `//` authority +
`/`-normalized paths. Supports: absolute parse; **relative resolution** `new URL(rel, base)` (inherit
scheme/authority, resolve `.`/`..` path segments); IPv4 dotted + IPv6 `[::1]` hosts (parsed/validated
in-process); **non-ASCII host → a loud "IDNA not supported" TypeError** (§3.2); percent-encoding of the
path/query/fragment per the WHATWG encode sets; userinfo. The `URL` object exposes href/protocol/username/
password/host/hostname/port/pathname/search/searchParams/hash/origin + setters that re-serialize; toString/
toJSON. `URLSearchParams` (from a string / object / pairs / another USP): get/getAll/set/append/has/delete/
sort/forEach/entries/keys/values/@@iterator/toString (application/x-www-form-urlencoded, `+` for space);
mutations reflect back into the URL's search (a linked USP). `node:url`: `url.parse`/`format`/`resolve`
(legacy, best-effort over the WHATWG core) + fileURLToPath/pathToFileURL. Documented gaps: IDNA/punycode,
some WPT setter edge cases.

## 3. Response parser (added to http-parser.lisp)

`make-http-response-parser` + `response-feed` mirror the request parser but read a **status line**
(`HTTP/1.x SP code SP reason`) instead of a request line, and frame the body by Content-Length, chunked,
OR **read-until-close** (HTTP/1.0 / no length / `Connection: close`). Returns `(:response resp)` /
`:need-more` / `(:error …)`; `resp` carries status, reason, headers, body, keep-alive. Same bounded,
no-crash discipline.

## 4. HTTP client (reactor, callback-based)

`http-request (loop &key host port method path headers body timeout signal on-response on-error)`:
`tcp-connect`, on-connect write the serialized request (`METHOD path HTTP/1.1` + Host + headers +
Content-Length + `Accept-Encoding: gzip` + body), feed bytes to a response parser, and on `(:response r)`
decode the body (de-chunked already; if `Content-Encoding: gzip`, chipz:decompress), then `on-response`.
Timeouts via a ref'd `lp:set-timer` (connect+overall) → on-error "timeout". `signal` (an AbortSignal):
already-aborted → immediate abort; abort mid-flight → close + on-error the reason. A **connection pool**
keyed `(host port)` reuses idle keep-alive sockets (v1: a simple idle-socket cache; a miss dials a new
one). **Redirects:** on 301/302/303/307/308 with a `Location`, resolve it against the current URL and
re-request (≤20 hops; strip the Authorization header cross-origin; 303 → GET); surfaced to fetch as the
final response with the final URL.

## 5. fetch

`fetch(input, init)` → `Promise<Response>`. Normalize input (a string/URL/Request) + init
(method/headers/body/signal/redirect) into a request; parse the URL (must be http/https — https is
Phase 20, so a loud error for now unless we treat it as plaintext-to-TLS-later); resolve the host
(IP literal or "localhost"→127.0.0.1; other hostnames via `sb-bsd-sockets:get-host-by-name`, blocking on
the loop for v1 — documented); drive the client; on the client callback, build a `Response`
(status/statusText/headers/body) and resolve; a network error / abort / timeout → reject with a
`TypeError` (abort → an AbortError-named error). The Response body is buffered; `.text()/.json()/
.arrayBuffer()/.bytes()` return it (reusing the Phase-17 Response accessors). `redirect: "manual"` returns
the 3xx as-is; default follows.

## 6. Gate + risks

CL parachute: a URL suite (a WPT-derived subset — parse/resolve/components/searchParams/serialization); a
fetch integration suite driving a `Clun.serve` instance + fetch on ONE loop (JSON round-trip, 404/500,
redirect chain, gzip fixture decode, abort→AbortError, connect timeout). Risks: WHATWG URL edge cases
(documented subset); blocking DNS on the loop (only for non-localhost hostnames — the gate uses 127.0.0.1);
the reactor client's redirect/abort/timeout state machine. Deferred 🟡: HTTPS (Phase 20), streaming bodies,
cookies, HTTP/2, IDNA, worker-pool async DNS, connection-pool eviction policy.
