# Phase 53 — S3 client (FULL PORT #185)

## Decision

`cloud.s3` is implemented as a **pure Common Lisp** AWS Signature Version 4
S3-compatible client. Purity means implementation language is CL — not feature
exclusion (epic #177). There is no ledger No for this row.

## Surface (meets Bun.s3; exceeds where noted)

| Operation | Bun | Clun |
|-----------|-----|------|
| Credentials (options + S3_*/AWS_* env) | Yes | Yes |
| Path-style endpoints | Yes (default) | Yes (`pathStyle`) |
| Virtual-hosted style | Yes | Yes |
| `file` / lazy S3File | Yes | Yes |
| get / text / write / delete | Yes | Yes |
| exists / size / stat | Yes | Yes |
| list (ListObjectsV2) | Yes | Yes |
| presign | Yes | Yes |
| multipart upload | Yes | Yes |
| copy | — | **Exceed** |
| batch deleteObjects | — | **Exceed** |
| hermetic mock transport | — | **Exceed** (tests) |

## Implementation

- Package: `clun.s3` (`src/cloud/s3.lisp`)
- JS boundary: `Clun.s3`, `Clun.S3Client` (`src/runtime/clun-s3.lisp`)
- Crypto: Ironclad HMAC-SHA256 + SHA256 + MD5 (Content-MD5)
- Transport: pure-tls HTTPS + plain HTTP; injectable `*s3-http-fn*` for fixtures

## Evidence gates

- Lisp suite: `tests/lisp/cloud/s3-tests.lisp` (SigV4 vectors, hermetic CRUD/list)
- Compat fixture: `tests/compat/cloud.s3/basic.js`
- Four-target platforms: supported via pure-CL portable core

## Non-goals (not soft-outs)

None for the Yes bar: the public API is a full first-party S3-compatible client.
Live operator endpoint smoke is optional and does not gate ledger Yes.
