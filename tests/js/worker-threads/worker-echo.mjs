import { parentPort, workerData, isMainThread, threadId } from 'worker_threads';

if (isMainThread) {
  throw new Error('worker script loaded as main');
}

const sab = workerData.sab;
const ia = new Int32Array(sab);
Atomics.add(ia, 0, 1);
parentPort.postMessage({ hello: 'from-worker', threadId, value: Atomics.load(ia, 0) });
parentPort.close();
