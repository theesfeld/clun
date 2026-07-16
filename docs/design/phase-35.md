# Phase 35 - CSRF API

Status: accepted after independent security, pinned-compatibility, and architecture/evidence review.

## Objective

Convert `web.csrf` from `No` to an evidence-backed `Yes` by implementing the complete selected
`Clun.CSRF.generate` and `Clun.CSRF.verify` contract in pure Common Lisp. The implementation must
interoperate with the pinned Bun token format, include the engineering-pin session binding, remain bounded
under hostile input, and execute through the shipped `build/clun` binary on all four release targets.

This phase does not create a `Bun` global or a `bun` module alias. The compatibility claim is the CSRF
contract exposed on Clun's existing namespace.

## Provenance

| Role | Revision | Paths |
| --- | --- | --- |
| Public baseline | Bun 1.3.14, `0d9b296af33f2b851fcbf4df3e9ec89751734ba4` | `docs/runtime/csrf.mdx`, `packages/bun-types/bun.d.ts`, `src/csrf/csrf.zig`, `src/runtime/api/csrf_jsc.zig`, `test/js/bun/util/csrf.test.ts` |
| Engineering inventory | Bun 1.4.0-dev, `c1076ce95effb909bfe9f596919b5dba5567d550` | `docs/runtime/csrf.mdx`, `packages/bun-types/bun.d.ts`, `src/csrf/lib.rs`, `src/runtime/api/csrf_jsc.rs`, `test/js/bun/util/csrf.test.ts` |
| Stable executable | Bun `1.3.14+0d9b296af` | linux-x64-baseline asset SHA-256 `a063908ae08b7852ca10939bbdc6ceed3ddabce8fb9402dce83d65d73b36e6c7` |
| Session compatibility | Bun PR 31215, merge `5d1d351e` | unbound tokens remain byte-for-byte compatible |
| SHA-512/256 | FIPS 180-4 and NIST CAVP | distinct IV, 128-byte block, 32-byte digest |
| HMAC SHA-512/256 | C2SP Wycheproof `fc24cd5b787d8e496bff31b0468af693a652b0f2` | full-length positive and wrong-digest negative vectors |

Stable executable observations authorize the public baseline. Engineering behavior is source-pinned.
Observations from later Bun canaries may corroborate the engineering reading but do not replace either pin.

## Public Surface

```js
Clun.CSRF.generate(secret?, options?) // string, function length 1
Clun.CSRF.verify(token, options?)      // boolean, function length 1
```

There is no options-first overload.

- `Clun.CSRF` is an ordinary object.
- `Object.keys(Clun.CSRF)` is exactly `["generate", "verify"]` in that order.
- The `CSRF` namespace property is writable and enumerable, but non-configurable.
- Both methods are writable, enumerable, and configurable.
- Method names are `generate` and `verify`; both report `length === 1`.
- Detached calls work because neither method depends on its receiver.
- Neither method is constructible.

`generate()` uses the runtime's default secret. Passing an explicit first argument of `undefined` or
`null` is not the same as omitting the argument and throws. Because no options-first overload exists,
the default secret is available only with default generation options.

`verify` requires the token argument. Its options object may supply `secret`; an absent, `undefined`, or
`null` secret selects the runtime default.

## Observable Property Order

Primitive second arguments are ignored. Object and inherited getters are observable and must be read once
in this order:

- generate: `expiresIn`, `sessionId`, `encoding`, `algorithm`
- verify: `secret`, `sessionId`, `maxAge`, `encoding`, `algorithm`

An abrupt getter completion propagates immediately and prevents later reads, randomness, clock access, HMAC,
or output allocation. Each value is validated immediately after its getter returns, so an invalid earlier
value also prevents later getters and work. The generate secret is validated before options; the verify token
is validated before options.

Option values have this exact boundary:

