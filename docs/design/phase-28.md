# Phase 28: Transport Foundation

## 1. Scope of this unit

This implementation series removes concrete transport blockers around TLS 1.2
interoperability, blocking libc IPv4-only hostname resolution, and buffered-only
fetch bodies. It adds a pure Common Lisp TLS 1.2 fallback beneath the existing
TLS 1.3 client, a bounded DNS A/AAAA resolver, dual-stack connection racing,
incremental authenticated response delivery, streaming request bodies, hardened
response decoding, HTTP proxy routing, HTTPS CONNECT tunnels, origin-keyed
pure-tls HTTPS idle pooling, and hermetic plus live public-registry evidence.

This is an implementation slice of Phase 28, not completion of the phase. The
canonical Phase 28 GitHub issue remains open. In particular, this series does not
claim the issue's complete proxy matrix, broader pool stress, incremental
decompression, 1 GiB transfer, remaining HTTPS cancellation-race/leak stress, or
four-target acceptance requirements. It does not promote a compatibility-ledger
row to `Yes`. Issue #234 completed the bounded authenticated certificate profile,
and Issue #235 adds the alert and closure lifecycle described below. Neither unit
claims browser-grade or complete RFC 5280 WebPKI.

## 2. Architecture

### 2.1 DNS and address-family racing

`dns.lisp` implements DNS directly over `sb-bsd-sockets`; production code does
not call `gethostbyname`, `getaddrinfo`, or an external resolver process. It
reads nameservers from `CLUN_RESOLV_CONF` or `/etc/resolv.conf`, sends bounded
recursive A and AAAA queries, validates transaction IDs/questions/opcodes and
section sizes, follows bounded compressed names and CNAME chains, and retries a
truncated UDP response over length-framed DNS TCP. Successful answers enter a
small TTL-bound cache. Literal IPv4, literal IPv6, and localhost avoid DNS I/O.
Every resolver wait polls its caller's cancellation token at a bounded interval;
an aborted HTTP or HTTPS fetch therefore releases a DNS worker promptly instead
of retaining it until the resolver timeout.

Results are interleaved IPv6-first while retaining each family's answer order.
Plain HTTP submits resolution to Clun's fixed worker pool and hands the candidates
back to the reactor. `tcp-connect-happy` starts the first candidate immediately,
staggers later candidates by the RFC 8305 250 ms recommendation, advances early
when every live attempt fails, closes losing descriptors, and exposes only the
winning handle. Cancellation and timer teardown are marshalled back to the
owning reactor thread.

HTTPS resolves and races candidates inside its existing blocking worker. Its
candidate sockets are nonblocking only during the race; the winner returns to
blocking mode before pure-tls owns the stream. One connect deadline covers the
entire candidate race, and abort closes every in-flight candidate or the winner.

Fetch owns one abort listener for the complete redirect operation rather than one
listener per hop. Terminal fulfillment, rejection, timeout, and abort detach that
exact listener and cancel the current DNS/connect/TLS resource exactly once. Abort
rejections preserve the signal's supplied JavaScript reason, including primitive
values and `AbortSignal.timeout()`'s `TimeoutError`. A monotonic safety deadline is
fixed when the operation begins and each redirect receives only the remaining
budget, so redirects cannot renew it. HTTPS work uses the cancellable worker API;
cancellation closes the active transport and clears its timeout before publishing
the terminal callback.

### 2.2 TLS interoperability

`https-request` keeps the existing vendored pure-tls TLS 1.3 client as the
preferred path. `pure-tls:make-tls-client-stream` eagerly completes its
handshake. Only the exact `protocol_version` description raised by that constructor
can select the TLS 1.2 path. It is semantically fatal under RFC 9846 section 6
regardless of the ignored legacy alert-level byte. The handler ends before any HTTP request bytes are
written, so a peer alert after request transmission cannot replay a POST or other
non-idempotent request.

The fallback opens a fresh TCP connection and uses `tls12-client.lisp`. The
supported TLS 1.2 profile is deliberately narrow:

