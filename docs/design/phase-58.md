# Phase 58 — Operating-system secrets constitutional checkpoint

> **Issue #215 adversarial disposition:** `security.encrypted-secrets` is **Partial**. PR #194 shipped
> a real pure-CL AES-256-GCM file vault with Bun-shaped `get`/`set`/`delete` plus
> `has`/`list`/`clear`, but it did not implement the row's operating-system keychain capability.
> The vault receipts prove that subset on four targets; they do not prove Keychain/libsecret behavior,
> native ACLs and prompts, locked-store semantics, or cross-tool credential interoperability.

Status (historical Phase 58): accepted as **No — constitutional** under the then-active purity-as-exclusion
reading. Productizing the file vault under #179 advances the row from No to **Partial**, not Yes. The
original distinction between a Clun vault and OS-keychain parity remains controlling.

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

1. **Target matrix** — even a complete Secret Service client addresses only Linux, while Phase 58
   `Yes` requires native jobs on Linux/macOS x64/arm64 with OS store behavior. Windows is part of
   Bun's implementation inventory, not Clun's current four-target release gate.
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

**Result: this implementation is useful evidence for a Partial row, but it must not be claimed as
Bun OS-secrets parity or a complete operating-system keychain integration.**

### Spike D — Optional purity amendment

An operator-approved amendment could allow a narrow FFI or subprocess boundary for Keychain /
libsecret / Credential Manager. That path is not taken in this unit. No amendment is recorded.

## Operator decision

| Option | Disposition |
| --- | --- |
| Pure OS keychain on all targets | **Rejected** — Darwin requires a native framework, and Linux-only pure D-Bus fails the four-target gate; Windows is inventory-only |
| Narrow optional-boundary amendment | **Not requested** — purity retained |
| Explicit unsupported (constitutional) | **Accepted** |
| File vault as an implemented subset | **Accepted as Partial only** — must not be labeled OS-keychain parity or Yes |

**Current decision:** retain purity. Ledger row `security.encrypted-secrets` is **`Partial`**: the
file-vault API below is implemented, while OS keychain integration remains an explicit gap and full-port
target. `Clun.secrets`:

1. exposes Bun-shaped `get` / `set` / `delete` (object form and positional form);
2. validates arguments with Bun-shaped `TypeError` + `ERR_INVALID_ARG_TYPE` messages;
3. stores data in the Clun AES-256-GCM file vault and adds `has` / `list` / `clear`.

## Public surface (Clun)

```js
Clun.secrets.get({ service, name }) // or get(service, name)
Clun.secrets.set({ service, name, value, allowUnrestrictedAccess? }) // or set(service, name, value)
Clun.secrets.delete({ service, name }) // or delete(service, name)
```

- `Clun.secrets` is a non-configurable data property on `Clun`.
- Methods return Promises (async shape matches Bun).
- Invalid arguments reject/throw with `ERR_INVALID_ARG_TYPE` before the constitutional code.
- Valid calls perform file-vault operations and settle through Promises.
- `allowUnrestrictedAccess` is accepted but cannot reproduce OS keychain ACL behavior.

## Non-goals

- Implementing Keychain, libsecret, or Credential Manager access
- Shelling out to `security`, `secret-tool`, or similar
- File-encrypted vault marketed as OS keychain parity
- Ledger `Yes` before OS keychain behavior and four-target receipts exist
- Amending the purity contract

## Evidence and gate

| Check | Expectation |
| --- | --- |
| Design + DECISIONS | This document and a DECISIONS.md entry |
| Lisp suite | Argument validation + constitutional disposition |
| `make compat FEATURE=security.encrypted-secrets` | Shipped fixture proves Bun-shaped operations against the Clun file vault only |
| Platforms | All four targets `unverified` for the full OS-keychain capability; subset receipts remain attached |
| `make build` / `make test` / `make purity` / `make docs-check` | Green |
| Ledger claim | **Partial**, with the OS-keychain gap explicit |

## Architecture

- `clun.secrets` — engine-free AES-256-GCM vault, key-file handling, serialization, and operations.
- `clun.runtime` (`clun-secrets.lisp`) — JS coercion, Promise construction, errors, and installation
  onto `Clun`.
- No CFFI, subprocess, Keychain, or libsecret integration.

## SemVer

Public addition of the file-vault-backed `Clun.secrets` surface was backward-compatible API work.
Issue #215 changes only evidence disposition and public claims; its recorded SemVer impact is `none`.