| Property | Absent | `undefined` | `null` | Accepted | Rejected |
| --- | --- | --- | --- | --- | --- |
| `expiresIn` | `86400000` | `86400000` | TypeError | finite nonnegative safe-integer Number; `-0` becomes `0` | every other value |
| `maxAge` | `86400000` | `86400000` | TypeError | finite nonnegative safe-integer Number; `-0` becomes `0` | every other value |
| verify `secret` | runtime default | runtime default | runtime default | nonempty string | empty or non-string |
| `sessionId` | unbound | unbound | unbound | nonempty string | empty or non-string |
| `encoding` | `base64url` | `base64url` | invalid format | value whose `ToString` result is a supported name; empty selects default | Symbol, abrupt coercion, or unknown nonempty result |
| `algorithm` | `sha256` | `sha256` | TypeError | a listed nonempty string | non-string, empty, or unknown name |

BigInt, Boolean, Symbol, string, and object numeric values are rejected rather than coerced. Fractions,
negatives, NaN, infinities, and values above `Number.MAX_SAFE_INTEGER` are rejected; `-0` is accepted and
stored as zero. Encoding alone applies ordinary JavaScript `ToString`, so a coercible object may select an
encoding and its original abrupt completion propagates. A throwing getter's original exception is preserved.
These rules are fixtures, not implementation latitude.

## Token Format

The interoperable wire payload is fixed:

```text
timestamp milliseconds, unsigned 64-bit big-endian   8 bytes
nonce, cryptographically secure random              16 bytes
expiresIn milliseconds, unsigned 64-bit big-endian  8 bytes
HMAC                                                 32, 48, or 64 bytes
```

The raw token is therefore 64, 80, or 96 bytes. It serializes no version byte, algorithm, encoding, secret,
or session identifier. Adding a prefix would break existing Bun tokens, so this format is treated as
implicit wire version 0. A future incompatible representation requires an explicit new opt-in API; it must
not silently change version 0 generation or verification.

For an unbound token, HMAC input is the 32-byte payload. When `sessionId` is present, HMAC input is:

```text
payload || replacement-mode UTF-8(sessionId)
```

The session identifier is never serialized. Omitting it while verifying a bound token, supplying a different
one, or supplying one for an unbound token fails authentication.

## Algorithms

Algorithm names are ASCII case-insensitive. Canonical names and accepted aliases are:

| Digest | Names | HMAC bytes |
| --- | --- | ---: |
| SHA-256 | `sha256`, `sha-256` | 32 |
| SHA-384 | `sha384`, `sha-384` | 48 |
| SHA-512 | `sha512`, `sha-512` | 64 |
| SHA-512/256 | `sha512-256`, `sha-512/256`, `sha-512_256`, `sha-512256` | 32 |
| BLAKE2b-256 | `blake2b256` | 32 |
| BLAKE2b-512 | `blake2b512` | 64 |

The default is SHA-256. Unknown names throw `TypeError("Algorithm not supported")`. Non-string values use
the exact invalid-argument-type error in the frozen table below.

Vendored Ironclad already supplies every listed HMAC except SHA-512/256. Phase 35 adds SHA-512/256 to
Ironclad's existing SHA-512 module with the FIPS-defined IV, four output registers, 32-byte digest length,
and 128-byte HMAC block length. It is not ordinary SHA-512 truncated to 32 bytes.

The Ironclad patch must include:

- exported `sha512/256` digest registration;
- specialized construction, reset, copy, and finalization;
- NIST empty and one-byte digest vectors;
- a full-length Wycheproof HMAC vector whose 65-byte key detects the wrong block size;
- a negative control proving the result differs from the first 32 bytes of ordinary HMAC-SHA-512 for the
  identical key and message;
- unchanged BSD-3-Clause attribution and Ironclad's own generated test-vector coverage.

## Encoding And Bounded Decoding

Generation supports case-insensitive `base64`, `base64url`, and `hex`. Empty encoding selects the default
`base64url`. Generated output is canonical:

| Raw bytes | Base64 | Base64url | Hex |
| ---: | ---: | ---: | ---: |
| 64 | 88 | 86 | 128 |
| 80 | 108 | 107 | 160 |
| 96 | 128 | 128 | 192 |

Verification retains canonical Bun interoperability without allowing unbounded work:

