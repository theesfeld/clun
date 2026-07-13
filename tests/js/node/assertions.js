const assert = require('node:assert');
function caught(fn) { try { fn(); return null; } catch (e) { return e.name + ':' + (e.code || ''); } }
console.log('ok', caught(() => assert.ok(1)), caught(() => assert.ok(0)));
console.log('eq', caught(() => assert.equal(1, 1)), caught(() => assert.strictEqual(1, '1')));
console.log('deep', caught(() => assert.deepStrictEqual([1, {a:2}], [1, {a:2}])),
            caught(() => assert.deepStrictEqual({a:1}, {a:2})));
console.log('throws', caught(() => assert.throws(() => { throw new Error('x'); })),
            caught(() => assert.throws(() => {})));
console.log('match', caught(() => assert.match('hello', /ell/)),
            caught(() => assert.match('hello', /zzz/)));
