import {chromium} from 'playwright';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
const server=createServer(async(q,r)=>{try{const p=q.url==='/'?'/index.html':q.url;r.setHeader('Content-Type',p.endsWith('.js')?'text/javascript':p.endsWith('.css')?'text/css':'text/html');r.end(await readFile(p==='/editor.js'?'dist/editor.js':'web'+p))}catch{r.writeHead(404);r.end()}});
await new Promise(r=>server.listen(0,'127.0.0.1',r));const browser=await chromium.launch();
try{
 const page=await browser.newPage({viewport:{width:1280,height:850}});const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.addInitScript(()=>{
  const previous=JSON.parse(localStorage.getItem('test.snapshot')||'null');
  window.moyeBootstrap={snapshot:previous||{docs:[{id:'old',name:'昨日笔记',text:'不要丢失这段记录',path:'/tmp/moye-fixture.md',savedText:'不要丢失这段记录',updated:Date.now()}],activeId:'old'}};
  window.messages=[];window.webkit={messageHandlers:{native:{postMessage(m){window.messages.push(m);if(m.action==='persist'){localStorage.setItem('test.snapshot',JSON.stringify(m.snapshot));queueMicrotask(()=>window.receiveNative({action:'persisted'}))}if(m.action==='openRecent')queueMicrotask(()=>window.receiveNative({action:'opened',path:m.path,name:'昨日笔记.md',text:'不要丢失这段记录',savedText:'不要丢失这段记录'}))}}}};
 });
 await page.goto(`http://127.0.0.1:${server.address().port}`);await page.waitForSelector('.cm-content');
 assert.equal(await page.locator('.cm-content').textContent(),'');assert.equal(await page.locator('#recent-list .doc').count(),1);
 assert.equal(await page.locator('.cm-content').evaluate(el=>el===document.activeElement),true);
 await page.locator('#recent-list .doc').click();assert.equal(await page.locator('.cm-content').innerText(),'不要丢失这段记录');
 await page.locator('.cm-content').fill('尚未保存的新编辑');await page.waitForTimeout(450);
 await page.reload();await page.waitForSelector('.cm-content');assert.equal(await page.locator('.cm-content').textContent(),'');
 assert.ok(await page.evaluate(()=>window.exportSnapshot().docs.some(d=>d.text==='尚未保存的新编辑')));
 const count=await page.evaluate(()=>window.exportSnapshot().docs.length);await page.reload();await page.waitForSelector('.cm-content');assert.equal(await page.evaluate(()=>window.exportSnapshot().docs.length),count);
 await page.locator('#recent-list .doc').click();assert.equal(await page.locator('.cm-content').innerText(),'尚未保存的新编辑');assert.equal(await page.locator('#recent-list .doc').count(),1);
 await page.evaluate(()=>window.receiveNative({action:'draftDeleted',id:'old'}));assert.equal(await page.locator('#recent-list .doc').count(),1);
 await page.locator('#recent-list .doc').click();assert.equal(await page.locator('.cm-content').innerText(),'不要丢失这段记录');
 await page.reload();await page.waitForSelector('.cm-content');await page.waitForTimeout(500);await page.screenshot({path:'dist/startup-history-light.png'});
 await page.locator('[data-section=settings]').click();await page.locator('#theme').selectOption('dark');await page.locator('[data-section=documents]').click();await page.waitForTimeout(500);await page.screenshot({path:'dist/startup-history-dark.png'});
 assert.deepEqual(errors,[]);console.log('PASS: blank launch, editor focus, preserved edits, blank reuse, recent migration/deduplication/reopen and retention after draft deletion');
}finally{await browser.close();server.close()}
