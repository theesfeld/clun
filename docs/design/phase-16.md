# Phase 16 — Sockets

Objective (§5, §3.2): a non-blocking TCP handle layer on the Phase-05 serve-event reactor —
connect/accept/read/write with EAGAIN→NIL, write queues + backpressure, IPv6, port-0 real-port,
error→JS-code mapping, BROKEN-PIPE handling. **Gate:** echo server 2,000 sequential + 500 concurrent
connections; `/proc/self/fd` stable (zero leaks); ≥100 MB/s single-connection loopback.

Substrate phase — CL only, no JS surface (that is Phase 17 `Clun.serve`/fetch). `clun.net`,
`src/net/sockets.lisp`, callback-based; Phase 17+ marshals the callbacks to JS.

## 1. Verified sb-bsd-sockets behavior (probed on this host, SBCL 2.6.4)

- Non-blocking connect signals `sb-bsd-sockets:operation-in-progress` (EINPROGRESS).
- Non-blocking `socket-accept`/`socket-receive` return **NIL** on EAGAIN; `socket-receive` returns
  `(values buf 0)` on orderly EOF (peer closed).
- Non-blocking `socket-send` returns a **partial byte count** when the kernel buffer fills (it does NOT
  signal EWOULDBLOCK) — so a large write drains over several writable events. `:nosignal t` turns
  write-to-closed-peer into a catchable `socket-error` (no SIGPIPE).
- **Accepted sockets are NOT non-blocking by default** — we set `non-blocking-mode` on each.
- A failed async connect: `socket-peername` signals `not-connected-error`; a subsequent `socket-receive`
  surfaces the real errno (`connection-refused-error` → ECONNREFUSED).
- `socket-name` on a port-0 bind returns the real ephemeral port.
- `socket-send` accepts a **displaced array** (a zero-copy view) — used for partial-send remainders.
- `socket-error` subclasses present: connection-refused / network-unreachable / operation-timeout /
  not-connected / address-in-use / operation-not-permitted / invalid-argument / bad-file-descriptor /
  no-buffers / interrupted (no connection-reset or broken-pipe subclass → the base maps to a default).

`sb-bsd-sockets` was added to the system `:depends-on`.

## 2. The reactor seam (thread rule)

`lp:reactor-add (loop fd direction fn)` registers an fd handler; `lp:reactor-remove` drops it. SBCL
dispatches a serve-event fd handler only for a registration made by the thread that runs serve-event (the
`run-loop` thread) — so all socket setup happens on the loop thread (before `run-loop`, or inside a
handler). Handlers here follow the §3.2 rule loosely: for Phase 16 (no JS) the callback runs directly in
the handler; Phase 17 will enqueue + drain microtasks.

## 3. The `tcp` handle

A struct: `socket fd loop handle state{:connecting/:open/:closed} read-handler write-handler write-queue
queued-bytes backpressured read-buf on-{connect,data,close,error,drain}`. A ref'd loop `handle` keeps the
loop alive while the socket is open (deactivated on close). `%wrap` sets non-blocking + TCP_NODELAY + 4 MB
SO_{SND,RCV}BUF (best-effort; the kernel clamps — this widens throughput margin by cutting reactor
round-trips).

- **Read** (`%on-readable`): drain `socket-receive` into a reusable 256 KB buffer in a loop until NIL
  (EAGAIN) or 0 (EOF→close); each chunk delivered to `on-data` as a fresh `subseq` (the buffer is reused).
- **Write** (`tcp-write`/`%flush`): append `(octets . offset)` chunks to a FIFO; `%flush` sends the head
  with `:nosignal`, advancing the offset on a partial send (via a displaced view — copying the remainder
  would be O(n²) to drain a large write). On a partial send, register the `:output` handler and mark
  `backpressured`; when the queue empties, drop `:output` and — **only if backpressured** — fire `on-drain`
  once (Node's `drain` is an edge, not "queue is empty now"). A zero-length write is a no-op (socket-send
  rejects an empty/wrong-type vector). Any non-socket condition from a send fails the connection cleanly.
- **Close** (`%finish-close`, idempotent): remove both reactor handlers, `socket-close :abort t`,
  deactivate the handle, fire `on-close (tcp code)` exactly once. EOF → code NIL; error → the code string.

## 4. Connect / listen

`tcp-connect`: create socket, `%wrap` (:connecting), `socket-connect`; on `operation-in-progress` register
`:output`; when writable, `%on-connect-writable` promotes to :open (peername succeeds) or surfaces the
failure code (peername signals → a recv reveals ECONNREFUSED etc.) → on-error + close. `tcp-listen`:
SO_REUSEADDR + non-blocking, bind (port 0 ok), listen, register `:input` → `%on-acceptable` accepts every
pending connection (until EAGAIN), wraps each, calls `on-connection (tcp)` (which sets its handlers), then
starts reading. A double-bind raises `socket-open-error` with code EADDRINUSE.

## 5. Error mapping

`socket-error-code` maps the sb-bsd-sockets condition subclass → a JS-visible errno string
(ECONNREFUSED/ENETUNREACH/ETIMEDOUT/ENOTCONN/EADDRINUSE/EPERM/EINVAL/EBADF/ENOBUFS; base → a default).

## 6. Gate + review

`tests/lisp/net/sockets-tests.lisp` runs BOTH the echo server and the clients on ONE loop (the reactor
multiplexes every fd): port-0-real-port, echo roundtrip, 2,000 sequential, 500 concurrent (backlog 1024),
fd-no-leak (fd count returns to baseline after 400 cycles), connect-refused→ECONNREFUSED, and throughput
(64 MB loopback ≥100 MB/s; measured ~115–140). Adversarial review panel (5 dims × verify-by-running-CL):
4/6 confirmed + fixed — a zero-byte `tcp-write` CASE-FAILURE crash (skip empty + broaden the send catch)
and `on-drain` firing spuriously/repeatedly (now edge-triggered on a real backpressure→empty transition).

## 7. Deferrals / notes

Hostnames must be IP literals (DNS is Phase 18); IPv6 is structurally supported (`inet6-socket` +
`make-inet6-address`) but lightly tested; no UDP; unclassified socket errors report a generic code. The
throughput figure is a single-threaded-both-ends test artifact — a real server drives one direction per
thread, so the effective ceiling is higher.
