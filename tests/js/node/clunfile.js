const fs=require('node:fs'), os=require('node:os'), path=require('node:path');
const dir = fs.mkdtempSync(path.join(os.tmpdir(),'clun-cf13-'));
const f = path.join(dir,'x.txt');
Clun.write(f, 'clun file body').then(n => {
  console.log('write', n);
  const file = Clun.file(f);
  console.log('name-size', file.name === f, file.size);
  return Promise.all([file.text(), file.exists(), Clun.file(path.join(dir,'no')).exists()]);
}).then(([t, ex, nx]) => {
  console.log('lazy', t, ex, nx);
  return Clun.file(f).bytes();
}).then(b => {
  console.log('bytes', b.length, b instanceof Uint8Array);
  fs.rmSync(dir,{recursive:true});
});
