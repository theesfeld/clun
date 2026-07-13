const timers = require('node:timers');
// setTimeout extra args are forwarded
setTimeout((a, b) => console.log('args', a, b), 0, 'x', 'y');
// setInterval fires repeatedly until cleared
let n = 0;
const iv = setInterval(() => {
  n++;
  console.log('interval', n);
  if (n === 3) clearInterval(iv);
}, 0);
// ref/unref/hasRef on a Timeout
const t = setTimeout(() => {}, 100000);
console.log('hasRef', t.hasRef());
t.unref();
console.log('unrefHasRef', t.hasRef());
t.ref();
console.log('refHasRef', t.hasRef());
clearTimeout(t);
// clearImmediate cancels a pending immediate
const im = setImmediate(() => console.log('SHOULD NOT PRINT'));
clearImmediate(im);
// node:timers re-exports the same global functions
console.log('timers-eq', timers.setTimeout === setTimeout, timers.setImmediate === setImmediate);
