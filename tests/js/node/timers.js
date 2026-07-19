// Selected-surface timers evidence (#132): node:timers + node:timers/promises.
// Keep async order deterministic: clearTimeout, then a single promises delay.
const timers = require('node:timers');
const tp = require('node:timers/promises');

console.log('exports',
            typeof timers.setTimeout, typeof timers.clearTimeout,
            typeof timers.setInterval, typeof timers.clearInterval,
            typeof timers.setImmediate, typeof timers.clearImmediate,
            typeof timers.queueMicrotask,
            typeof timers.enroll, typeof timers.unenroll, typeof timers.active);

console.log('promises',
            typeof tp.setTimeout, typeof tp.setImmediate, typeof tp.setInterval);

const cancelled = timers.setTimeout(() => {
  console.log('cancel-fail');
  process.exit(1);
}, 50);
timers.clearTimeout(cancelled);
console.log('cleared', true);

tp.setTimeout(1, 'done').then((v) => {
  console.log('tp', v);
});
