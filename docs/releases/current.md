<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.34

Phase 76: Cron, scheduling, and interactive REPL.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 10 Yes / 7 Partial / 13 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->
## Highlights

- Issue #136 (parent #50): pure-CL **`Clun.cron`** in-process scheduling and
  expression parse/next-occurrence (UTC), with Bun-shaped `stop` / `ref` / `unref`,
  no-overlap re-arm after callback settlement, nicknames, named months/weekdays,
  and DOM/DOW OR semantics.
- OS-level `Clun.cron(path, schedule, title)` and `Clun.cron.remove(title)` fail
  closed (pure-CL cannot drive crontab / launchd / Task Scheduler).
- Fixtures: `tests/compat/tooling.cron/basic.js`, `tests/lisp/runtime/cron-tests.lisp`.
- Beyond the fixed 30-row homepage matrix (cron is a Phase 76 beyond-matrix surface).
  REPL remains open on parent Phase 76 / #50.
- Slot map: published base `v0.1.0-dev.21`; master tip `0.1.0-dev.33` (#126); this
  candidate allocates free `0.1.0-dev.34` / `v0.1.0-dev.34` (SemVer `minor`). Hosted
  installer remains on published dev.21 until a later unit publishes.

The release candidate ships the pure-CL cron surface without inventing a 31st matrix
row; public claims stay honest about OS-level unsupported paths.
