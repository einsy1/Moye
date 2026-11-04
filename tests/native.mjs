import {createServer} from 'node:http';
import {spawn,spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
const compiled=spawnSync('swiftc',['-parse-as-library','Sources/WebDAV.swift','Sources/Storage.swift','tests/NativeTests.swift','-framework','Security','-o','dist/native-tests'],{stdio:'inherit'});if(compiled.status)process.exit(compiled.status);
let files=new Map(),redirected=false, transientReads=0;
const server=createServer(async(req,res)=>{let body='';for await(const c of req)body+=c;const path=decodeURIComponent(req.url);
if(path==='/redirect/'){res.writeHead(302,{Location:'/redirect-target'});res.end();return}if(path==='/redirect-target')redirected=true;
if(req.headers.authorization!=='Basic '+Buffer.from('tester:test-only').toString('base64')){res.writeHead(401);res.end();return}
if(req.method==='GET'&&path==='/huge.md'){res.writeHead(200,{'Content-Type':'text/markdown','Content-Length':'10000001'});res.end('too big');return}
if(req.method==='GET'&&path==='/chunked.md'){res.writeHead(200,{'Content-Type':'text/markdown'});const chunk=Buffer.alloc(65536,65);let n=0;const pump=()=>{while(n++<170){if(res.destroyed)return;if(!res.write(chunk)){res.once('drain',pump);return}}res.end()};pump();return}
if(req.method==='PROPFIND'){
if(path==='/transient/'&&++transientReads<3){res.writeHead(503);res.end();return}
assert.ok(['0','1'].includes(req.headers.depth));assert.match(body,/resourcetype/);assert.match(req.headers['content-type'],/application\/xml/);
const entry=(href,name,collection=true,status=200)=>`<z:response><z:href>${href}</z:href><z:propstat><z:prop><z:displayname>${name}</z:displayname><z:resourcetype>${collection?'<z:collection/>':''}</z:resourcetype></z:prop><z:status>HTTP/1.1 ${status} Result</z:status></z:propstat></z:response>`;
res.writeHead(207,{'Content-Type':'application/xml'});
if(path==='/notxml/'){res.end('<html>not WebDAV</html>');return}
if(path==='/missing/'){res.end('<z:multistatus xmlns:z="DAV:"><z:response><z:href>/missing/</z:href><z:status>HTTP/1.1 404 Not Found</z:status></z:response></z:multistatus>');return}
let entries=entry(req.url,'Current');if(req.headers.depth==='1'&&path==='/')entries+=entry('/%E7%A4%BA%E4%BE%8B%E6%96%87%E4%BB%B6/','示例文件')+entry('/Space%20Folder/','Space Folder')+entry('/note.md','file',false)+entry('https://outside.invalid/private/','outside')+entry('/%E7%A4%BA%E4%BE%8B%E6%96%87%E4%BB%B6/grandchild/','grandchild')+entry('/blocked/','blocked',true,403)+entry('/bad%2Fchild/','encoded slash')+entry('/%E7%A4%BA%E4%BE%8B%E6%96%87%E4%BB%B6/','duplicate');
if(req.headers.depth==='1'&&path==='/示例文件/')entries+=entry('/%E7%A4%BA%E4%BE%8B%E6%96%87%E4%BB%B6/%E5%AD%90%20%E7%9B%AE%E5%BD%95/','子 目录');
res.end('<z:multistatus xmlns:z="DAV:">'+entries+'</z:multistatus>');return}
if(req.method==='PUT'){if(path.endsWith('/offline.md')){res.writeHead(503);res.end();return}const old=files.get(path);if(req.headers['if-none-match']==='*'&&old||req.headers['if-match']&&req.headers['if-match']!==old?.etag){res.writeHead(412);res.end();return}assert.ok(req.headers['if-match']||req.headers['if-none-match']);const etag=old?'"v2"':'"v1"';files.set(path,{body,etag});res.writeHead(old?204:201,{ETag:etag});res.end();return}
if(req.method==='GET'){const item=files.get(path);if(!item){res.writeHead(404);res.end();return}res.writeHead(200,{'Content-Type':'text/markdown; charset=utf-8',ETag:item.etag});res.end(item.body);return}
res.writeHead(405);res.end();});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));try{const child=spawn('dist/native-tests',[`http://127.0.0.1:${server.address().port}`],{stdio:'inherit'});const code=await new Promise(resolve=>child.on('exit',resolve));assert.equal(code,0);assert.equal(redirected,false);assert.equal(transientReads,3);assert.equal(files.get('/文稿/测试 文稿.md').body,'# 版本二');}finally{server.close()}
