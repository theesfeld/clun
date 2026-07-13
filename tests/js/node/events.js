const EventEmitter = require('node:events');
const ee = new EventEmitter();
const log = [];
ee.on('data', (a, b) => log.push('data:' + a + ',' + b));
ee.once('open', () => log.push('open'));
ee.emit('data', 1, 2);
ee.emit('open'); ee.emit('open');           // once fires only the first time
console.log(log.join('|'), ee.listenerCount('data'), ee.listenerCount('open'));
const f = () => log.push('x');
ee.on('e', f); ee.removeListener('e', f);
console.log('afterRemove', ee.listenerCount('e'));
let order = [];
ee.on('newListener', (n) => order.push('new:' + n));
ee.on('z', () => {});
console.log(order.join(','));
console.log('eventNames', ee.eventNames().sort().join(','));
let threw = false;
try { ee.emit('error', new Error('boom')); } catch (e) { threw = e.message; }
console.log('errorThrow', threw);
console.log('EE.EventEmitter===EE', EventEmitter.EventEmitter === EventEmitter);
