const B = require('node:buffer').Buffer;
console.log(B.alloc(4).join(','), B.alloc(3,0xff).join(','));
console.log(B.from('hello').toString(), B.from('hello').length, B.from('héllo').length);
console.log(B.from('hi').toString('hex'), B.from('4869','hex').toString());
console.log(B.from('hello').toString('base64'), B.from('aGVsbG8=','base64').toString());
console.log(B.from('hi').toString('base64url'), B.from('aGk','base64url').toString());
console.log(B.from([72,105]).toString('latin1'), B.from('AB').toString('ascii'));
console.log(B.concat([B.from('ab'),B.from('cd'),B.from('ef')]).toString());
console.log(B.from('abc').equals(B.from('abc')), B.from('abc').compare(B.from('abd')));
console.log(B.byteLength('héllo'), B.isBuffer(B.alloc(1)), B.isBuffer(new Uint8Array(1)));
console.log(B.from('hello').indexOf('llo'), B.from('hello').includes('x'), B.from('hello').lastIndexOf('l'));
// numeric round-trips (KAT)
const n = B.alloc(8);
n.writeUInt32BE(0xdeadbeef,0); console.log(n.readUInt32BE(0), n.readUInt8(0), n.readUInt16LE(0));
n.writeInt16LE(-1000,0); console.log(n.readInt16LE(0));
n.writeDoubleBE(1.5,0); console.log(n.readDoubleBE(0));
n.writeFloatLE(0.5,0); console.log(n.readFloatLE(0));
// slice shares memory
const p = B.from([1,2,3,4]); const s = p.slice(1,3); s[0]=99; console.log(p[1], s.join(','));
// fill + toJSON
console.log(B.alloc(3).fill(7).join(','), JSON.stringify(B.from([1,2]).toJSON()));
