# Phase 28: Transport Foundation

## 1. Scope of this unit

This unit removes two concrete transport blockers: TLS 1.2 interoperability with
the public npm registry and blocking libc IPv4-only hostname resolution. It adds
a pure Common Lisp TLS 1.2 fallback beneath the existing TLS 1.3 client, a
bounded DNS A/AAAA resolver, dual-stack connection racing, hardened response
decoding, and hermetic plus live public-registry evidence.

This is an implementation slice of Phase 28, not completion of the phase. The
canonical Phase 28 GitHub issue remains open. In particular, this unit does not
claim the issue's connection pooling, streaming bodies, backpressure, complete
cancellation/proxy/timeout matrix, 1 GiB transfer, leak/stress, or four-target
acceptance requirements. It does not promote a compatibility-ledger row or a
public landing-page claim.

## 2. Architecture

### 2.1 DNS and address-family racing

`dns.lisp` implements DNS directly over `sb-bsd-sockets`; production code does
not call `gethostbyname`, `getaddrinfo`, or an external resolver process. It
reads nameservers from `CLUN_RESOLV_CONF` or `/etc/resolv.conf`, sends bounded
recursive A and AAAA queries, validates transaction IDs/questions/opcodes and
section sizes, follows bounded compressed names and CNAME chains, and retries a
truncated UDP response over length-framed DNS TCP. Successful answers enter a
small TTL-bound cache. Literal IPv4, literal IPv6, and localhost avoid DNS I/O.

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

### 2.2 TLS interoperability

`https-request` keeps the existing vendored pure-tls TLS 1.3 client as the
preferred path. `pure-tls:make-tls-client-stream` eagerly completes its
handshake. Only an exact fatal `protocol_version` alert raised by that constructor
can select the TLS 1.2 path. The handler ends before any HTTP request bytes are
written, so a peer alert after request transmission cannot replay a POST or other
non-idempotent request.

The fallback opens a fresh TCP connection and uses `tls12-client.lisp`. The
supported TLS 1.2 profile is deliberately narrow:

- ECDHE over `secp256r1`;
- ECDSA P-256/SHA-256 or RSA SHA-256 authentication;
- RSA-PSS or RSA PKCS#1 v1.5 ServerKeyExchange signatures;
- AES-128-GCM with SHA-256;
- SNI and HTTP/1.1 ALPN;
- extended master secret when negotiated;
- system trust roots and hostname verification; and
- verified client and server Finished messages.

The ClientHello includes `TLS_FALLBACK_SCSV`. A TLS 1.3 downgrade sentinel in a
TLS 1.2 ServerHello is fatal. Duplicate ServerHello extensions, non-empty EMS,
invalid renegotiation information, compression, unsupported algorithms,
unsolicited CertificateStatus, post-handshake messages, malformed alerts, record
overflow, and authentication failures all fail closed.

No FFI, external TLS process, or shell command participates in production
networking. OpenSSL is used only as a hermetic test oracle.

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

## 4. Trust and signature policy

The trust bundle follows the established `SSL_CERT_FILE` override and system CA
candidate search. Verification is required by default and checks both the chain
and requested hostname.

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
- downgrade sentinels, duplicate extensions, and malformed EMS;
- plaintext record bounds;
- authenticated EOF requirements; and
- bounded, fail-closed content decoding.

The DNS and connection suite additionally covers exact query encoding,
compressed CNAME/A/AAAA parsing, canonical IPv6 rendering, truncation signaling,
malformed compression/bounds/transaction rejection, exact rcode mapping,
family interleaving, network-free literal handling, a hermetic UDP A/AAAA
resolver round trip, and an IPv6-to-IPv4 connection fallback against a local
listener.

`make test-tls12` runs that focused suite, then starts an OpenSSL TLS 1.2-only server with
`ECDHE-RSA-AES128-GCM-SHA256` and forces `rsa_pkcs1_sha256`. It proves a trusted
HTTP round trip and a real wrong-host rejection using the same listener.

`make smoke-npm` is an opt-in live check. It installs exact public package
`is-number@7.0.0`, verifies the registry SRI path used by the package manager,
and executes the installed package with the shipped Clun binary.

## 6. Remaining Phase 28 work

Before Phase 28 can close, the canonical issue still requires implementation and
evidence for at least:

- reusable origin-keyed connection pooling;
- streaming request and response bodies with bounded memory;
- backpressure, cancellation, proxy, and timeout semantics;
- the issue's large-transfer and adversarial transport fixtures;
- required Linux and macOS x64/arm64 evidence; and
- valid compatibility-ledger gate identifiers for the issue acceptance commands.

Until those requirements pass, the public compatibility state must remain at its
current non-`Yes` value even though public npm TLS interoperability is now proven
on the development host.
