const B = require('node:buffer').Buffer;
// OOB numeric read/write -> a CATCHABLE RangeError, never a process crash
const b = B.alloc(4);
console.log('oob-read', (()=>{try{b.readUInt8(10);return 'no-throw'}catch(e){return e.constructor.name}})());
console.log('oob-write', (()=>{try{b.writeUInt32BE(1,3);return 'no-throw'}catch(e){return e.constructor.name}})());
// copy with a forward overlap on the same backing buffer (memmove semantics)
const c = B.from([1,2,3,4,5]);
c.copy(c, 2, 0, 3);                                          // -> 1,2,1,2,3
console.log('overlap', c.join(','));
// concat with totalLength larger than the sum -> zero-padded tail
console.log('concat-pad', B.concat([B.from([1,2]),B.from([3])], 5).join(','));
// concat truncates when totalLength is smaller
console.log('concat-trunc', B.concat([B.from([1,2,3,4]),B.from([5])], 2).join(','));
// write(string, encoding): the 2-arg form's second arg is the encoding, offset=0
const w = B.alloc(4);
console.log('write-enc', w.write('4869','hex'), w.slice(0,2).toString());   // 2 Hi
// write(string, offset, encoding): 3-arg form
const w2 = B.alloc(4); w2.write('4869', 1, 'hex');
console.log('write-off-enc', w2.join(','));                 // 0,72,105,0
