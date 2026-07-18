// Residual pure-CL node:fs surface: hard links, chown/lchown, utimes, and
// callback/promises parity for the path-based ops already backed by clun.sys.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'clun-fsres-'));
const a = path.join(dir, 'a.txt');
const b = path.join(dir, 'b.txt');
const c = path.join(dir, 'c.txt');
const s = path.join(dir, 's.lnk');

fs.writeFileSync(a, 'payload');
fs.linkSync(a, b);
console.log('link', fs.readFileSync(b, 'utf8'), fs.statSync(a).nlink >= 2);

const st = fs.statSync(a);
fs.chownSync(a, st.uid, st.gid);
fs.lchownSync(a, st.uid, st.gid);
console.log('chown', fs.statSync(a).uid === st.uid, fs.statSync(a).gid === st.gid);

// Unix-seconds form + Date form (ms epoch) both set mtime/atime.
fs.utimesSync(a, 1000000000, 1000000500);
const st2 = fs.statSync(a);
console.log('utimes-num', st2.atimeMs === 1e12, st2.mtimeMs === 1000000500 * 1000);
fs.utimesSync(a, new Date(1000001000 * 1000), new Date(1000001500 * 1000));
const st3 = fs.statSync(a);
console.log('utimes-date', st3.atimeMs === 1000001000 * 1000, st3.mtimeMs === 1000001500 * 1000);

fs.symlinkSync(a, s);
console.log('readlink', fs.readlinkSync(s) === a);
fs.chmodSync(a, 0o600);
console.log('chmod', (fs.statSync(a).mode & 0o777) === 0o600);
fs.truncateSync(a, 3);
console.log('trunc', fs.readFileSync(a, 'utf8'));
fs.copyFileSync(b, c);
// b still holds the pre-truncate hard-link content after truncate of a? On POSIX
// hard links share inode — truncate of a also truncates b. Copy from b after
// truncate therefore yields the truncated body.
console.log('copy', fs.readFileSync(c, 'utf8'));

const p = fs.promises;
console.log(
  'promises',
  typeof p.link, typeof p.chown, typeof p.lchown, typeof p.utimes,
  typeof p.readlink, typeof p.symlink, typeof p.chmod, typeof p.truncate,
  typeof p.rmdir, typeof p.rm, typeof p.lstat, typeof p.copyFile
);
console.log(
  'callbacks',
  typeof fs.link, typeof fs.chown, typeof fs.utimes, typeof fs.lstat,
  typeof fs.copyFile, typeof fs.realpath, typeof fs.readlink, typeof fs.rm,
  typeof fs.rmdir, typeof fs.chmod, typeof fs.truncate, typeof fs.mkdtemp
);

fs.rmSync(dir, { recursive: true, force: true });
console.log('done', !fs.existsSync(dir));
