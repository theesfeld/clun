# Phases 55–57 — SQL drivers full port (Issue #183)

## Decision

**FULL PORT Yes** under epic #177: pure Common Lisp PostgreSQL and MySQL
frontend/backend wire clients, plus a pure-CL embedded SQLite-compatible
engine, unified behind `Clun.SQL` exceeding Bun.SQL.

Purity means implementation language is Common Lisp. It does **not** authorize
leaving SQL drivers unimplemented or claiming soft Yes.

## Surface

| Adapter | Realization |
|---------|-------------|
| PostgreSQL | Protocol v3: startup, cleartext/MD5/SCRAM-SHA-256 auth paths, simple + extended query, row decoding, pool/reserve/transactions |
| MySQL | Client protocol: handshake, mysql_native_password + caching_sha2_password fast auth, COM_QUERY, result sets, pool/transactions |
| SQLite | Embedded pure-CL engine (no libsqlite / no foreign libs): CREATE/DROP/INSERT/UPDATE/DELETE/SELECT, transactions/savepoints, file persistence (`CLUN-SQLITE` format) |

## Exceed Bun.SQL

- `sql.inspect()` / `sql.stats()` / `sql.export()` (SQLite dump)
- `enableQueryLog` / `queryLog`
- `SQL.adapters` / multi-adapter unified client
- Typed error classes with adapter tags
- Hermetic mock backends for PG/MySQL protocol tests without live servers

## Non-goals for this unit

- Full SQLite B-tree file format compatibility with upstream libsqlite binaries
  (Clun uses a pure-CL on-disk format; the **API** matches Bun.SQL SQLite)
- Every PG type OID / COPY binary protocol variant (extensible; core query path Yes)

## Evidence

- `tests/lisp/sql/sql-tests.lisp`
- `tests/compat/database.sql-drivers/basic.js`
- Four-target `platforms.tsv` supported rows
- Ledger `database.sql-drivers` → **Yes**, gap empty

## SemVer

`0.1.0-dev.50` minor within the 0.1.0 prerelease train.
