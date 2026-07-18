# Phase 76 — Cron, scheduling, and interactive REPL

**Issue:** [#50](https://github.com/theesfeld/clun/issues/50)  
**Status:** Partial checkpoint — pure-CL `Clun.cron` parse + in-process jobs shipped; REPL and OS-level scheduler open.

## Scope of this unit (`0.1.0-dev.34`)

### Shipped (pure CL)

1. **Expression grammar** matching frozen Bun `cron_parser`:
   - five fields: minute hour day month weekday
   - `*`, lists, ranges, steps; named months/weekdays (case-insensitive full or 3-letter)
   - weekday `0` and `7` = Sunday; bit-7 fold after range expansion
   - nicknames: `@yearly`/`@annually`, `@monthly`, `@weekly`, `@daily`/`@midnight`, `@hourly`
   - POSIX OR when both DOM and DOW are restricted
2. **`Clun.cron.parse(expr, from?)`** — next UTC occurrence strictly after `from` (Date or ms), or `null` within 8 years.
3. **`Clun.cron(schedule, handler)`** — in-process `CronJob`:
   - `cron` getter, `stop()`, `ref()`, `unref()` (chainable)
   - schedules via realm `setTimeout` so jest/vi fake timers control fire times
   - no-overlap: next fire computed only after handler (and returned Promise) settles
   - invalid expression or no future occurrences → TypeError at register
4. **OS-level overloads** — `Clun.cron(path, schedule, title)` and `Clun.cron.remove(title)` validate Bun-shaped args then **reject** with a clear purity message (crontab/launchd/schtasks require host shell-out; not pure CL).

### Open (remain Partial / phase incomplete)

- Interactive `clun repl` (multiline, top-level await, history, PTY)
- OS-level scheduler without purity exception (or approved pure-CL substitute)
- `make compat FEATURE=cron-scheduling` four-target receipts
- 100k scheduled-entry stress bound and leak gates
- `Symbol.dispose` / `using` convenience (stop() works)

## Non-goals

- Seconds field (6-field cron) — Bun rejects with “seconds are not supported”
- Local-time interpretation for in-process/parse (always UTC, matching Bun)
- Claiming a matrix `Yes` row (cron is beyond the 30-row homepage matrix)

## Tests

- `tests/lisp/runtime/cron-tests.lisp` — 18 parachute cases
- `tests/js/cron/parse.js`, `tests/js/cron/job.js` — fixture stdout locks

## SemVer

- Impact: **minor** (new public `Clun.cron` surface)
- Slot: **`0.1.0-dev.34`** / `v0.1.0-dev.34` after master shell Yes `0.1.0-dev.33`
