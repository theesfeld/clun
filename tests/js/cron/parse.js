function check(cond, label) {
  if (!cond) throw new Error("cron parse check failed: " + label);
}

check(typeof Clun.cron === "function", "Clun.cron is function");
check(typeof Clun.cron.parse === "function", "Clun.cron.parse is function");
check(typeof Clun.cron.remove === "function", "Clun.cron.remove is function");

const next = Clun.cron.parse("0 9 * * *", new Date("2026-06-15T00:00:00Z"));
check(next instanceof Date, "parse returns Date");
check(next.toISOString() === "2026-06-15T09:00:00.000Z", "9am UTC");

const after = Clun.cron.parse("0 9 * * *", new Date("2026-06-15T09:00:00Z"));
check(after.toISOString() === "2026-06-16T09:00:00.000Z", "strictly after");

const nullish = Clun.cron.parse("0 0 30 2 *", new Date("2026-01-01T00:00:00Z"));
check(nullish === null, "impossible date is null");

const hourly = Clun.cron.parse("@hourly", new Date("2026-06-15T12:00:00Z"));
check(hourly.toISOString() === "2026-06-15T13:00:00.000Z", "@hourly");

const weekday = Clun.cron.parse("0 12 * * MON", new Date("2026-06-14T23:00:00Z"));
check(weekday.toISOString() === "2026-06-15T12:00:00.000Z", "named weekday UTC");

const orDom = Clun.cron.parse("0 0 13 * 5", new Date("2026-01-01T00:00:00Z"));
check(orDom.toISOString() === "2026-01-02T00:00:00.000Z", "DOM/DOW OR");

let threw = false;
try {
  Clun.cron.parse("* * * *");
} catch (e) {
  threw = e.name === "TypeError";
}
check(threw, "too few fields throws TypeError");

console.log("cron-parse-ok");
