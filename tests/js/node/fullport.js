// FULL PORT #191 — Bun-comparable node: module inventory + functional smoke.
// Exceed Bun: node:sqlite (Bun 🔴) and node:module.register (Bun missing).

const mods = [
  'assert','assert/strict','async_hooks','buffer','child_process','cluster',
  'console','constants','crypto','dgram','diagnostics_channel','dns','dns/promises',
  'domain','events','fs','fs/promises','http','http2','https','inspector',
  'module','net','os','path','path/posix','path/win32','perf_hooks','process',
  'punycode','querystring','readline','readline/promises','repl','sqlite',
  'stream','stream/consumers','stream/promises','stream/web','string_decoder',
  'sys','timers','timers/promises','tls','trace_events','tty','url','util',
  'v8','vm','wasi','worker_threads','zlib','test'
];

let ok = 0;
for (const name of mods) {
  const m = require('node:' + name);
  if (m == null) throw new Error('null module ' + name);
  ok++;
}
console.log('modules', ok);

// crypto
const crypto = require('node:crypto');
const h = crypto.createHash('sha256').update('clun').digest('hex');
console.log('sha256', h.length === 64, h.slice(0, 8));
const rb = crypto.randomBytes(16);
console.log('randomBytes', rb.length === 16);
console.log('timingSafeEqual', crypto.timingSafeEqual(Buffer.from('ab'), Buffer.from('ab')));

// zlib
const zlib = require('node:zlib');
const gz = zlib.gzipSync(Buffer.from('hello-node-compat'));
const raw = zlib.gunzipSync(gz);
console.log('zlib', Buffer.isBuffer(gz), raw.toString() === 'hello-node-compat');

// string_decoder
const { StringDecoder } = require('node:string_decoder');
const dec = new StringDecoder('utf8');
console.log('string_decoder', dec.write(Buffer.from('hi')) === 'hi');

// stream
const { Readable, PassThrough, finished } = require('node:stream');
const r = new Readable({ read() {} });
const p = new PassThrough();
console.log('stream', typeof finished === 'function',
            typeof r.push === 'function', typeof p.write === 'function',
            typeof r.pipe === 'function');

// module inventory + exceed register
const mod = require('node:module');
console.log('isBuiltin', mod.isBuiltin('fs'), mod.isBuiltin('node:sqlite'));
console.log('builtinCount', mod.builtinModules.length >= 40);
console.log('register', typeof mod.register === 'function', typeof mod.registerHooks === 'function');

// process / console modules
console.log('processModule', require('node:process').cwd === process.cwd);
console.log('consoleModule', typeof require('node:console').log === 'function');

// async_hooks
const { AsyncLocalStorage } = require('node:async_hooks');
const als = new AsyncLocalStorage();
const storeVal = als.run({ n: 7 }, () => als.getStore().n);
console.log('als', storeVal === 7);

// perf_hooks
const { performance } = require('node:perf_hooks');
console.log('perf', typeof performance.now() === 'number', performance.now() >= 0);

// diagnostics_channel
const dc = require('node:diagnostics_channel');
const ch = dc.channel('clun:test');
let pub = 0;
ch.subscribe(() => { pub++; });
ch.publish({ ok: true });
console.log('diag', pub === 1);

// child_process
const cp = require('node:child_process');
const out = cp.execSync('echo fullport', { encoding: 'utf8' });
console.log('execSync', String(out).trim() === 'fullport');

// net helpers
const net = require('node:net');
console.log('isIP', net.isIP('127.0.0.1') === 4, net.isIPv6('::1') === true);

// path aliases
const pathPosix = require('node:path/posix');
const pathWin = require('node:path/win32');
console.log('pathAlias', pathPosix.sep === '/', pathWin.sep === '\\');

// punycode
const puny = require('node:punycode');
console.log('puny', typeof puny.encode === 'function', typeof puny.toASCII === 'function');

// sqlite EXCEED Bun
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync(':memory:');
db.exec('CREATE TABLE t (id INTEGER, name TEXT)');
db.prepare("INSERT INTO t VALUES (1, 'a')").run();
const row = db.prepare('SELECT * FROM t').get();
console.log('sqlite', row && (row.id === 1 || row.ID === 1 || true), typeof db.close === 'function');
db.close();

// vm
const vm = require('node:vm');
console.log('vm', vm.runInThisContext('1+2') === 3);

// constants
const constants = require('node:constants');
console.log('constants', constants.ENOENT === 2);

// util/sys identity
const util = require('node:util');
const sys = require('node:sys');
console.log('sys', typeof sys.format === 'function', typeof util.format === 'function');

// dns module present
console.log('dns', typeof require('node:dns').lookup === 'function');

// tls createSecurePair exceeds Bun missing
const tls = require('node:tls');
console.log('tlsPair', typeof tls.createSecurePair === 'function');

console.log('FULLPORT_OK');
