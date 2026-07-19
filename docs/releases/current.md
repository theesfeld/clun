<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.62

Phase 47: Node compatibility certification.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 27 Yes / 1 Partial / 2 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->
## Highlights

- Issue #191 promotes `runtime.node-compatibility` Partial→**Yes** with pure-CL Bun-comparable `node:` matrix (54 builtins) exceeding Bun (sqlite, module.register, repl).
- Issue #189 promotes `tooling.frontend-dev-server` No→**Yes** (pure-CL HTML entry + HMR).
- Issue #180 promotes `tooling.bundler` No→**Yes** (`Clun.build` pure-CL).
- Issue #187 promotes `runtime.loader-plugins` No→**Yes** (pure-CL `Clun.plugin` exceeding `Bun.plugin`).
- Slot: free `0.1.0-dev.57` after master frontend-dev Yes `0.1.0-dev.56`.
