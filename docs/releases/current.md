<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.57

Phase 48: Native-addon constitutional checkpoint and conditional implementation.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 25 Yes / 3 Partial / 2 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->
## Highlights

- Issue #187 promotes `runtime.loader-plugins` No→**Yes** (pure-CL `Clun.plugin` exceeding `Bun.plugin`).
- Issue #185 promotes `cloud.s3` No→**Yes** with pure-CL AWS SigV4 client exceeding Bun.s3 (copy, batch-delete, hermetic mock).
- Issue #183 promotes `database.sql-drivers` No→**Yes**.
- Pure-CL `Clun.SQL`: PostgreSQL + MySQL wire protocols and embedded SQLite engine.
- Exceeds Bun.SQL with inspect/stats/export/queryLog and multi-adapter surface.
- Slot: free `0.1.0-dev.50` after master secrets Yes `0.1.0-dev.49`.
