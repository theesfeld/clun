const EE = require('node:events');
// resolve with the event args
const e = new EE();
EE.once(e, 'data').then(a => console.log('got', a[0], a[1]));
e.emit('data', 'hello', 42);
// reject on 'error'
const e2 = new EE();
EE.once(e2, 'data').then(() => console.log('BAD'), err => console.log('err', err.message));
e2.emit('error', new Error('oops'));
// {signal}: already-aborted rejects
const e3 = new EE();
EE.once(e3, 'never', { signal: AbortSignal.abort() })
  .then(() => console.log('BAD2'), err => console.log('abort', err.name));
// captureRejections routes a rejecting listener to 'error'
const ce = new EE({ captureRejections: true });
ce.on('error', err => console.log('capture', err.message));
ce.on('go', async () => { throw new Error('rejected'); });
ce.emit('go');
