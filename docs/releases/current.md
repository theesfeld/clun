<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.44

Phase 59: Package registry and dependency-spec breadth.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 16 Yes / 1 Partial / 13 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->
## Highlights

- Issue #131: `package-manager.npm` Partial→**Yes**. Dependency-spec residual closed for the
  install surface: registry packages (semver ranges, dist-tags), `npm:` aliases, `file:`/`link:`
  local packages, and `optionalDependencies` soft-fail with os/cpu filtering.
- Four-target hermetic install receipts (`examples/e2e-install.sh`) are registered; platforms are
  **supported**. Offline reinstall remains byte-identical on `clun.lock`.
- Publishing remains an honest residual outside this Yes claim (Bun matrix Yes is install-class;
  workspaces stay `package-manager.monorepo` No; pure-CL git/SSH remains later Phase 59/61 work).
- Slot map: published base `v0.1.0-dev.21`; master tip `0.1.0-dev.43`; this candidate allocates
  `0.1.0-dev.44` / `v0.1.0-dev.44` (SemVer `minor`). Hosted installer remains on published dev.21.

The release candidate promotes one compatibility matrix row to `Yes` without claiming monorepo,
registry publish, or git dependency protocols.
