// SharedArrayBuffer + Atomics single-thread surface (Issue #338).
const sab = new SharedArrayBuffer(8);
const ia = new Int32Array(sab);
console.log(typeof SharedArrayBuffer, typeof Atomics);
console.log(sab.byteLength);
console.log(Atomics.store(ia, 0, 7), Atomics.load(ia, 0));
console.log(Atomics.add(ia, 0, 3), Atomics.load(ia, 0));
console.log(Atomics.compareExchange(ia, 0, 10, 42), Atomics.load(ia, 0));
console.log(Atomics.wait(ia, 0, 0, 0)); // not-equal path would be value mismatch; value is 42
console.log(Atomics.wait(ia, 0, 42, 0)); // timed-out
console.log(Atomics.isLockFree(4));
console.log(Object.prototype.toString.call(sab));
