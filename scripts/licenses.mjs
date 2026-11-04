import {readFile,writeFile,mkdir,readdir,copyFile} from 'node:fs/promises';
const lock=JSON.parse(await readFile('package-lock.json','utf8'));
const output=process.argv[2];
if(!output)throw Error('Provide the license output directory');
await mkdir(output,{recursive:true});
const index=[];
for(const [path,info] of Object.entries(lock.packages)){
 if(!path||info.dev)continue;
 const files=await readdir(path);
 const license=files.find(f=>/^licen[sc]e(\.(txt|md))?$/i.test(f));
 if(!license)throw Error(`Missing license text: ${path}`);
 const name=path.replace('node_modules/','').replaceAll('/','_');
 await writeFile(`${output}/${name}.txt`,await readFile(`${path}/${license}`));
 index.push(`${path.replace('node_modules/','')} ${info.version} — ${info.license||'See license text'}`);
}
await writeFile(`${output}/DEPENDENCIES.txt`,index.join('\n')+'\n');
for(const file of ['LICENSE','THIRD_PARTY_NOTICES.md','PRIVACY.md'])await copyFile(file,`${output}/${file}`);
