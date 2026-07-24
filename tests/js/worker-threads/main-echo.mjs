import { Worker, isMainThread } from 'worker_threads';
import { fileURLToPath } from 'url';
import path from 'path';

const sab = new SharedArrayBuffer(4);
const ia = new Int32Array(sab);
Atomics.store(ia, 0, 10);

const workerPath = path.join(path.dirname(fileURLToPath(import.meta.url)), 'worker-echo.mjs');
const w = new Worker(workerPath, { workerData: { sab } });

w.on('message', (msg) => {
  console.log(JSON.stringify({ msg, main: Atomics.load(ia, 0), isMain: isMainThread }));
  w.terminate().then(() => process.exit(0));
});

w.on('error', (e) => {
  console.error('worker error', e);
  process.exit(1);
});

setTimeout(() => {
  console.error('timeout');
  process.exit(2);
}, 5000);
