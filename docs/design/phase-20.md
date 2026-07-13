# Phase 20 — HTTPS

**Objective (PLAN §5/§3.4):** `fetch("https://…")` and the registry client's transport, over the
Phase-19 pure-CL TLS stack. TLS runs **blocking on the worker pool** (off the JS loop thread);
reactor-native TLS is post-v1. Fail closed on any certificate error; label the posture honestly.

**Gate:** hermetic HTTPS round-trip vs an in-process pure-tls server with a test CA (chain +
hostname exercised); a negative matrix (expired / wrong-host / self-signed / bad-chain each fail
closed with a distinct error); one live smoke (`fetch("https://registry.npmjs.org/left-pad")` →
parseable JSON) executed once and logged in STATE.md.

## 1. Architecture — blocking TLS on the worker pool

pure-tls's `make-tls-client-stream` / `make-tls-server-stream` take an already-connected **blocking
Lisp stream** and perform a **blocking** handshake + blocking byte I/O over a trivial-gray-streams
binary stream (`(unsigned-byte 8)`; read/write-sequence, read/write-byte, force-output, close). This
does NOT fit our non-blocking serve-event reactor (src/net/sockets.lisp). Per §3.2 we therefore run
the whole TLS request on a **worker thread**:

```
fetch("https://h/p")                       [JS loop thread]
  → %do-fetch: scheme https → %https-request-async
      → lp:worker-submit loop
          (lambda ()                         [WORKER thread — blocking]
            connect a BLOCKING sb-bsd-sockets stream to (resolve h):port
            pure-tls:make-tls-client-stream stream :hostname h :verify … :context <trust>
            write the serialized HTTP/1.1 request (reuse net::%serialize-request)
            read the full response, feeding net's http-response parser (reuse!)
            → (values :ok http-response) | (values :error code)   ; close the stream)
          (lambda (result)                   [JS loop thread — completion]
            build a Response (reuse web-fetch %build-fetch-response) → resolve/reject))
```

- The worker returns the parsed `net:http-response` (or an error code); the completion callback runs
  on the loop thread (via the Phase-05 mailbox + self-pipe) and resolves the fetch promise. No JS or
  engine object touched on the worker (only CL: sockets, pure-tls, the byte parser) → thread-safe.
- **Reuse:** `net::%serialize-request` (request bytes), the `net:make-http-response-parser` +
  `response-finish` (Phase 18), and `web-fetch`'s Response builder + redirect/abort logic. HTTPS is a
  new **transport** under the same fetch state machine; redirects across http↔https work naturally
  (each hop picks its transport by scheme).
- Timeouts: a `cl-cancel` deadline around the blocking handshake+I/O (pure-tls integrates cl-cancel),
  or a worker-side socket timeout; the fetch-layer AbortSignal cancels by closing the worker's socket.
- **New net file `src/net/tls-client.lisp`** (clun.net, pure CL, no engine dep) holds the blocking
  TLS request; `web-fetch` (runtime) calls it via the worker pool. gzip decode reuses `%decode-body`.

## 2. Trust store (§3.4)

`pure-tls:make-tls-context :ca-file … / :ca-directory …` builds a trust store; `load-certificate-chain`
loads PEM CAs. Client trust resolution, monotonic (never downgrade):
1. `SSL_CERT_FILE` / `SSL_CERT_DIR` env overrides (Node/OpenSSL convention) if set;
2. else the system PEM bundle — probe the usual Linux paths (`/etc/ssl/certs/ca-certificates.crt`,
   `/etc/pki/tls/certs/ca-bundle.crt`, `/etc/ssl/cert.pem`), first that exists wins;
3. tests inject the hermetic test CA via `SSL_CERT_FILE` (or a Clun-internal context override).
Verify mode defaults to `+verify-required+`; hostname verification via `verify-hostname` (SAN, CN
fallback, wildcards). A verification failure → a JS `TypeError` whose message names the specific cause
(the pure-tls condition class: `tls-verification-error` / `tls-certificate-expired` /
`tls-certificate-not-yet-valid` / `tls-alert-error`). Certs ALWAYS fail closed.

## 3. Test CA + fixtures (no in-lib generation)

pure-tls only parses/validates certs — it cannot generate them. So a small script generates a
hermetic test PKI **with `openssl`** at fixture-build time and checks the PEMs into
`tests/fixtures/certs/` (like the Phase-13 gzip fixture). Generated once by
`scripts/gen-test-certs.sh` (documented; re-runnable), committed:
- `test-ca.{key,crt}` — a self-signed CA.
- `localhost-leaf.{key,crt}` — CN/SAN `localhost` + `127.0.0.1`, signed by the CA (the good server cert).
- Negative leaves (each signed appropriately to isolate ONE failure): `expired.crt` (notAfter in the
  past), `wrong-host.crt` (SAN `other.example`), `self-signed.crt` (not chained to the CA),
  `bad-chain.crt` (signed by an unknown CA). openssl is a build-time fixture tool, NOT a runtime dep
  (§1.1 forbids runtime shell-outs; fixture generation is offline + checked in — same policy as the
  gzip fixture).

In-process pure-tls **server** fixture (`make-tls-server-stream :certificate … :key …`) runs on a
worker/thread accepting a loopback connection, so the HTTPS **client** path is exercised end-to-end
hermetically (no external network).

## 4. Gate tests (`make test-tls-https` or a runtime fixture)

- **Round-trip:** in-process pure-tls server (localhost-leaf, trust = test-ca) ↔ `fetch("https://
  localhost:PORT/…")` with `SSL_CERT_FILE=test-ca.crt` → JSON body round-trips; chain + hostname verified.
- **Negatives** (trust = test-ca, each must reject with a DISTINCT, catchable error):
  expired-leaf → certificate-expired; wrong-host (SAN mismatch) → verification/hostname error;
  self-signed → unknown-CA; bad-chain → chain verification error.
- **Live smoke (opt-in, logged):** `fetch("https://registry.npmjs.org/left-pad")` using the SYSTEM
  trust store → HTTP 200 + parseable JSON; run once behind an env flag, result logged in STATE.md.

## 5. fetch wiring

`web-fetch` `%do-fetch`: the current `unless (member scheme '("http"))` https-rejection becomes a
dispatch — `http` → the Phase-18 reactor client; `https` → `%https-request-async` (worker-pool TLS).
Both return the same `on-response`/`on-error` shape, so redirects, AbortSignal, timeout, gzip, and the
Response builder are unchanged. The connection-pool key (when pooling lands) gains the TLS config so a
plaintext socket is never reused for a TLS origin (monotonic).

## 6. Risks / fallbacks (PLAN §7)

- **pure-tls young/unaudited (High):** its suites are in CI (Phase 19); SRI sha512 is the independent
  integrity check (Phase 22); certs fail closed; posture labeled in README (Phase 26) + in errors.
- **Blocking-on-worker latency / thread exhaustion:** one worker per in-flight HTTPS request; the pool
  is bounded — many concurrent HTTPS requests queue (documented; acceptable for v1, matches §3.2).
- **System trust-store path variance:** probe a documented path list; `SSL_CERT_FILE` override always
  wins; if none found, HTTPS to public hosts fails closed with a clear "no system CA bundle" error.
- **cl-cancel timeout interaction with the worker:** a timeout/abort closes the worker's socket so the
  blocking pure-tls I/O unwinds with a socket error → mapped to a JS error; verify no worker leak.
- **openssl availability at fixture-build time:** the generated PEMs are checked in, so CI/build does
  not need openssl; only regenerating them does (documented in the script).