- ECDHE over `secp256r1`;
- ECDSA P-256/SHA-256 or RSA SHA-256 authentication;
- RSA-PSS or RSA PKCS#1 v1.5 ServerKeyExchange signatures;
- AES-128-GCM with SHA-256;
- SNI and HTTP/1.1 ALPN;
- required extended master secret;
- system trust roots and hostname verification; and
- verified client and server Finished messages.

The ClientHello includes `TLS_FALLBACK_SCSV`. Both RFC 8446 downgrade sentinels,
`DOWNGRD\\x01` and `DOWNGRD\\x00`, are fatal in a TLS 1.2 ServerHello. Duplicate
ServerHello extensions, non-empty EMS,
invalid renegotiation information, compression, unsupported algorithms,
unsolicited CertificateStatus or NewSessionTicket, post-handshake messages, malformed alerts, record
overflow, and authentication failures all fail closed.

Alert output has explicit terminal state in both protocol paths. TLS 1.2 parser,
record-authentication, negotiation, signature, and certificate failures carry a standard fatal
alert disposition and emit it at most once while the transport remains writable. TLS 1.3 maps
certificate parsing, hostname, validity, usage, chain, and trust failures to bounded certificate
alerts without putting local diagnostic text on the wire. A complete peer fatal is preserved as
the reported cause and never receives a response alert. Peer `close_notify` receipt is tracked
separately from local close transmission, so clean closure receives exactly one reciprocal
`close_notify`; fatal termination suppresses later record reads, alerts, and buffered
application-data output.
These protocol rules do not expand the cipher/profile surface or establish BoringSSL/browser
parity.

No FFI, external TLS process, or shell command participates in production
networking. OpenSSL is used only as a hermetic test oracle.

### 2.3 HTTP proxy routing and CONNECT tunnels

Fetch accepts an HTTP proxy URL through `init.proxy` or the conventional
lowercase/uppercase `http_proxy` and `https_proxy` environment variables. Empty
and quoted-empty environment values disable proxying. `NO_PROXY`/`no_proxy`
supports wildcard, exact host, domain suffix, bracketed IPv6, and exact optional
port matching; malformed or empty entries are ignored safely. Proxy URL
credentials are percent-decoded and sent as Basic credentials without leaking
them into the absolute request target.

Plain HTTP dials the proxy and serializes the origin URL in absolute form while
retaining the origin `Host` header. Proxy hop headers are shaped separately from
origin headers; direct and bypassed requests also strip proxy hop headers rather
than exposing credentials to an origin. Proxied connections are excluded from
the direct-origin pool. This avoids reusing an authentication failure or
cross-origin proxy socket under the wrong pool identity.

HTTPS sends one bounded, split-safe CONNECT request before constructing the TLS
stream. A successful 2xx envelope is consumed completely and never reaches the
origin response parser. Certificate and hostname verification remain bound to
the origin, not the proxy. The TLS 1.2 fallback opens a fresh connection and
repeats CONNECT before its new handshake. Non-2xx CONNECT replies are exposed as
proxy HTTP responses and marked so Fetch never follows them as origin redirects.
Proxy authorization and `Proxy-Connection` are removed from the tunneled origin
request.

## 3. Bounded data flow

TLS record plaintext is limited to 16 KiB and ciphertext is bounded before
allocation. Handshake messages and the coalescing buffer have explicit limits.
Handshake and response accumulators grow geometrically rather than copying the
entire accumulated value for every record.

The HTTP wire response is limited to the parser's header plus body limits.
TLS errors are never converted to EOF. For an HTTP response whose body is framed
by `Content-Length` or chunked encoding, completed authenticated application data
is sufficient even if a TLS 1.2 peer then closes TCP without `close_notify`. For
an until-close body, the peer must send authenticated `close_notify`; otherwise
the response is rejected as potentially truncated.

Gzip and deflate decoding use a bounded streaming sink. Malformed compressed
content and decoded output beyond `*max-decoded-body-bytes*` signal
`http-content-decoding-error`; compressed bytes are never returned as though
decoding had succeeded.

