# Phase 76 — Cron scheduling pure-CL (Issue #136)

**Issue:** #136 (parent #50)  
**Ledger:** `tooling.cron` → **Yes** (in-process + parse; OS-level fail-closed)  
**SemVer:** `0.1.0-dev.34` / minor within the `0.1.0` prerelease train

## Goal

Ship a Bun-compatible `Clun.cron` surface in pure Common Lisp: expression grammar,
next-occurrence (UTC), and in-process callback scheduling with stop/ref/unref and
no-overlap re-arm. OS-level register/remove cannot shell out to crontab/launchd/schtasks
under the purity constitution, so those overloads fail closed with a clear Error.

## Public contract

```js
Clun.cron(schedule, handler)           // -> CronJob { cron, stop, ref, unref }
Clun.cron.parse(expression, from?)     // -> Date | null  (UTC, strictly after `from`)
Clun.cron(path, schedule, title)       // -> Promise (rejects: OS unsupported)
Clun.cron.remove(title)                // -> Promise (rejects: OS unsupported)
```

## Behavior (Bun-pinned)

- 5-field expressions + `@yearly`/`@annually`/`@monthly`/`@weekly`/`@daily`/`@midnight`/`@hourly`
- Lists, ranges, steps; month/weekday names; weekday `7` = Sunday
- DOM+DOW both restricted → POSIX OR semantics
- Next search strictly after `from`, 8-year horizon, null when impossible (e.g. Feb 30)
- In-process: default ref'd (keeps event loop alive); `.unref()` allows exit
- No-overlap: next fire computed only after the callback settles (including returned Promise)
- Sync throw re-arms after the exception propagates; rejected Promise re-arms after settle

## Non-goals

- OS-level persistence (crontab / launchd / Task Scheduler)
- Interactive REPL (remainder of Phase 76 / parent #50)
- Seconds field (Bun rejects 6-field expressions)

## Evidence

- `tests/lisp/runtime/cron-tests.lisp`
- `tests/compat/tooling.cron/basic.js` / `basic.out`
- Four-target `supported` platforms for `tooling.cron`
