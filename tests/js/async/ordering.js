// Deterministic phase ordering: sync -> nextTick (all) -> microtasks (FIFO:
// Promise.then then queueMicrotask) -> timers -> immediates (check). The
// setTimeout(0)-vs-setImmediate order is unspecified in Node; Clun makes it
// deterministic (timer first) — see DECISIONS / fs-buffer... phase-14 notes.
console.log('1: sync start');
setTimeout(() => console.log('6: timeout'), 0);
setImmediate(() => console.log('7: immediate'));
Promise.resolve().then(() => console.log('4: promise'));
queueMicrotask(() => console.log('5: microtask'));
process.nextTick(() => console.log('3: nextTick'));
console.log('2: sync end');
