// path.win32 pure-CL residual (#108) — Node-shaped string algorithms.
const path = require('node:path');
const w = path.win32;
const p = path.posix;

function j(v) { return JSON.stringify(v); }

console.log('sep', w.sep === '\\');
console.log('delimiter', w.delimiter === ';');
console.log('links', w === w.win32, p.win32 === w, w.posix === p, p.posix === p);

console.log('join1', w.join('C:\\foo', 'bar', 'baz\\..', 'quux'));
console.log('join2', w.join('C:\\', '\\foo'));
console.log('join3', w.join('\\\\server\\share', 'a', 'b'));
console.log('join4', w.join('foo', 'bar'));
console.log('join5', w.join('C:', 'foo'));
console.log('join6', w.join('C:', '\\foo'));
console.log('join7', w.join());

console.log('norm1', w.normalize('C:\\\\temp\\\\..\\\\foo\\\\bar\\\\..\\\\'));
console.log('norm2', w.normalize('C:foo\\\\bar'));
console.log('norm3', w.normalize('\\\\server\\share\\..\\file'));
console.log('norm4', w.normalize('a\\b\\..\\c'));
console.log('norm5', w.normalize('.\\foo\\bar'));
console.log('norm6', w.normalize(''));
console.log('norm7', w.normalize('/'));

console.log('abs1', w.isAbsolute('//server'));
console.log('abs2', w.isAbsolute('C:/foo'));
console.log('abs3', w.isAbsolute('C:foo'));
console.log('abs4', w.isAbsolute('/foo'));
console.log('abs5', w.isAbsolute('\\\\foo\\\\bar'));
console.log('abs6', w.isAbsolute('foo\\bar'));
console.log('abs7', w.isAbsolute(''));

console.log('dir1', w.dirname('C:\\temp\\foo'));
console.log('dir2', w.dirname('C:\\'));
console.log('dir3', w.dirname('\\\\unc\\share'));
console.log('dir4', w.dirname('\\\\unc\\share\\foo'));
console.log('dir5', w.dirname('file.txt'));
console.log('dir6', w.dirname('C:\\temp'));

console.log('base1', w.basename('C:\\temp\\foo.html', '.html'));
console.log('base2', w.basename('C:\\temp\\foo.html'));
console.log('base3', w.basename('foo.html\\'));

console.log('ext1', w.extname('C:\\temp\\foo.html'));
console.log('ext2', w.extname('file.'));
console.log('ext3', j(w.extname('.bashrc')));
console.log('ext4', j(w.extname('..')));

console.log('parse1', j(w.parse('C:\\path\\dir\\file.txt')));
console.log('parse2', j(w.parse('\\\\server\\share\\file')));
console.log('parse3', j(w.parse('file.txt')));
console.log('parse4', j(w.parse('C:')));
console.log('parse5', j(w.parse('C:\\')));

console.log('rel1', w.relative('C:\\orandea\\test\\aaa', 'C:\\orandea\\impl\\bbb'));
console.log('rel2', w.relative('C:\\foo', 'D:\\bar'));
console.log('rel3', j(w.relative('C:\\foo\\bar', 'C:\\foo\\bar')));

console.log('fmt1', w.format({root:'C:\\', dir:'C:\\path\\dir', base:'file.txt'}));
console.log('fmt2', w.format({dir:'C:\\path\\dir', name:'file', ext:'.txt'}));

console.log('res1', w.resolve('C:\\foo', 'bar'));
console.log('res2', w.resolve('C:\\foo', 'D:\\bar', 'baz'));

console.log('nsp1', w.toNamespacedPath('C:\\foo'));
console.log('nsp2', w.toNamespacedPath('\\\\server\\share\\a'));
console.log('makeLong', typeof w._makeLong === 'function',
            w._makeLong('C:\\foo') === w.toNamespacedPath('C:\\foo'));

// Host-cwd dependent resolve: must rewrite / -> \ and end with \foo\bar
const r = w.resolve('foo', 'bar');
console.log('res-cwd', r.indexOf('\\') !== -1 && /[\\\/]foo[\\\/]bar$/.test(r));

// Default export remains posix on this host
console.log('default-posix', path === p, path.sep === '/');
