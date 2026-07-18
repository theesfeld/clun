# Phase 51 — WebSocket and Pub/Sub (constitutional checkpoint)

Status: **design + fail-closed skeleton**. Full protocol implementation is not in this unit.
Ledger row `server.websocket` is **`Partial`** after M1 (handshake + framing + echo). Full **`Yes`** still waits for Autobahn-style and Bun-differential gates
with four-target receipts.

Canonical live SoT: [issue #25](https://github.com/theesfeld/clun/issues/25).

## 1. Objective of this checkpoint

Answer, with evidence-shaped design rather than vapor:

1. Is a **pure Common Lisp** WebSocket client/server + Bun-shaped Pub/Sub path feasible under the
   purity contract (§1.1) without CFFI, OpenSSL, libuv, or uWebSockets?
2. If yes, what is the architecture, milestone split, and purity risk register?
3. Until implementation lands, how does `Clun.serve` fail **closed** with a clear, tested error?

This unit does **not** claim `Yes`, does **not** run `make compat FEATURE=websocket-pubsub`, and does
**not** advertise WebSocket capability in README/site beyond the existing honest `No` row.

## 2. Bun surface inventory (pinned baselines)

| Role | Revision | Paths |
| --- | --- | --- |
| Public baseline | Bun 1.3.14, `0d9b296af33f2b851fcbf4df3e9ec89751734ba4` | `docs/runtime/http/websockets.mdx`, `packages/bun-types/serve.d.ts`, `test/js/bun/websocket/` |
| Engineering inventory | Bun 1.4.0-dev, `c1076ce95effb909bfe9f596919b5dba5567d550` | same docs/types/tests; server stack historically uWebSockets-derived; client under `src/http/websocket*` |

### 2.1 Public `Bun.serve` WebSocket contract (stable shape)

```js
Bun.serve({
  fetch(req, server) {
    if (server.upgrade(req, { data, headers })) return;
    return new Response("Upgrade failed", { status: 500 });
  },
  websocket: {
    message(ws, message) {},
    open(ws) {},
    close(ws, code, reason) {},
    drain(ws) {},
    // optional: ping, pong, error
    // limits: maxPayloadLength, backpressureLimit, closeOnBackpressureLimit,
    //         idleTimeout, publishToSelf, sendPings, perMessageDeflate
  },
});
```

Server object methods (beyond ordinary HTTP serve):

| Method | Bun behavior |
| --- | --- |
| `server.upgrade(req, opts?)` | HTTP → WebSocket; returns `boolean` |
| `server.publish(topic, data, compress?)` | fan-out to topic subscribers |
| `server.subscriberCount(topic)` | integer subscriber count |

`ServerWebSocket` surface (abbreviated): `send` / `sendText` / `sendBinary`, `close`, `ping` /
`pong`, `publish` / `publishText` / `publishBinary`, `subscribe` / `unsubscribe` / `isSubscribed` /
`subscriptions`, `cork`, `data`, `readyState`, `remoteAddress`, `binaryType`.

Client: browser-shaped `WebSocket` global (CONNECTING/OPEN/CLOSING/CLOSED), plus Bun extensions as
documented at the pin. Clun has no DOM `EventTarget` full surface today; client delivery must map to
existing event/callback patterns without inventing a second event system.

### 2.2 Protocol obligations (RFC 6455 + extensions)

- Opening handshake: HTTP/1.1 `Upgrade: websocket`, `Connection: Upgrade`,
  `Sec-WebSocket-Key` / `Sec-WebSocket-Accept` (SHA-1 + GUID, base64), optional subprotocol and
  extension negotiation.
- Framing: FIN/RSV/opcode, masking (client→server mandatory), payload length 7/16/64-bit,
  continuation, close/ping/pong control frames, fragmentation rules.
- Close handshake and error states; idle timeout / automatic pings when configured.
- Optional **permessage-deflate** (RFC 7692) negotiation and bounded inflate/deflate.
- Pub/Sub: topic membership tables, server-wide publish without running JS on the I/O path,
  backpressure and cork batching, subscriber cleanup on close.
- Bounds: max frame/message size, compression expansion caps, queue depths, connection caps
  (compose with existing `*serve-max-connections*` shedding).

## 3. Constitutional feasibility decision

### 3.1 Verdict

**Pure-CL path: FEASIBLE. Not a constitutional block.**

RFC 6455 and Bun-shaped Pub/Sub are ordinary octet protocols and in-memory data structures over
sockets Clun already owns. Nothing in the WebSocket feature requires CFFI, native crypto libraries,
or uWebSockets. The ledger stays `No` for **missing implementation and evidence**, not for purity
prohibition (contrast `runtime.native-addons` / Phase 48).

### 3.2 Substrate already present

| Need | Existing Clun asset |
| --- | --- |
| Non-blocking TCP + reactor | `clun.net` sockets (`src/net/sockets.lisp`), Phase 05/16 loop |
| HTTP/1.1 request parse + response write | `http-parser`, `clun-serve` |
| SHA-1 / digests for accept key | Ironclad (approved pure-CL crypto) |
| Base64 for accept key | Existing install/runtime usage (`cl-base64` where already approved) |
| Deflate/inflate for optional compression | Chipz (already used for gzip/deflate on HTTP client and tarballs) |
| TLS for `wss:` client / HTTPS upgrade later | pure-tls path (Phase 19/20); server TLS remains a separate serve milestone |
| JS handler dispatch / promises | Engine + existing async serve path |

### 3.3 Purity risks (not blockers — mitigate in milestones)

| Risk | Severity | Mitigation |
| --- | --- | --- |
| Temptation to vendor/link uWebSockets or Node `ws` native bits | Critical if done | Forbidden by purity scan; Autobahn fixtures stay tests only |
| Unbounded permessage-deflate expansion (compression bomb) | High | Hard inflate caps (same discipline as tarball gzip cap); reject on exceed |
| Unbounded fragmented message reassembly | High | `maxPayloadLength` default (Bun: 16 MiB) + per-connection queue bounds |
| SHA-1 for accept key | Low (protocol-mandated) | Ironclad SHA-1 only for handshake accept; not a new crypto product |
| Chipz inflate as “zlib” | Low | Chipz is pure CL already in the tree; no system zlib |
| Client `WebSocket` vs missing full `EventTarget` | Medium | Map to minimal event slots / callbacks; do not fake DOM parity |
| Running JS inside raw I/O callbacks for publish | Medium | Mirror Bun: topic fan-out on CL side; schedule handler jobs on the JS loop |
| Proxy/redirect/`wss` client complexity | Medium | Milestone after cleartext server framing is solid |
| Performance claims vs Bun/uWS | High (docs) | No throughput claims without same-host reproducible benches |

### 3.4 Explicit non-goals of the full phase (and of this checkpoint)

- No CFFI exception request.
- No partial “works on my machine” Yes.
- No HMR protocol (Phase 67 ownership).
- No HTTP/2 WebSocket bootstrap.
- No Windows (project non-goal until an Issue says otherwise).

## 4. Architecture (target implementation)

```
                    ┌─────────────────────────────────────┐
  TCP accept ──────►│ clun-serve connection reader        │
                    │  HTTP parse ──► fetch / routes      │
                    │       │                             │
                    │       └─ server.upgrade ──► handshake│
                    └──────────────┬──────────────────────┘
                                   │ protocol switch
                                   ▼
                    ┌─────────────────────────────────────┐
                    │ clun.websocket framing I/O          │
                    │  mask/unmask · control frames       │
                    │  fragment reassembly (bounded)      │
                    │  optional permessage-deflate        │
                    └──────────────┬──────────────────────┘
                                   │ schedule on JS loop
                                   ▼
                    ┌─────────────────────────────────────┐
                    │ WebSocketHandler (open/message/…)   │
                    │ ServerWebSocket brand + per-socket  │
                    │ data · cork · readyState            │
                    └──────────────┬──────────────────────┘
                                   │
                    ┌──────────────▼──────────────────────┐
                    │ Topic hub (publish / subscribe)     │
                    │  subscriberCount · cleanup on close │
                    └─────────────────────────────────────┘
```

**Package split (scaffold now, fill later):**

| Package / file | Role |
| --- | --- |
| `clun.websocket` (`src/net/websocket.lisp`) | Frame types, opcodes, bounds constants, `websocket-unsupported` condition, pure protocol helpers |
| `clun.runtime` (`clun-serve.lisp`) | Options validation, `upgrade` / `publish` / `subscriberCount`, handler install |
| Future: `src/net/websocket-client.lisp` | Client dialer + `WebSocket` global install |
| Future: tests under `tests/lisp/net/` + `tests/compat/server.websocket/` | Autobahn-style + Bun differential corpus |

## 5. Milestone plan

### M0 — Constitutional checkpoint (this unit)

- Design document accepted on issue #25.
- Pure-CL feasibility recorded (not a purity No).
- Package/types scaffold + fail-closed `Clun.serve` errors with tests.
- Ledger remains `No` with improved detail pointing at this design.
- SemVer: **none** (no public capability claim; no version bump).

### M1 — Server handshake + unmasked/masked framing

- [x] Detect upgrade requests; compute `Sec-WebSocket-Accept`; 101 response.
- [x] Parse/write frames; ping/pong/close; basic `message` / `open` / `close` handlers.
- [ ] Resource tests: 10k connect/message/close without handle leaks (local gate; residual).

### M2 — ServerWebSocket API + backpressure

- Full send API, cork, readyState, binaryType, per-socket `data`.
- Backpressure limits, drain callbacks, idle timeout / sendPings.

### M3 — Pub/Sub

- [x] subscribe/unsubscribe/isSubscribed/subscriptions.
- [x] `ws.publish` and `server.publish` / `subscriberCount`.
- 10k-subscriber stress and cleanup proofs.

### M4 — Compression + client + TLS/`wss`

- permessage-deflate with expansion bounds; compression-bomb adversaries.
- Client `WebSocket` + AbortSignal; proxy/redirect policy as pinned.
- Compose with existing TLS client; server TLS when serve TLS lands.

### M5 — Evidence and ledger Yes

- Pin and inventory Bun websocket tests; Autobahn-style fixtures.
- `make compat FEATURE=websocket-pubsub` (or final feature id) on four targets.
- Adversarial review; only then flip `server.websocket` → `Yes`.

Each milestone after M0 is its own Issue branch/PR train if scope demands; M0 does not authorize
capability claims.

## 6. Fail-closed contract (shipped in M0)

Until M1 (superseded once M1 lands):

1. `Clun.serve({ websocket: … })` and `server.reload({ websocket: … })` throw a **TypeError** whose
   message states that WebSocket support is not implemented (Phase 51) and that a pure-CL path is
   designed (`docs/design/phase-51.md`).
2. Every `Clun.serve` server object exposes:
   - `upgrade` → throws the same class of clear not-implemented error (never silently upgrades);
   - `publish` → same;
   - `subscriberCount` → same.
3. Ordinary HTTP `fetch` / `routes` servers without a `websocket` option continue to work.
4. No global `WebSocket` constructor is installed in this unit (client remains absent, not a silent
   half-shim).

## 7. Acceptance for M0 only

- [x] Design answers pure-CL feasibility with purity risk register and milestone plan.
- [x] Scaffold package/types compile under `make build`.
- [x] Fail-closed serve errors covered by Lisp tests.
- [x] `make purity` clean.
- [x] Ledger still `No`; detail references design + fail-closed stubs.
- [ ] Issue #25 updated with decision evidence; PR `Refs #25`.

Full phase gate from `PLAN.md` applies only when M5 is claimed.

## 8. SemVer disposition (this unit)

| Field | Value |
| --- | --- |
| Impact | **none** |
| Rationale | Design notebook + internal scaffold + fail-closed refusal of an unimplemented feature. No new supported public capability; no version or release claim change. |
| Version bump | none (leave `src/version.lisp` on the current train head) |

## 9. Decision summary

| Question | Answer |
| --- | --- |
| Constitutional block? | **No** |
| Pure-CL without CFFI? | **Yes** (RFC 6455 + chipz deflate + ironclad SHA-1 + existing reactor sockets) |
| Ledger after M0? | **`No`** (implementation and four-target evidence still required) |
| User-visible M0 behavior? | Explicit errors when WebSocket options/APIs are used; HTTP serve unchanged |
