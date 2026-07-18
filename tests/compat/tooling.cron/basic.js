// Frozen Bun.cron contract (in-process + parse). Clun exposes Clun.cron.
// OS-level register/remove fail closed under pure-CL.

function t(fn) {
  try {
    fn();
    return "ok";
  } catch (e) {
    return e.message;
  }
}

function kind(fn) {
  try {
    fn();
    return "ok";
  } catch (e) {
    if (/Invalid cron/.test(e.message)) return "invalid";
    if (/no future/.test(e.message)) return "nofuture";
    if (/string cron/.test(e.message)) return "notstring";
    return "other:" + e.name + ":" + e.message;
  }
}

console.log(
  "api",
  typeof Clun.cron,
  typeof Clun.cron.parse,
  typeof Clun.cron.remove,
  Clun.cron.name,
  Clun.cron.parse.name,
);

const ns = Object.getOwnPropertyDescriptor(Clun, "cron");
console.log(
  "namespace-descriptor",
  ns.writable,
  ns.enumerable,
  ns.configurable,
);

const j = Clun.cron("* * * * *", function () {});
console.log("job", j.cron, typeof j.stop, typeof j.ref, typeof j.unref);
console.log("chain", j.unref() === j, j.ref() === j, j.stop() === j);
j.stop();

console.log(
  "validate",
  kind(() => Clun.cron("invalid expr", () => {})),
  kind(() => Clun.cron("* * * *", () => {})),
  kind(() => Clun.cron("60 * * * *", () => {})),
  kind(() => Clun.cron(123, () => {})),
  kind(() => Clun.cron("0 0 30 2 *", () => {})),
);

console.log(
  "parse",
  Clun.cron.parse("0 9 * * *", new Date("2026-06-15T00:00:00Z")).toISOString(),
  Clun.cron.parse("0 9 * * *", new Date("2026-06-15T09:00:00Z")).toISOString(),
  Clun.cron.parse("0 0 30 2 *", new Date("2026-01-01T00:00:00Z")),
  Clun.cron.parse("0 0 13 * 5", new Date("2026-01-01T00:00:00Z")).toISOString(),
  Clun.cron.parse("0 0 * * 7", new Date("2026-01-01T00:00:00Z")).toISOString(),
);

console.log(
  "nicknames",
  Clun.cron.parse("@hourly", new Date("2026-06-15T12:30:00Z")).toISOString(),
  Clun.cron.parse("@daily", new Date("2026-06-15T12:30:00Z")).toISOString(),
);

const named = Clun.cron("0 9 * JAN-DEC MON-FRI", () => {});
console.log("named", named.cron);
named.stop();

// OS-level fail-closed: returns a rejected Promise (never registers).
const os = Clun.cron("./job.js", "@hourly", "title");
const rm = Clun.cron.remove("title");
console.log("os-level", os instanceof Promise, rm instanceof Promise);
Promise.allSettled([os, rm]).then((results) => {
  console.log(
    "os-reject",
    results[0].status === "rejected" &&
      /pure Common Lisp|unavailable|crontab/i.test(results[0].reason.message),
    results[1].status === "rejected" &&
      /pure Common Lisp|unavailable|crontab/i.test(results[1].reason.message),
  );
});
