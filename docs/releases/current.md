<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.35

Phase 59: Package registry and dependency-spec breadth.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 11 Yes / 6 Partial / 13 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->
## Highlights

- Issue #131: `package-manager.npm` Partial→**Yes**. Four-target hermetic install and dependency-spec
  residual receipts (`examples/e2e-install.sh`, `examples/e2e-depspec.sh`); platforms **supported**.
- Dependency-spec residual closed pure-CL: optionalDependencies soft-fail, `file:` local directory
  packages, registry semver ranges / dist-tags / scoped names, offline lock reinstall, SRI-verified
  tarballs. Pinned public npm smoke (`make smoke-npm`, is-number@7.0.0) over verified pure-CL TLS.
- Publishing is **not** required for Yes vs Bun (`bun install`); workspaces remain separate
  `package-manager.monorepo` **No**; git/SSH and registry publish stay Phase 59/61 follow-ons.
- Slot map: published base `v0.1.0-dev.21`; master tip `0.1.0-dev.33` (shell Yes #120); this candidate
  allocates free `0.1.0-dev.35` / `v0.1.0-dev.35` (SemVer `minor`). Hosted installer remains on
  published dev.21 until a later unit publishes.

The release candidate promotes `package-manager.npm` to matrix **Yes** with four-target supported receipts.
