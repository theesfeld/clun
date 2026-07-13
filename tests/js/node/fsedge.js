const fs=require('node:fs'), os=require('node:os'), path=require('node:path');
const dir = fs.mkdtempSync(path.join(os.tmpdir(),'clun-fe13-'));
// error message format ("ENOENT: no such file or directory, open '...'") + code + negative errno
try { fs.readFileSync(path.join(dir,'nope')); } catch(e){
  console.log('msg', e.message.startsWith('ENOENT: no such file or directory, '));
  console.log('code-errno', e.code, e.errno);
}
// mkdirSync({recursive}) returns the TOPMOST newly-created directory
const created = fs.mkdirSync(path.join(dir,'x/y/z'), {recursive:true});
console.log('mkdir-ret', created === path.join(dir,'x'));
// recursive mkdir when it already exists -> undefined
console.log('mkdir-exists', fs.mkdirSync(path.join(dir,'x/y/z'), {recursive:true}));
// non-recursive mkdir -> undefined
console.log('mkdir-nonrec', fs.mkdirSync(path.join(dir,'plain')));
// accessSync honours the mode argument
fs.writeFileSync(path.join(dir,'r.txt'),'hi');
console.log('access-fok', (()=>{try{fs.accessSync(path.join(dir,'r.txt'), fs.constants.F_OK);return 'ok'}catch(e){return e.code}})());
console.log('access-enoent', (()=>{try{fs.accessSync(path.join(dir,'no'), fs.constants.R_OK);return 'ok'}catch(e){return e.code}})());
fs.rmSync(dir,{recursive:true});
