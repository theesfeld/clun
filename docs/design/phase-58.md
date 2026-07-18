# Phase 58 — Operating-system secrets constitutional checkpoint

Status: accepted as **No — constitutional**. OS keychain parity is not delivered under the purity
contract. `Clun.secrets` exists, validates Bun-shaped arguments, and fails closed with a tested
clear error. This phase does **not** promote `security.encrypted-secrets` to `Yes` or `Partial`.

## Objective

Decide whether Bun-compatible OS credential storage (`Bun.secrets` / `Clun.secrets`) can be
delivered on all supported targets without native foreign calls or shell-command substitution.
Record an operator decision with cited spikes. A positive path would require four-target OS store
parity; otherwise the ledger remains explicit non-parity with a tested clear error.

## Provenance (inventory)

| Role | Revision | Paths |
| --- | --- | --- |
| Public baseline | Bun 1.3.14, `0d9b296af33f2b851fcbf4df3e9ec89751734ba4` | `docs/runtime/secrets.mdx`, `packages/bun-types/bun.d.ts`, `test/js/bun/secrets*.ts` |
| Engineering inventory | Bun 1.4.0-dev, `c1076ce95effb909bfe9f596919b5dba5567d550` | same docs/types/tests plus `src/jsc/bindings/Secrets{Darwin,Linux,Windows}.cpp`, `JSSecrets.cpp`, `JSSecrets.rs` |
| Clun ledger | `security.encrypted-secrets` | primary owner Phase 58 |

### Bun surface (frozen)

```js
// Object or positional overloads
await secrets.get({ service, name })           // Promise<string | null>
await secrets.set({ service, name, value, allowUnrestrictedAccess? })
await secrets.delete({ service, name })        // Promise<boolean>
```

Argument validation (synchronous before threadpool work):

- options must be an object (object form), or positional strings;
- `service` and `name` must be non-empty strings → `ERR_INVALID_ARG_TYPE`;
- `set` requires string `value` → `ERR_INVALID_ARG_TYPE` (empty string means delete in Bun).

Platform backends (Bun implementation, not Clun):

| Target | Mechanism | Native boundary |
| --- | --- | --- |
| macOS | Keychain Services (`Security.framework`) | C API / FFI |
| Linux | libsecret → Secret Service (GNOME Keyring, KWallet, …) | `dlopen` + GLib/libsecret |
| Windows | Credential Manager | Win32 API |

Error codes used by Bun include `ERR_SECRETS_NOT_AVAILABLE`, `ERR_SECRETS_NOT_FOUND`,
`ERR_SECRETS_ACCESS_DENIED`, `ERR_SECRETS_PLATFORM_ERROR`, interaction/auth/cancel variants, and
`ERR_INVALID_ARG_TYPE` for argument shape.

## Spike results

### Spike A — macOS Keychain pure protocol

Keychain Services are a proprietary C framework. There is no documented pure user-space protocol
that stores items into the same per-user keychain without `Security.framework` (or shelling out to
`security(1)`, which is also forbidden). **Result: pure-CL OS keychain parity on Darwin is
impossible under the current purity contract.**

### Spike B — Linux Secret Service over pure D-Bus

Secret Service is a D-Bus API. A pure Common Lisp D-Bus client over Unix domain sockets is
theoretically possible without CFFI. Barriers to ledger `Yes`:

1. **Target matrix** — even a complete Secret Service client does not help Darwin or Windows, and
   Phase 58 `Yes` requires native jobs on Linux/macOS x64/arm64 with OS store behavior.
2. **Session reality** — CI and headless hosts often lack a session bus or unlocked collection;
   Bun already surfaces `libsecret not available` / platform errors. Hermetic locked/unlocked
   fixtures need a real agent, not a file.
3. **Schema and ACL parity** — Bun uses libsecret schemas, search flags, unlock, and collection
   creation. Reimplementing that surface is a multi-milestone product, not a checkpoint stub.
4. **Constitutional line** — a pure D-Bus client is not an OS-keychain amendment by itself, but
   claiming `security.encrypted-secrets` `Yes` without Darwin/Windows (or with a fake store) would
   relabel non-parity.