Identity response bodies now leave the HTTP parser incrementally. Plain HTTP
pauses reactor reads when the JavaScript stream crosses its high-water mark;
HTTPS permits only one worker-to-loop delivery at a time and blocks the worker
while the consumer is paused. Response cloning uses a bounded tee instead of
collecting the source before either branch can read.

ReadableStream request bodies remain streams through fetch normalization and
require `duplex: "half"`. Plain HTTP pulls at most one body chunk ahead of the
socket, waits for the drain edge before the next pull, and leaves inbound reads
paused until the sole terminal chunk is queued. HTTPS crosses the worker boundary
with one outstanding reader promise and writes each chunk as an authenticated TLS
record before pulling again. Both TLS 1.3 and the fresh-connection TLS 1.2 fallback
use the same bounded source contract. User-provided `Content-Length` and
`Transfer-Encoding` are rejected for stream bodies; aggregate request bytes are
bounded by `*max-body-bytes*`; cancellation wakes upload and response wait sites;
and a source rejection remains the fetch rejection reason.

Plain HTTP/1.1 now reuses eligible connections from a pool owned by the event
loop. Pool keys include the normalized origin host, port, selected address family,
and transport kind. A connection is admitted only after exact response framing,
no trailing bytes, persistent request and response semantics, a completed upload,
and an empty write queue. Idle sockets retain their read registration so EOF or
unsolicited bytes evict them, but both the socket handle and 30-second eviction
timer are unreferenced and therefore cannot keep a realm alive. Each key retains
at most eight idle sockets. Loop destruction closes the registered TCP resources
before releasing the loop-owned pool state.

## 4. Trust and signature policy

The trust bundle follows the established `SSL_CERT_FILE` override and system CA
candidate search. Verification is required by default and checks both the chain
and requested hostname. Issue #234 completed an experimental bounded profile with
SAN-only identity, cumulative intermediate EKU policy, strict key/encoding/strength
and depth bounds, and fail-closed unsupported path semantics. It remains narrower
than browser WebPKI: name-constraint paths reject, and revocation, CT, AIA,
alternate-path building, and the full RFC 5280 policy tree are not implemented.

TLS 1.3 retains its existing signature-algorithm allowlist. The shared
CertificateVerify helper now accepts an explicit protocol policy. TLS 1.2 may
use PKCS#1 only when its caller supplies the narrow SHA-256 allowlist. PKCS#1
verification uses the vendored RFC 8017 verifier, including exact DigestInfo
length and padding checks, rather than Ironclad's raw RSA verification method.

## 5. Evidence

The focused deterministic Lisp suite covers:

- the TLS 1.2 SHA-256 PRF;
- AES-GCM record authentication and tamper rejection;
- ClientHello SNI, ALPN, EMS, and fallback SCSV;
- exact fallback-alert selection;
- downgrade sentinels, duplicate/unsolicited extensions, malformed EMS, ALPN,
  and EC point-format acknowledgements, and unsolicited session tickets;
- plaintext record bounds;
- authenticated EOF requirements; and
- bounded, fail-closed content decoding.

The DNS and connection suite additionally covers exact query encoding,
compressed CNAME/A/AAAA parsing, canonical IPv6 rendering, truncation signaling,
malformed compression/bounds/transaction rejection, exact rcode mapping,
family interleaving, network-free literal handling, a hermetic UDP A/AAAA
resolver round trip, and an IPv6-to-IPv4 connection fallback against a local
listener. A silent local resolver additionally proves that cancellation interrupts
the in-flight wait and returns `ECANCELED` without waiting for the resolver deadline.

The fetch integration suite covers pre-aborted signals, primitive abort reasons,
and a multi-hop redirect that installs and removes exactly one listener without
leaving it attached after settlement. Streaming coverage additionally verifies
byte-exact HTTP chunk framing, mandatory half-duplex validation, framing-header
rejection, source-error identity, reader lock release, and the HTTPS
worker-to-loop pull bridge. Timeout coverage preserves `TimeoutError` before
headers and while consuming a partial body, proves one safety deadline across
redirect hops, and proves reader cancellation closes an incomplete transport
without admitting it to the pool.

