<!-- clun-generated:release-notes:begin -->
# Clun 0.1.0-dev.38

Phase 75: Data formats, Markdown, and HTMLRewriter.

- SemVer impact: `minor` within the selected `0.1.0` prerelease train.
- Compatibility snapshot: 12 Yes / 5 Partial / 13 No across 30 generated rows.
- Public baseline: Bun 1.3.14; engineering baseline: Bun `c1076ce95e`.
- Target release platforms: Linux and macOS, x64 and arm64.
- License: `GPL-3.0-or-later`.

The canonical evidence and current limitations are in `compat/`; `make compat-validate` and `make docs-check` reject claim drift.
<!-- clun-generated:release-notes:end -->
## Highlights

- Issue #50 (Phase 76): pure-CL `Clun.cron` API —
  - `Clun.cron.parse(expression, from?)` → next UTC `Date` or `null` (5-field grammar, nicknames,
    named months/weekdays, Sunday-as-7, POSIX DOM/DOW OR semantics).
  - `Clun.cron(schedule, handler)` → in-process `CronJob` with `stop` / `ref` / `unref`, no-overlap
    reschedule after promise settlement, setTimeout-backed (fake-timer friendly).
  - OS-level `Clun.cron(path, schedule, title)` / `Clun.cron.remove(title)` fail closed (pure-CL
    cannot shell out to crontab/launchd/schtasks).
- Tests: 18 parachute cases + `tests/js/cron/{parse,job}.js` fixtures.
- Does **not** claim full Phase 76 Yes (REPL, OS cron, four-target `make compat FEATURE=cron-scheduling`
  remain open). Slot: free `0.1.0-dev.35` / `v0.1.0-dev.35` after master `0.1.0-dev.33` shell Yes.
- Hosted installer remains on published `v0.1.0-dev.21` until a later unit publishes.