**Result: pure D-Bus is research-interesting for a future optional Linux-only experiment; it does
not clear Phase 58 `Yes` under the four-target gate.**

### Spike C — Encrypted Clun file vault

A pure-CL file encrypted with Ironclad (e.g. under `~/.config/clun/secrets`) can store credentials
without FFI. It is **not** OS keychain integration: different ACL model, no system UI prompts, no
sharing with other tools' keychain entries, different threat model. PLAN requires distinguishing an
encrypted Clun file from OS-keychain parity and never relabeling it.

**Result: out of scope for `security.encrypted-secrets`. If ever productized, it must be a separate
capability ID and must not be claimed as Bun OS-secrets parity.**

### Spike D — Optional purity amendment

An operator-approved amendment could allow a narrow FFI or subprocess boundary for Keychain /
libsecret / Credential Manager. That path is not taken in this unit. No amendment is recorded.

## Operator decision

| Option | Disposition |
| --- | --- |
| Pure OS keychain on all targets | **Rejected** — Darwin/Windows require native frameworks; Linux-only pure D-Bus fails the four-target gate |
| Narrow optional-boundary amendment | **Not requested** — purity retained |
| Explicit unsupported (constitutional) | **Accepted** |
| File vault labeled as OS secrets | **Rejected** — would falsify the ledger |

**Decision:** retain purity. Ledger row `security.encrypted-secrets` remains **`No`** with detail
that OS keychain integration is excluded by the purity contract (constitutional). Ship
`Clun.secrets` that:

1. exposes Bun-shaped `get` / `set` / `delete` (object form and positional form);
2. validates arguments with Bun-shaped `TypeError` + `ERR_INVALID_ARG_TYPE` messages;
3. rejects every store operation with `Error` + `ERR_SECRETS_NOT_AVAILABLE` and a message that
   names the purity / constitutional checkpoint (not a fake empty store).

## Public surface (Clun)

```js
Clun.secrets.get({ service, name }) // or get(service, name)
Clun.secrets.set({ service, name, value, allowUnrestrictedAccess? }) // or set(service, name, value)
Clun.secrets.delete({ service, name }) // or delete(service, name)
```

- `Clun.secrets` is a non-configurable data property on `Clun`.
- Methods return Promises (async shape matches Bun).
- Invalid arguments reject/throw with `ERR_INVALID_ARG_TYPE` before the constitutional code.
- Valid calls settle as rejected Promises (async methods) with `ERR_SECRETS_NOT_AVAILABLE`.
- `allowUnrestrictedAccess` is accepted and ignored for validation parity; it never enables a store.

## Non-goals

- Implementing Keychain, libsecret, or Credential Manager access
- Shelling out to `security`, `secret-tool`, or similar
- File-encrypted vault marketed as OS secrets
- Ledger `Yes` or `Partial` for `security.encrypted-secrets`
- Amending the purity contract

## Evidence and gate

| Check | Expectation |
| --- | --- |
| Design + DECISIONS | This document and a DECISIONS.md entry |
| Lisp suite | Argument validation + constitutional disposition |
| `make compat FEATURE=security.encrypted-secrets` | Shipped fixture proves API presence and fail-closed errors (PLAN shorthand `os-secrets`) |
| Platforms | All four targets `unsupported` with constitutional note |
| `make build` / `make test` / `make purity` / `make docs-check` | Green |
| Ledger claim | Stays **No** (not Yes, not Partial) |

## Architecture

- `clun.secrets` — engine-free disposition constants, message text, and pure argument checks used by
  tests without a realm.
- `clun.runtime` (`clun-secrets.lisp`) — JS coercion, Promise construction, error objects with
  `code`, install onto `Clun`.
- No CFFI, no subprocess, no on-disk secret store.

## SemVer

Public addition of `Clun.secrets` is backward-compatible API surface → prerelease **minor** advance
on the active `0.1.0-dev.N` train. Compatibility matrix counts stay **9 Yes / 7 Partial / 14 No**
(no promotion of this row).