- every base64-family input whose raw JavaScript-string length exceeds 256 code units is rejected from an
  O(1) length check before stripping, trimming, scanning, or allocation;
- after that precheck, every format strips exactly one NUL only when it is the raw final code unit;
- hex then accepts either case, requires an even length, rejects whitespace and invalid characters, and is
  rejected before decoding above 192 remaining characters;
- base64 and base64url share one decoder and accept either alphabet. After the one terminal-NUL step, they
  trim endpoint CR, LF, TAB, space, and VT without stripping another NUL;
- the resulting spelling is rejected above 128 code units. ASCII letters, digits, `+`, `/`, `-`, and `_`
  contribute sextets; `=` and other ASCII junk are ignored; any non-ASCII code unit rejects. Mixed alphabets
  are accepted. One remaining sextet rejects; two or three produce one or two final bytes. Repeated NULs and
  whitespace after the stripped terminal NUL are therefore governed by those exact steps, not by another
  normalization pass;
- decoding stops and rejects before producing more than 96 bytes;
- after decoding, the raw length must exactly equal `32 + selected digest length`;
- every malformed nonempty token returns `false` rather than exposing a parser oracle.

Generation remains canonical. Bun's 96-byte decoded-output buffer already imposes the same effective
128-ASCII-character normalized ceiling. Clun's additional 256-code-unit raw pre-cap and non-ASCII rejection
intentionally reject some junk-heavy spellings that Bun accepts; these are documented resource-bound security
improvements, not a claim that every noncanonical spelling is shared. Accepted permissive spellings are
textually malleable but do not bypass authentication because verification compares the MAC over decoded bytes.

## Text Encoding And Size Limits

Bun replaces lone UTF-16 surrogates with U+FFFD before HMAC. Clun's existing `code-units->utf8` intentionally
emits WTF-8 and is not used for CSRF inputs. Phase 35 adds a replacement-mode UTF-8 helper and covers BMP,
astral, embedded NUL, and lone-surrogate strings.

The stable Bun surface has no secret or session cap, but the Phase 35 contract requires bounded hostile
inputs. Clun permits at most 1,048,576 UTF-16 code units and at most 1,048,576 replacement-mode UTF-8 bytes
for each secret or session identifier. Larger values throw `RangeError` before HMAC. These limits are
documented security bounds, not silent truncation.

Secrets and session identifiers must be nonempty strings when explicitly supplied. The implementation does
not claim guaranteed secret erasure because Common Lisp allocation and garbage collection do not provide
that guarantee.

## Time, Randomness, And Numeric Policy

- `timestamp` is current Unix epoch time in integer milliseconds.
- Generation uses exactly 16 bytes from `clun.sys:os-random-bytes`.
- Defaults are `expiresIn = 86400000` and `maxAge = 86400000`.
- `0` disables only the corresponding embedded-expiry or caller-max-age check.
- Expiry uses the pinned strict boundary `now > timestamp + age`.
- Both embedded `expiresIn` and verifier `maxAge` apply.
- Future timestamps verify when the MAC is valid.
- Generation requires the current timestamp to fit unsigned 64-bit and writes the validated JavaScript
  `expiresIn` value without adding them. Like the pinned implementation, generation may create a token whose
  eventual unsigned expiry sum overflows; verification rejects that token.
- Authenticated wire fields retain their full unsigned 64-bit domain. Verification uses exact Common Lisp
  integer arithmetic and rejects only a sum above `2^64 - 1`, not a sum above `Number.MAX_SAFE_INTEGER`.
  Both `timestamp + expiresIn` and `timestamp + maxAge` use this rule.

Phase 35 follows the safer engineering-pin numeric contract: absent or explicit-`undefined` numeric options
retain the default, while `-0` becomes zero. Invalid present numeric values throw `TypeError` with
`ERR_INVALID_ARG_TYPE`. This intentionally rejects
stable 1.3.14's NaN-to-zero quirk and its mixed TypeError/RangeError split; the divergence is recorded as a
security correctness improvement and directly tested.

