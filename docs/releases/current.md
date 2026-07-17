<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.23

Phase 58: Operating-system secrets constitutional checkpoint.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 9 Yes / 7 Partial / 14 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->

## Highlights

- Phase 58 records the OS-secrets **constitutional checkpoint**: pure Common Lisp cannot
  deliver Bun-compatible OS keychain storage (macOS Keychain, libsecret, Windows Credential
  Manager) without a purity-contract amendment.
- Ships `Clun.secrets` with Bun-shaped `get` / `set` / `delete` argument validation and
  fail-closed `ERR_SECRETS_NOT_AVAILABLE` for every store operation.
- Ledger row `security.encrypted-secrets` remains **No** (excluded by the purity contract).
  A pure file vault is explicitly not OS-keychain parity and is not claimed.
- Slot map: published base `0.1.0-dev.18`; master tip `0.1.0-dev.21` (Phase 37 m2); transport
  holds unpublished `0.1.0-dev.22`; this candidate allocates `0.1.0-dev.23` under the
  unpublished-intermediate prerelease gap policy.

The release candidate stages an honest constitutional disposition with tested clear errors and
does not promote any matrix row to `Yes` or `Partial`.
