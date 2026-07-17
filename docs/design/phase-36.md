# Phase 36: Password and hash APIs

## Contract

Phase 36 implements the frozen Bun `c1076ce95e` password and non-cryptographic
hashing surface under the Clun namespace. `Clun.password` exposes `hash`,
`hashSync`, `verify`, and `verifySync`. `Clun.hash` is callable as wyhash and
also exposes `wyhash`, `adler32`, `crc32`, `cityHash32`, `cityHash64`,
`xxHash32`, `xxHash64`, `xxHash3`, `murmur32v2`, `murmur32v3`, `murmur64v2`,
and `rapidhash`.

Password inputs accept strings and binary views. Hash inputs accept strings,
ArrayBuffer, TypedArray, and DataView values. Strings are hashed as their UTF-8
bytes. 32-bit hash functions return Number and 64-bit functions return BigInt.

## Architecture

`clun.password` is engine-free. It owns strict PHC and modular-crypt parsers,
Argon2d/i/id and bcrypt derivation through the vendored Ironclad primitives,
automatic CSPRNG salts owned by the engine-free core, constant-time comparison,
and resource ceilings. Bcrypt passwords longer than 72 bytes use their raw
SHA-512 digest, matching Bun's stable long-password format.

`clun.hash` is engine-free and implements the frozen integer algorithms with
explicit 32- and 64-bit modular arithmetic. It never allocates in proportion
to an attacker-controlled seed and scans input once, except for fixed-size
algorithm tails.

`clun.runtime` performs JS coercion and copies password bytes before dispatch.
Synchronous password calls compute inline. Asynchronous calls create a Promise,
submit work to the fixed event-loop worker pool, and settle back on the realm
loop. Owned password buffers are erased in unwind-protect cleanup paths. Hash
helpers are synchronous and use a borrowed binary view for the duration of the
call.

## Resource policy

- Password and encoded-hash inputs are bounded before parsing or allocation.
- Argon2 generation and verification enforce the public minimums plus explicit
  memory/time ceilings before allocating a work area.
- Argon2 generation uses one lane, exactly as the pinned public API does;
  verification schedules up to 64 encoded PHC lanes sequentially with the
  specification's slice barriers and cross-lane reference indexing.
- Bcrypt costs are validated before exponentiation; malformed MCF/PHC strings
  fail without entering the KDF.
- Async jobs are admitted only through the fixed worker pool, so submissions do
  not create unbounded threads.
- Salt, derived-key, and copied password vectors are overwritten where the
  implementation retains ownership.

## Evidence

The phase gate combines published Argon2/bcrypt vectors, MCF/PHC cross-format
verification, the frozen Bun hash vectors including length-boundary coverage,
binary-view/coercion fixtures, malformed/cost-exhaustion tests, a reactor
progress canary, stress/resource tests, the Phase 19 crypto suite, full Clun
tests, purity, and documentation checks.