The engine-free core receives explicit timestamp and nonce values for deterministic Lisp tests. Clock and
random injection are not exposed through JavaScript or production dynamic variables.

## Default Secret Lifetime

Each installed `Clun.CSRF` namespace closes over one lazy default-secret cell. The first default-secret
generation or verification allocates 16 CSPRNG bytes; subsequent calls in that runtime reuse them. Explicit
secrets do not initialize or mutate the cell. Separate runtime/realm installations and separate processes
do not share the secret.

## Authentication And Failure Rules

Verification rejects before comparison unless encoding, selected algorithm, decoded length, and byte layout
are structurally valid. It then computes the full expected MAC and calls `ironclad:constant-time-equal` only
on equal-length byte vectors. Only after successful authentication does it interpret timestamp/expiry fields
and apply unsigned-overflow, embedded-expiry, and caller-max-age decisions. This intentionally reverses the
pinned implementation's expiry-before-HMAC timing as a security improvement while preserving every return
value. There is no early MAC byte comparison.

Public algorithm and encoding selection may determine expected token length before HMAC; that metadata is
caller-selected and is not secret. Authentication failures, wrong secret/session/algorithm, expiry,
tampering, truncation, extension, and malformed nonempty token text return `false`.

## Error Contract

The stable argument boundary is retained:

| Call | Result |
| --- | --- |
| `generate()` | use default secret |
| explicit `generate(undefined)` or `generate(null)` | TypeError, `Secret is required` |
| empty or non-string explicit secret | TypeError, `Secret must be a non-empty string` |
| `verify()` | TypeError, `Missing required token parameter` |
| explicit undefined or null token | TypeError, `Token is required` |
| empty or non-string token | TypeError, `Token must be a non-empty string` |
| non-string verify `secret` | TypeError, `The "secret" property must be of type string, got <typeof>` |
| empty verify `secret` | TypeError, `Secret must be a non-empty string` |
| non-string `sessionId` | TypeError, `The "sessionId" property must be of type string, got <typeof>` |
| unknown algorithm | TypeError, `Algorithm not supported` |
| non-string algorithm | TypeError, `The "algorithm" argument must be of type string. Received <rendered>` |
| invalid encoding | TypeError, `Invalid format: must be 'base64', 'base64url', or 'hex'` |
| encoding coercion throws | preserve the original thrown value |
| empty session ID | TypeError, `sessionId must be a non-empty string` |
| non-number `expiresIn`/`maxAge` | TypeError, `The "<name>" argument must be of type number. Received <rendered>` |
| invalid numeric `expiresIn`/`maxAge` | TypeError, `<name> must be an integer between 0 and 9007199254740991` |
| secret or session over either input cap | RangeError, `<name> exceeds the 1048576 code-unit or byte limit` |

Every generated TypeError in this table exposes `code = "ERR_INVALID_ARG_TYPE"`; preserved user exceptions
are unchanged. Every RangeError exposes `code = "ERR_OUT_OF_RANGE"`. Error objects retain their native names.
Fixtures freeze concrete rendered messages for representative values in addition to method names, codes,
getter order, and thrown kinds before the implementation claim is promoted.

## Security Properties And Limits

- Tokens are bearer values and replayable until both configured age checks allow them; the API does not
  provide one-time-use storage.
- `expiresIn = 0` disables only the embedded-expiry check, and `maxAge = 0` disables only the caller check.
- Future timestamps are accepted after authentication, matching the pinned contract.
- Noncanonical base64 spelling is textually malleable within the stated caps; authentication is over decoded
  bytes, not the spelling.
- The default secret is process/runtime local and intentionally does not survive restart or coordinate across
  processes. Applications that need stable or distributed verification must supply an explicit secret.
- Secret erasure is not guaranteed by the Common Lisp allocator or garbage collector.

## Architecture

1. `clun.asd` declares Ironclad directly instead of relying on the transitive pure-tls dependency.
2. `clun.csrf` is an engine-free package loaded after `clun.sys` and before the JavaScript engine.
3. `src/security/csrf.lisp` owns wire encoding, bounded decoding, HMAC dispatch, timestamp arithmetic, and
   deterministic core generate/verify entry points.