The plain HTTP pool tests prove that two sequential fetches to one origin return
the same TCP wrapper to the idle pool, while an explicit `Connection: close`
request is never pooled. A peer FIN while idle evicts the stale wrapper before a
later request reconnects, and simultaneous same-host/different-port origins retain
distinct TCP identities. Parser tests separately reject EOF-delimited bodies,
close responses, and bytes trailing a complete message as reusable. The complete
network subset passes at this checkpoint with 124 top-level suites, 3,764
assertions, zero failures, and zero skips.

`make test-proxy` validates nine contract mappings against Bun engineering commit
`c1076ce95effb909bfe9f596919b5dba5567d550`, then executes six hermetic suites.
They cover absolute-form HTTP requests, percent-decoded Basic credentials,
407 response delivery, disabled proxy environment values, `NO_PROXY` port and
domain rules, a CONNECT envelope split across reads, proxy-header isolation, and
non-2xx CONNECT response delivery without redirect handling, including an
end-to-end Fetch 302 response with a `Location` that is not followed. CONNECT 101
and unsupported `ftp`, SOCKS, and WebSocket proxy schemes reject before origin I/O.

`make test-tls-alerts` runs deterministic malformed record, handshake, certificate,
peer-fatal, and clean-closure fixtures and asserts the exact emitted alert records plus one-shot
state. `make test-tls12` requires that alert suite, then runs the broader focused transport suite
and starts OpenSSL TLS 1.2-only peers
with `ECDHE-RSA-AES128-GCM-SHA256` and forces `rsa_pkcs1_sha256`. It proves a
trusted HTTP round trip, incremental response delivery, a streamed POST whose
decrypted request has exact chunk framing, and a real wrong-host rejection. The
required CI, Compatibility, and Release `make test-tls` gate includes this work
and the complete pure-tls suite. The upload oracle accepts the TLS 1.3 probe and
the fresh TLS 1.2 fallback connection,
which also proves that the non-replayable source is not consumed before fallback.
The focused parser policy rejects both RFC 8446 downgrade sentinels, duplicate or
unsolicited ServerHello extensions, malformed extension acknowledgements, and
peers that do not negotiate Extended Master Secret.

`make smoke-npm` is a live, non-hermetic check required in the Compatibility and
Release workflows; local invocation remains optional. From empty manifests it exercises both
`clun add is-odd@3.0.1` (including its transitive `is-number` dependency) and Bun-compatible
`clun install left-pad@1.3.0`, verifies each registry SRI path, executes each
installed package with the shipped Clun binary, then deletes `node_modules` and
proves byte-identical frozen cache-only reinstalls while the configured registry
is deliberately unreachable and `SSL_CERT_FILE` names an explicit empty trust
source. The latter is authoritative and prevents fallback to system/custom roots,
so a missing cache entry cannot be repaired by downloading its public HTTPS
tarball. SRI authenticates cached bytes against the lockfile's recorded integrity;
on fresh resolution that integrity is itself obtained from TLS-authenticated
registry metadata rather than being an independent trust root.

## 6. Remaining Phase 28 work

Before Phase 28 can close, the canonical issue still requires implementation and
evidence for at least:

- origin-keyed pure-tls HTTPS idle pooling is landed; broader TLS/HTTP pool stress and eviction matrix remains;
- HTTPS proxy endpoints, proxy object options and pooling, the broader proxy
  stress/error matrix, and the remaining HTTPS cancellation-race/leak matrix;
- the issue's large-transfer and adversarial transport fixtures; and
- required Linux and macOS x64/arm64 evidence.

Compatibility gate identifiers are the real ledger IDs
`runtime.web-standard-apis` and `package-manager.npm` (not the historical
aliases `transport` / `fetch` / `public-npm`). `make compat FEATURE=…` for those
IDs is valid and executable; rows remain **Partial** until the remaining
acceptance matrix and four-target receipts pass.
