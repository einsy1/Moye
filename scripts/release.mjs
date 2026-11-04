// Freeze a tagged, tested version without overwriting any historical release.
import {readFile,mkdir,rm,copyFile,writeFile,mkdtemp} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {tmpdir} from 'node:os';
import path from 'node:path';
const root=path.resolve(import.meta.dirname,'..');process.chdir(root);
const {version}=JSON.parse(await readFile('package.json','utf8'));
if(!/^\d+\.\d+\.\d+$/.test(version))throw Error('Invalid version');
const run=(command,args)=>execFileSync(command,args,{encoding:'utf8'}).trim();
if(run('git',['status','--porcelain']))throw Error('Commit the source and validation notes before releasing.');
if(run('git',['rev-parse','HEAD'])!==run('git',['rev-list','-n','1',`v${version}`]))throw Error('Version tag must point to HEAD.');
const app=path.join(root,'dist',`墨页 ${version}.app`);
if(run('/usr/libexec/PlistBuddy',['-c','Print :CFBundleShortVersionString',app+'/Contents/Info.plist'])!==version)throw Error('Build version mismatch');
run('codesign',['--verify','--deep','--strict',app]);
const destination=path.join(root,'releases',version);
// Reserve the final directory exclusively. A failed attempt never replaces an old release.
await mkdir(path.dirname(destination),{recursive:true});
await mkdir(destination);
const temp=await mkdtemp(path.join(tmpdir(),'moye-release-'));
try{
  const appName=`Moye-${version}-macOS-arm64.zip`,sourceName=`Moye-${version}-source.zip`;
  run('ditto',['--noextattr','--norsrc','-c','-k','--keepParent',app,path.join(temp,appName)]);
  run('git',['archive','--format=zip',`--prefix=Moye-${version}/`,`--output=${path.join(temp,sourceName)}`,`v${version}`]);
  // Verify the archive using macOS's normal extractor, including executable permissions.
  const extracted=path.join(temp,'extracted');await mkdir(extracted);
  run('ditto',['-x','-k',path.join(temp,appName),extracted]);
  run('codesign',['--verify','--deep','--strict',path.join(extracted,`墨页 ${version}.app`)]);
  const sums=[];
  for(const name of [appName,sourceName]){
    const data=await readFile(path.join(temp,name));
    sums.push(createHash('sha256').update(data).digest('hex')+`  ${name}`);
    await copyFile(path.join(temp,name),path.join(destination,name));
  }
  await writeFile(path.join(destination,'SHA256SUMS'),sums.join('\n')+'\n');
  console.log(`Released ${destination}`);
}catch(error){await rm(destination,{recursive:true,force:true});throw error}
finally{await rm(temp,{recursive:true,force:true})}
