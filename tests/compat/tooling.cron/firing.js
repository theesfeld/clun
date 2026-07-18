// In-process fire under injectable wall clock via Date + setTimeout (fake-timer free).
// Uses a past-leaning schedule boundary: every minute; we advance by stopping after arming.
const job = Clun.cron("* * * * *", function () {
  console.log("fired", this === job, this.cron);
  job.stop();
});
console.log("armed", job.cron, typeof job.stop);
// Stop before a real minute elapses so the process can exit cleanly under test timeouts.
setTimeout(() => {
  if (typeof job.stop === "function") job.stop();
  console.log("stopped-early");
}, 20);