4. `src/sys/platform.lisp` gains an accurately named Unix-millisecond wall-clock primitive. The existing
   monotonic-nanosecond name is not reused for epoch tokens.
5. `src/engine/strings.lisp` owns replacement-mode UTF-8 because it operates on Clun's JavaScript string
   representation.
6. `src/runtime/clun-csrf.lisp` owns JS argument discrimination, property access order, errors, aliases,
   descriptors, default-secret lifetime, and the production clock/CSPRNG boundary.
7. `src/runtime/clun-global.lisp` installs the namespace through a writable, enumerable, non-configurable
   engine descriptor helper.

No implementation JavaScript, CFFI, foreign library, shell-out, duplicated crypto primitive, or
Test262/fixture-specific runtime path is permitted.

## Evidence Plan

### Pure crypto

- NIST SHA-512/256 digest KATs;
- Wycheproof positive and wrong-digest HMAC vectors;
- digest length, block length, copy, reset, and repeated-HMAC tests;
- existing Phase 19 crypto KATs remain green.

### Engine-free core

- six algorithms by three encodings with fixed timestamp and nonce;
- stable Bun timeless vectors and engineering session-bound vectors;
- both expiry limits, zero disablement, exact boundary, future timestamp, and overflow;
- wrong key, algorithm, encoding, session, omitted session, and cross-key rejection;
- bytewise tampering across timestamp, nonce, expiry, and every MAC region;
- truncation, extension, oversized text, malformed hex/base64, and seeded fuzz rejection;
- raw million-code-unit whitespace/junk rejection before scanning, both base64 caps, incomplete sextets,
  mixed alphabets, padding placement, repeated NULs, non-ASCII, and normalization-order fixtures;
- replacement-mode UTF-8 and explicit input caps;
- authenticated `MAX_SAFE`, `2^64 - 1`, sum-overflow, future-timestamp, and zero-disablement
  cases, with authentication observably preceding expiry decisions;
- constant-time comparison path review.

### Runtime and shipped binary

- namespace keys/descriptors, method metadata, detached calls, and non-construction;
- omitted versus explicit undefined/null arguments;
- primitive options and inherited getter order/abrupt completion;
- exact errors and error codes;
- per-runtime lazy default-secret reuse and cross-process isolation;
- executable fixtures under `tests/compat/web.csrf/` through `build/clun`;
- all executable evidence registered for linux-x64, linux-arm64, darwin-x64, and darwin-arm64.

Static crypto/core suites supplement the executable fixtures but cannot authorize the published compatibility
`Yes` without the four shipped-binary receipts. The ledger stages the candidate value before CI so the receipt
jobs exercise the exact claim they are expected to authorize.

## Ledger And Release

The preimplementation candidate remained at 1 Yes / 6 Partial / 23 No. Only the same green unit that passes
the declared contract may promote `web.csrf` to:

```text
Yes: Clun.CSRF generate and verify
```

That promotion produces 2 Yes / 6 Partial / 22 No. README, landing page, release notes, STATE, DECISIONS, the
canonical issue, evidence/reference/platform ledgers, and source version must change together.

This is backward-compatible public functionality. Canonical impact is `minor` in the selected `0.1.0`
prerelease train, targeting `0.1.0-dev.9` / `v0.1.0-dev.9` with ASDF core `0.1.0`.

## Acceptance Gate

```sh
make compat FEATURE=web.csrf
make test-crypto
make build
make test
make purity
make docs-check
```

The exact phase gate additionally requires:

- every selected stable/engineering behavior and documented security improvement represented in fixtures;
- tamper, expiry, max-age, session, cross-key, malformed, oversize, and fuzz cases green;
- constant-time review with no early MAC byte comparison;
- existing installer SemVer and crypto regressions green;
- exact committed-range SemVer transition classified `minor`;
- four native Compatibility receipts agreeing on the candidate, ledger, fixtures, results, and zero failures.
