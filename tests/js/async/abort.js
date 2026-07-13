// AbortController / AbortSignal
const ac = new AbortController();
const fired = [];
ac.signal.addEventListener('abort', () => fired.push('a'));
ac.signal.addEventListener('abort', () => fired.push('b'));
console.log('before', ac.signal.aborted);
ac.abort();
console.log('after', ac.signal.aborted, ac.signal.reason.name, fired.join(','));
ac.abort();                                    // idempotent: no more listeners fire
console.log('idempotent', fired.join(','));
try { ac.signal.throwIfAborted(); } catch (e) { console.log('throwIf', e.name); }
// onabort handler
const ac2 = new AbortController();
ac2.signal.onabort = () => console.log('onabort');
ac2.abort();
// statics
console.log('static-abort', AbortSignal.abort('boom').reason);
// AbortSignal.any adopts the first abort
const p1 = new AbortController(), p2 = new AbortController();
const any = AbortSignal.any([p1.signal, p2.signal]);
p2.abort('from-p2');
console.log('any', any.aborted, any.reason);
// timers/promises rejects on mid-flight abort
const tp = require('node:timers/promises');
const ac3 = new AbortController();
tp.setTimeout(10000, 'never', { signal: ac3.signal })
  .then(() => console.log('BAD'), e => console.log('tp-abort', e.name));
ac3.abort();
