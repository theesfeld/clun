const url = require('node:url');

// parse core
const p = url.parse('http://user:pw@example.com:8080/a/b?x=1&y=2#frag');
console.log([p.protocol, p.slashes, p.auth, p.host, p.hostname, p.port,
             p.pathname, p.search, p.query, p.hash, p.path, p.href].join('|'));

const p2 = url.parse('https://example.com/path');
console.log([p2.protocol, p2.host, p2.pathname, p2.href].join('|'));

const p3 = url.parse('http://example.com');
console.log([p3.pathname, p3.path, p3.href].join('|'));

const p4 = url.parse('file:///tmp/a%20b.txt');
console.log([p4.protocol, p4.slashes, p4.hostname, p4.pathname, p4.href].join('|'));

// parseQueryString + slashesDenoteHost
const pq = url.parse('http://ex.com/?a=1&b=2', true);
console.log(pq.query.a, pq.query.b, typeof pq.query);
const sh = url.parse('//host/path', false, true);
console.log([sh.slashes, sh.host, sh.hostname, sh.pathname, sh.href].join('|'));

// IPv6
const v6 = url.parse('http://[::1]:8080/x');
console.log([v6.host, v6.hostname, v6.port, v6.pathname].join('|'));

// format
console.log(url.format(p));
console.log(url.format({protocol:'http:', host:'ex.com', pathname:'/a', search:'?q=1', hash:'#h'}));
console.log(url.format({protocol:'http', slashes:true, host:'ex.com', pathname:'/a'}));
console.log(url.format({protocol:'http:', hostname:'ex.com', port:'8080', pathname:'/a',
                        query:{a:1, b:'x y'}}));

// resolve
console.log(url.resolve('http://ex.com/a/b', 'c'));
console.log(url.resolve('http://ex.com/a/b/', 'c'));
console.log(url.resolve('http://ex.com/a/b', '/c'));
console.log(url.resolve('http://ex.com/a/b', 'http://other/x'));
console.log(url.resolve('http://ex.com/a/b', '//other/x'));
console.log(url.resolve('/a/b/c', '../d'));
console.log(url.resolve('http://ex.com', 'a'));

// file helpers
console.log(url.fileURLToPath('file:///tmp/a%20b.txt'));
console.log(url.pathToFileURL('/tmp/a b.txt').href);
console.log(url.fileURLToPath(url.pathToFileURL('/tmp/z.txt')));

// re-exports + domain helpers
console.log(typeof url.URL, typeof url.URLSearchParams, url.URL === URL);
console.log(url.domainToASCII('Example.COM'), url.domainToUnicode('Example.COM'));
console.log(url.domainToASCII('exämple.com') === '');
