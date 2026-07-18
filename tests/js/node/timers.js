// Selected-surface timers evidence (#132): node:timers + node:timers/promises.
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

let order = [];
const id = timers.setTimeout(() => order.push('t'), 5);
timers.clearTimeout(id);
order.push('cleared');

timers.setImmediate(() => order.push('imm'));
queueMicrotask(() => order.push('micro'));

tp.setTimeout(1, 'done').then((v) => {
  order.push('tp:' + v);
  console.log('order', order.join('|'));
});
