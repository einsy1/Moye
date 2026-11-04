// Render only synthetic documents in an isolated browser profile. No real AI requests.
import {chromium} from 'playwright';
import {createServer} from 'node:http';
import {readFile,mkdir} from 'node:fs/promises';
const sample='# 让想法，自然流淌。\n\n一处安静的 Markdown 书写空间。\n\n## 留住今天的灵感\n\n写下 **重要的事**，也给尚未成形的想法留一点空白。\n\n> 慢慢写，让文字找到自己的节奏。\n\n## 一个小小的计划\n\n- [x] 收集灵感\n- [x] 整理文稿\n- [ ] 分享新的故事\n\n## 写作工具箱\n\n| 方式 | 用途 |\n| --- | --- |\n| Markdown | 专注文字 |\n| 实时预览 | 看见排版 |\n| 文稿助手 | 整理表达 |\n\n用 `⌘S` 保存，用文字记录。';
const server=createServer(async(q,r)=>{try{const f=q.url==='/'?'index.html':q.url.slice(1);if(!['index.html','style.css','editor.js','assistant.html','assistant.css','assistant.js'].includes(f)){r.writeHead(404);r.end();return}r.setHeader('Content-Type',f.endsWith('.js')?'text/javascript':f.endsWith('.css')?'text/css':'text/html');r.end(await readFile(f==='editor.js'?'dist/editor.js':'web/'+f))}catch{r.writeHead(404);r.end()}});
await mkdir('docs/screenshots',{recursive:true});await new Promise(r=>server.listen(0,'127.0.0.1',r));
const browser=await chromium.launch();
try{
 const p=await browser.newPage({viewport:{width:1440,height:960},deviceScaleFactor:1});
 await p.addInitScript(text=>{localStorage.setItem('moye.v11.docs',JSON.stringify([{id:'demo',name:'让想法，自然流淌',text,updated:0}]));localStorage.setItem('moye.v11.prefs',JSON.stringify({theme:'light',fontSize:17,lines:false,translucency:0}));},sample);
 const base=`http://127.0.0.1:${server.address().port}`;await p.goto(base);await p.waitForSelector('.cm-content');await p.evaluate(()=>document.fonts.ready);await p.screenshot({path:'docs/screenshots/editor-light.png',animations:'disabled'});
 await p.locator('[data-section=settings]').click();await p.locator('#theme').selectOption('dark');await p.locator('[data-section=documents]').click();await p.screenshot({path:'docs/screenshots/editor-dark.png',animations:'disabled'});
 const a=await browser.newPage({viewport:{width:480,height:1100},deviceScaleFactor:1});
 await a.goto(base+'/assistant.html');await a.locator('#generate').click();await a.evaluate(()=>{receiveAssistant({action:'aiUI',before:'# 写作计划\n先收集灵感，再整理成稿。',name:'写作计划（演示）',scope:'全文'});receiveAssistant({action:'aiAttachments',files:[{id:'demo',name:'写作提纲（示例）.md',text:'先记录，再整理，最后分享。'}]});receiveAssistant({action:'aiResult',requestID:'demo',status:'model',text:'Codex · 演示'});receiveAssistant({action:'aiResult',requestID:'demo',status:'done',text:'# 写作计划\n\n## 收集灵感\n随手记录值得留下的片段。\n\n## 整理成稿\n围绕一个主题，梳理段落与表达。\n\n## 核对与分享\n检查事实、调整措辞，再与读者见面。'});});
 await a.screenshot({path:'docs/screenshots/assistant-light.png',fullPage:true,animations:'disabled'});
 console.log('Rendered 3 screenshots from synthetic data; no AI service contacted.');
}finally{await browser.close();server.close()}
