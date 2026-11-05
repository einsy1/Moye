import {chromium} from 'playwright';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
const server=createServer(async(req,res)=>{try{const path=req.url==='/'?'/index.html':req.url;res.setHeader('Content-Type',path.endsWith('.js')?'text/javascript':path.endsWith('.css')?'text/css':'text/html');res.end(await readFile(path==='/editor.js'?'dist/editor.js':'web'+path))}catch{res.writeHead(404);res.end()}});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const browser=await chromium.launch();
try {
  const page=await browser.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.addInitScript(()=>{
    window.__messages=[];
    window.moyeBootstrap={nas:{address:'https://nas.example.invalid',username:'u',folder:'folder',allowHTTP:false}};
    window.webkit={messageHandlers:{native:{postMessage(m){
      window.__messages.push(structuredClone(m));
      if(m.action==='persist')queueMicrotask(()=>window.receiveNative({action:'persisted'}));
      if(m.action==='nasBrowse')queueMicrotask(()=>window.receiveNative({action:'nasListed',requestID:m.requestID,ok:true,folder:m.folder,folders:[],files:[{name:'a.md',path:'folder/a.md'}]}));
    }}}};
  });
  await page.goto(`http://127.0.0.1:${server.address().port}`);await page.waitForSelector('.cm-content');
  await page.evaluate(()=>window.receiveNative({action:'opened',name:'disk.md',path:'/tmp/moye-regression.md',text:'baseline',savedText:'baseline'}));
  await page.locator('.cm-content').click();await page.keyboard.press('End');await page.keyboard.type(' edited');
  await page.locator('#new').click();await page.locator('#doc-list .doc').filter({hasText:'disk'}).click();
  await page.locator('.cm-content').click();await page.keyboard.press('Meta+z');
  assert.equal(await page.locator('.cm-content').innerText(),'baseline','undo survives switching');
  await page.keyboard.press('Meta+Shift+z');assert.equal(await page.locator('.cm-content').innerText(),'baseline edited');
  await page.evaluate(()=>window.nativeCommand('save'));
  assert.equal(await page.evaluate(()=>window.__messages.findLast(m=>m.action==='save').savedText),'baseline');
  await page.evaluate(()=>window.receiveNative({action:'opened',name:'disk.md',path:'/tmp/moye-regression.md',text:'external',savedText:'external'}));
  assert.equal(await page.locator('.cm-content').innerText(),'baseline edited','dirty editor is preserved');
  await page.keyboard.press('Meta+z');
  await page.evaluate(()=>window.receiveNative({action:'opened',name:'disk.md',path:'/tmp/moye-regression.md',text:'external',savedText:'external'}));
  assert.equal(await page.locator('.cm-content').innerText(),'external','clean editor reloads disk changes');

  await page.locator('.cm-content').fill('`==literal==`\n\n```\na\n~~~\n###inside code\n```\n\n###outside');
  await page.waitForFunction(()=>document.querySelector('#preview h3')?.textContent==='outside');
  assert.equal(await page.locator('#preview code').first().innerText(),'==literal==');
  assert.match(await page.locator('#preview pre').innerText(),/###inside code/);
  assert.equal(await page.locator('.outline-item').count(),1);
  assert.equal(await page.locator('.cm-md-h3').count(),1);
  assert.equal(await page.locator('.cm-md-mark').count(),0);

  await page.locator('.cm-content').fill('before `one\n==literal==` after');
  await page.waitForFunction(()=>document.querySelector('#preview code')?.textContent==='one ==literal==');
  assert.equal(await page.locator('.cm-md-mark').count(),0);

  const openFile=async()=>{
    await page.evaluate(()=>window.nativeCommand('nasOpen'));
    await page.locator('.nas-file').click();
    return page.evaluate(()=>window.__messages.findLast(m=>m.action==='nasOpenFile').requestID);
  };
  const response=id=>({action:'nasOpened',requestID:id,ok:true,name:'a.md',text:'remote text',remote:{name:'a.md',path:'folder/a.md',folder:'folder',fingerprint:'https://nas.example.invalid|u|folder',etag:'"v1"'}});
  const count=await page.evaluate(()=>window.exportSnapshot().docs.length);
  const cancelled=await openFile();await page.locator('#nas-browser-cancel').click();
  await page.evaluate(data=>window.receiveNative(data),response(cancelled));
  assert.equal(await page.evaluate(()=>window.exportSnapshot().docs.length),count,'cancelled GET does not open');
  const latest=await openFile();await page.evaluate(data=>window.receiveNative(data),response(cancelled));
  assert.equal(await page.locator('#nas-browser').evaluate(e=>e.open),true,'stale GET does not close newer session');
  await page.evaluate(data=>window.receiveNative(data),response(latest));
  assert.equal(await page.locator('#title').innerText(),'a');
  const id=await page.evaluate(()=>window.exportSnapshot().activeId);
  // Exercise migration from an old upload acknowledgment without a path.
  await page.evaluate(id=>window.receiveNative({action:'nasUploaded',id,remote:{name:'a.md',folder:'folder',fingerprint:'https://nas.example.invalid|u|folder',etag:'"v2"'},savedText:'remote text'}),id);
  const again=await openFile();await page.evaluate(data=>window.receiveNative(data),response(again));
  assert.equal(await page.evaluate(()=>window.exportSnapshot().docs.filter(d=>d.nasRemote).length),1,'remote identity survives upload/reopen');


  await page.evaluate(()=>window.beginAssistant({instruction:'整理格式'}));
  const aiRequest=await page.evaluate(()=>window.__messages.findLast(m=>m.action==='aiRequest'));
  const original=await page.evaluate(()=>window.exportSnapshot().docs.find(d=>d.id===window.exportSnapshot().activeId).text);
  await page.evaluate(r=>window.receiveNative({action:'aiResult',requestID:r.requestID,status:'done',text:'AI revised'}),aiRequest);
  await page.evaluate(()=>document.querySelector('#ai-apply').click());
  assert.equal(await page.locator('.cm-content').innerText(),'AI revised');
  assert.ok(await page.evaluate(t=>window.exportSnapshot().docs.some(d=>d.name.includes('AI 修改前')&&d.text===t),original));
  await page.evaluate(()=>window.beginAssistant({instruction:'整理格式'}));
  const stale=await page.evaluate(()=>window.__messages.findLast(m=>m.action==='aiRequest'));
  await page.evaluate(()=>window.receiveNative({action:'opened',name:'different.md',text:'other document'}));
  await page.evaluate(r=>window.receiveNative({action:'aiResult',requestID:r.requestID,status:'done',text:'must not apply here'}),stale);
  await page.evaluate(()=>document.querySelector('#ai-apply').click());assert.equal(await page.locator('.cm-content').innerText(),'other document');
  await page.evaluate(()=>document.querySelector('#ai-close').click());
  const large=Array.from({length:6000},(_,i)=>`plain line ${i}`).join('\n');
  const start=Date.now();await page.evaluate(text=>window.receiveNative({action:'opened',name:'6000行回归.md',text}),large);const opened=Date.now();await page.locator('.cm-line').first().click();await page.keyboard.type('X');await page.waitForTimeout(200);
  assert.equal(await page.evaluate(()=>window.exportSnapshot().docs.find(d=>d.id===window.exportSnapshot().activeId).text.length),large.length+1);
  console.log(`PASS: undo/redo across documents, local reload/save baseline, code-safe preview/outline, cancelled/stale NAS GET, stable remote identity; 6000-line file opened in ${opened-start}ms, then typed one character in ${Date.now()-opened}ms (not a full performance benchmark)`);
  assert.deepEqual(errors,[]);
} finally {await browser.close();server.close()}
