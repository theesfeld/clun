const fs=require('node:fs'), os=require('node:os'), path=require('node:path');
const dir = fs.mkdtempSync(path.join(os.tmpdir(),'clun-f13-'));
const bracket = path.join(dir,'has[bracket].txt');       // §3.2 path-discipline
fs.writeFileSync(bracket, 'brackets ok');
console.log('bracket', fs.readFileSync(bracket,'utf8'), fs.existsSync(bracket));
fs.mkdirSync(path.join(dir,'a/b/c'), {recursive:true});
fs.writeFileSync(path.join(dir,'a/b/c/f.txt'),'deep');
console.log('deep', fs.readFileSync(path.join(dir,'a/b/c/f.txt'),'utf8'));
fs.symlinkSync(path.join(dir,'a/b/c/f.txt'), path.join(dir,'link1'));
fs.symlinkSync(path.join(dir,'link1'), path.join(dir,'link2'));   // symlink chain
console.log('symlink', fs.readFileSync(path.join(dir,'link2'),'utf8'),
            fs.lstatSync(path.join(dir,'link2')).isSymbolicLink(),
            fs.statSync(path.join(dir,'link2')).isFile());
console.log('enoent', (()=>{try{fs.readFileSync(path.join(dir,'nope'))}catch(e){return e.code}})());
console.log('eisdir', (()=>{try{fs.readFileSync(dir)}catch(e){return e.code}})());
const st = fs.statSync(bracket);
console.log('stat', st.size, st.isFile(), st.isDirectory(), st.mtime instanceof Date);
console.log('readdir', fs.readdirSync(dir).includes('has[bracket].txt'));
fs.appendFileSync(bracket, '!'); console.log('append', fs.readFileSync(bracket,'utf8'));
fs.renameSync(bracket, path.join(dir,'renamed.txt'));
console.log('rename', fs.existsSync(bracket), fs.existsSync(path.join(dir,'renamed.txt')));
fs.rmSync(dir,{recursive:true}); console.log('rm', fs.existsSync(dir));
