function check(cond, label) {
  if (!cond) throw new Error("cron job check failed: " + label);
}

let called = false;
const job = Clun.cron("* * * * *", function () {
  called = true;
});
check(job.cron === "* * * * *", "cron getter");
check(typeof job.stop === "function", "stop");
check(typeof job.ref === "function", "ref");
check(typeof job.unref === "function", "unref");
check(job.unref() === job && job.ref() === job, "chainable");
job.stop();
check(called === false, "stop before fire");
check(job.stop() === job, "stop idempotent");

let threw = false;
try {
  Clun.cron("0 0 30 2 *", () => {});
} catch (e) {
  threw = e.name === "TypeError" && /no future occurrences/.test(e.message);
}
check(threw, "no future occurrences");

const nick = Clun.cron("@hourly", () => {});
check(nick.cron === "@hourly", "nickname schedule string");
nick.stop();

const named = Clun.cron("0 9 * JAN-DEC MON-FRI", () => {});
check(named.cron === "0 9 * JAN-DEC MON-FRI", "named fields preserved");
named.stop();

console.log("cron-job-ok");
