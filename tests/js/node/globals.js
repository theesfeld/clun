console.log(JSON.stringify(structuredClone({n:1, a:[1,2,{b:3}], s:'x', t:true})));
const uuid = crypto.randomUUID();
console.log(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(uuid),
            crypto.randomUUID() !== crypto.randomUUID());
const buf = new Uint8Array(16);
crypto.getRandomValues(buf);
console.log(buf.length === 16, buf instanceof Uint8Array);
console.log(typeof Clun.nanoseconds(), typeof Clun.which('sh'),
            Clun.fileURLToPath('file:///tmp/a%20b.txt'), Clun.deepEquals({x:1}, {x:1}));
