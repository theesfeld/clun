// Selected Node surface smoke (#132): path/os/querystring/util plus require
// identity for fs/url/buffer/events/assert/timers(/promises) and process.
const path = require('node:path');
console.log(path.join('/a/b', '..', 'c/'), path.basename('/x/y.js', '.js'),
            path.dirname('/x/y/z'), path.extname('a.b.c'), path.isAbsolute('rel'),
            path.normalize('/a//b/../c'), JSON.stringify(path.parse('/d/f.txt')),
            path.format({dir:'/d', base:'f.txt'}), path.relative('/a/b/c', '/a/b/d/e'));
const os = require('node:os');
console.log(os.EOL === '\n', os.endianness(), typeof os.hostname(), Array.isArray(os.loadavg()),
            os.cpus().length >= 1, typeof os.freemem());
const qs = require('node:querystring');
console.log(qs.stringify({a:'1',b:['x','y'],c:'a b'}));
console.log(JSON.stringify(qs.parse('a=1&b=2&b=3&c=a%20b')));
console.log(qs.escape("a b/c?d"), qs.unescape("a%20b%2Fc"));
const util = require('node:util');
console.log(util.format('%s/%d/%i/%f/%%', 'S', 3.9, 4.9, 1.5));
console.log(util.format('%j', {x:[1,2]}), util.format('a', 'b', 1));
console.log(util.isDeepStrictEqual({a:[1,{b:2}]}, {a:[1,{b:2}]}),
            util.isDeepStrictEqual([1,2], [1,2,3]),
            util.stripVTControlCharacters('\x1b[1mX\x1b[0mY'));
const buffer = require('node:buffer');
const events = require('node:events');
const assert = require('node:assert');
const fs = require('node:fs');
const url = require('node:url');
const timers = require('node:timers');
const tprom = require('node:timers/promises');
console.log('selected',
            typeof buffer.Buffer, typeof events, typeof assert.ok,
            typeof fs.readFileSync, typeof url.parse, typeof url.fileURLToPath,
            typeof timers.setTimeout, typeof tprom.setTimeout,
            typeof process.cwd, path.win32.sep === '\\', path.posix.sep === '/');
