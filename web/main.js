import {EditorState, Compartment, RangeSetBuilder, Prec} from '@codemirror/state';
import {EditorView, ViewPlugin, Decoration, keymap, lineNumbers, highlightActiveLine, drawSelection} from '@codemirror/view';
import {defaultKeymap, history, isolateHistory, historyKeymap, indentWithTab} from '@codemirror/commands';
import {closeBrackets, closeBracketsKeymap} from '@codemirror/autocomplete';
import {markdown, markdownLanguage} from '@codemirror/lang-markdown';
import {syntaxHighlighting, HighlightStyle, bracketMatching, LanguageDescription, syntaxTree} from '@codemirror/language';
import {javascript} from '@codemirror/lang-javascript';
import {html as htmlLang} from '@codemirror/lang-html';
import {css as cssLang} from '@codemirror/lang-css';
import {search, searchKeymap, openSearchPanel} from '@codemirror/search';
import {tags} from '@lezer/highlight';
import {renderMarkdown} from './markdown.js';
import DOMPurify from 'dompurify';
import {createIcons, icons} from 'lucide';
const $=s=>document.querySelector(s), $$=s=>[...document.querySelectorAll(s)];
const iconify=()=>createIcons({icons,attrs:{'aria-hidden':'true'}});
const native = !!window.webkit?.messageHandlers?.native;
const bootstrap = window.moyeBootstrap || {};
let nasConfig = bootstrap.nas || {}, uploadInFlight = false, sessionMode = null;
let prefs={theme:'auto',fontSize:16,fontFamily:'mono',lines:true,ruled:false,scrollSync:true,translucency:60,minimal:false,spell:true,motion:false};
let docs=[],activeId,mode='split',currentSection='documents',saveTimer,toastTimer,renderTimer;
const editorStates=new Map(),scrollPositions=new Map();
try{Object.assign(prefs,JSON.parse(localStorage.getItem('moye.v11.prefs') || localStorage.getItem('moye.prefs')||'{}'));docs=JSON.parse(localStorage.getItem('moye.v11.docs') || localStorage.getItem('moye.docs')||'[]');if(!Array.isArray(docs))docs=[];docs=docs.filter(d=>typeof d.id==='string'&&typeof d.text==='string'&&typeof d.name==='string');activeId=localStorage.getItem('moye.v11.active') || localStorage.getItem('moye.active');}catch{}
if (Array.isArray(bootstrap.snapshot?.docs)) { docs=bootstrap.snapshot.docs;activeId=bootstrap.snapshot.activeId;Object.assign(prefs,bootstrap.snapshot.prefs||{}); }
if(!docs.length)docs=[{id:crypto.randomUUID(),name:'未命名文稿',text:'',updated:Date.now()}];
if(!docs.some(d=>d.id===activeId))activeId=docs[0].id;
const current=()=>docs.find(d=>d.id===activeId);
const lineConfig=new Compartment(), spellConfig=new Compartment();
const codeLanguages=[
  LanguageDescription.of({name:'javascript',alias:['js','mjs','cjs','ts','typescript','json','jsx','tsx'],support:javascript({jsx:true,typescript:true})}),
  LanguageDescription.of({name:'html',alias:['htm','xml','svg'],support:htmlLang()}),
  LanguageDescription.of({name:'css',alias:['scss','less'],support:cssLang()})
];
const highlight=HighlightStyle.define([
  {tag:tags.heading1,color:'var(--md-heading)',fontWeight:'700'},
  {tag:tags.heading2,color:'var(--md-heading)',fontWeight:'650'},
  {tag:[tags.heading,tags.heading3,tags.heading4,tags.heading5,tags.heading6],color:'var(--md-heading)',fontWeight:'600'},
  {tag:[tags.processingInstruction,tags.meta],color:'var(--md-marker)'},
  {tag:tags.strong,fontWeight:'700',color:'var(--md-strong)'},
  {tag:tags.emphasis,fontStyle:'italic',color:'var(--md-em)'},
  {tag:[tags.url,tags.link],color:'var(--md-link)',textDecoration:'underline'},
  {tag:tags.monospace,color:'var(--md-code)',backgroundColor:'var(--md-code-bg)',borderRadius:'4px'},
  {tag:[tags.keyword,tags.operatorKeyword],color:'var(--md-em)',fontWeight:'600'},
  {tag:[tags.string,tags.special(tags.string)],color:'var(--md-code)'},
  {tag:[tags.number,tags.bool,tags.atom],color:'var(--md-strong)'},
  {tag:[tags.comment,tags.lineComment,tags.blockComment],color:'var(--muted)',fontStyle:'italic'},
  {tag:tags.quote,color:'var(--md-quote)',fontStyle:'italic'},
  {tag:tags.list,color:'var(--md-marker)'},
  {tag:tags.strikethrough,textDecoration:'line-through',color:'var(--muted)'}
]);
function codeAt(state, pos) {
  let node=syntaxTree(state).resolveInner(pos,1);
  for(;node;node=node.parent)if(node.name==='FencedCode'||node.name==='CodeBlock')return true;
  return false;
}
function buildMarkdownDecorations(v){
  const b=new RangeSetBuilder(),doc=v.state.doc;
  let lastLine=0;
  for(const range of v.visibleRanges)for(let i=doc.lineAt(range.from).number,end=Math.min(doc.lineAt(range.to).number,i+250);i<=end;i++){
    if(i<=lastLine)continue;lastLine=i;
    const line=doc.line(i),t=line.text;
    if(codeAt(v.state,line.from+Math.min(t.length,1))){
      b.add(line.from,line.from,Decoration.line({class:'cm-md-codeblock'+(/^ {0,3}(`{3,}|~{3,})/.test(t)?' cm-md-codefence':'')}));continue;
    }
    const hm=t.match(/^ {0,3}(#{1,6})(?:\s+|(?=[^\s#]))(.+)/);
    if(hm)b.add(line.from,line.from,Decoration.line({class:`cm-md-heading cm-md-h${Math.min(4,hm[1].length)}`}));
    else if(/^ {0,3}>+/.test(t))b.add(line.from,line.from,Decoration.line({class:'cm-md-quote'}));
    else if(/^ {0,3}(?:---+|\*\*\*+|___+)\s*$/.test(t))b.add(line.from,line.from,Decoration.line({class:'cm-md-hr'}));
    const tokens=[],codeRanges=[];
    syntaxTree(v.state).iterate({from:line.from,to:line.to,enter(node){if(node.name==='InlineCode'){codeRanges.push([node.from,node.to]);const from=Math.max(node.from,line.from),to=Math.min(node.to,line.to);if(to>from)tokens.push({from,to,cls:'cm-md-inline-code'});return false}}});
    for(const [re,cls] of [[/==[^=\n]+==/g,'cm-md-mark'],[/\*\*[^*\n]+\*\*/g,'cm-md-bold']])for(const m of t.matchAll(re)){
      const from=line.from+m.index,to=from+m[0].length;
      if(!codeRanges.some(([a,z])=>from<z&&to>a))tokens.push({from,to,cls});
    }
    tokens.sort((a,c)=>a.from-c.from||a.to-c.to);let lastEnd=-1;
    for(const tk of tokens)if(tk.from>=lastEnd){b.add(tk.from,tk.to,Decoration.mark({class:tk.cls}));lastEnd=tk.to}
  }
  return b.finish();
}
const markdownDecorations=ViewPlugin.fromClass(class{
  constructor(v){this.decorations=buildMarkdownDecorations(v)}
  update(u){if(u.docChanged||u.viewportChanged||syntaxTree(u.startState)!==syntaxTree(u.state))this.decorations=buildMarkdownDecorations(u.view)}
},{decorations:v=>v.decorations});
const markdownPairs=EditorView.inputHandler.of((v,from,to,text)=>{
  if(text.length!==1)return false;
  const pairs={'*':'*','~':'~','`':'`','=':'=','(':')','[':']','"':'"',"'":"'",'（':'）','【':'】','「':'」','『':'』','“':'”'};
  if(from<to&&pairs[text]){
    const sel=v.state.sliceDoc(from,to);
    v.dispatch({changes:{from,to,insert:text+sel+pairs[text]},selection:{anchor:from+1,head:to+1}});
    return true;
  }
  if(from===to&&['*','~','`','='].includes(text)){
    const doc=v.state.doc,b1=from>0?doc.sliceString(from-1,from):'',b2=from>1?doc.sliceString(from-2,from-1):'',a1=doc.sliceString(from,from+1),a2=doc.sliceString(from+1,from+2);
    const boundary=!b2||/[\s([{（【「『"']/.test(b2);
    if(text==='`'&&b1==='`'&&b2==='`'&&a1==='`'&&a2==='`'){
      v.dispatch({changes:{from:from-2,to:from+2,insert:'```\n\n```'},selection:{anchor:from+2}});return true;
    }
    if(b1===text&&a1===text&&boundary&&a2!==text){
      v.dispatch({changes:{from,to,insert:text+text},selection:{anchor:from+1}});return true;
    }
    if(a1===text){v.dispatch({selection:{anchor:from+1}});return true}
    if((text==='*'||text==='`')&&(!b1||/[\s([{（【「『"']/.test(b1))&&!/[\w\u4e00-\u9fff]/.test(a1)){
      v.dispatch({changes:{from,to,insert:text+text},selection:{anchor:from+1}});return true;
    }
    if((text==='~'||text==='=')&&b1===text&&boundary&&a1!==text){
      v.dispatch({changes:{from,to,insert:text+text+text},selection:{anchor:from+1}});return true;
    }
  }
  return false;
});
function editorState(text){return EditorState.create({doc:text,extensions:[history(),drawSelection(),highlightActiveLine(),closeBrackets(),markdownPairs,Prec.highest(keymap.of([{key:'Mod-b',run:()=>{wrap('**');return true}},{key:'Mod-i',run:()=>{wrap('*');return true}},{key:'Mod-k',run:()=>{insertLink();return true}},{key:'Enter',run:v=>{const s=v.state.selection.main;if(!s.empty)return false;const line=v.state.doc.lineAt(s.from);if(/^\s*>+\s*$/.test(line.text)){v.dispatch({changes:{from:line.from,to:line.to,insert:''},selection:{anchor:line.from}});return true}return false}},{key:'Backspace',run:v=>{const s=v.state.selection.main;if(!s.empty||s.from===0)return false;const b=v.state.doc.sliceString(s.from-1,s.from),a=v.state.doc.sliceString(s.from,s.from+1);if(b===a&&['*','~','`','='].includes(b)){v.dispatch({changes:{from:s.from-1,to:s.from+1}});return true}return false}}])),markdown({base:markdownLanguage,codeLanguages}),syntaxHighlighting(highlight),markdownDecorations,bracketMatching(),search({top:true}),EditorView.lineWrapping,lineConfig.of(prefs.lines?lineNumbers():[]),spellConfig.of(EditorView.contentAttributes.of({spellcheck:String(prefs.spell),'aria-label':'Markdown 编辑器'})),keymap.of([...closeBracketsKeymap,...defaultKeymap,...historyKeymap,...searchKeymap,indentWithTab]),EditorView.updateListener.of(update=>{if(update.docChanged){current().text=update.state.doc.toString();current().updated=Date.now();$('#save-state').textContent='正在保存草稿…';clearTimeout(saveTimer);saveTimer=setTimeout(persist,350);clearTimeout(renderTimer);renderTimer=setTimeout(()=>{renderPreview();renderOutline();updateStats()},100)}if(update.selectionSet||update.docChanged)updateCursor()})]})}
const view=new EditorView({state:editorState(current().text),parent:$('#editor')});
function toast(message){$('#toast').textContent=message;$('#toast').classList.add('visible');clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('#toast').classList.remove('visible'),2400)}
window.exportSnapshot=()=>({version:2,docs,activeId,prefs});
function refreshSaveState(){const doc=current();let state=doc.pendingUpload?'NAS 待上传 · 本机已备份':doc.path?(doc.text===doc.savedText?'文件已保存':'文件有修改 · 草稿已备份'):doc.nasRemote?(doc.text===doc.nasSavedText?'NAS 已上传':'NAS 有修改 · 草稿已备份'):'草稿已备份';$('#save-state').textContent=state;$('#status').textContent=state;$('#pending-count').textContent=docs.filter(d=>d.pendingUpload).length;}
function persist(){if(native){bridge('persist',{snapshot:window.exportSnapshot()});}else{try{localStorage.setItem('moye.v11.docs',JSON.stringify(docs));localStorage.setItem('moye.v11.active',activeId);refreshSaveState()}catch{$('#save-state').textContent='草稿保存失败';$('#status').textContent='请使用 ⌘S 保存文件';toast('草稿保存失败，请保存到本地文件')}}renderDocuments()}

function renderDocuments(){const list=$('#doc-list');list.replaceChildren();for(const doc of docs){let b=document.createElement('button');b.className='doc'+(doc.id===activeId?' active':'');b.innerHTML='<i data-lucide="file-text"></i><div><strong></strong><small></small></div>';b.querySelector('strong').textContent=doc.name;b.querySelector('small').textContent=doc.pendingUpload?'NAS 待上传':doc.nasRemote?'NAS 文稿':doc.path?'本地文件 · '+new Date(doc.updated).toLocaleDateString('zh-CN',{month:'short',day:'numeric'}):'本地草稿';b.onclick=()=>switchDoc(doc.id);list.append(b)}$('#doc-count').textContent=docs.length;iconify()}
function switchDoc(id){
  if(id===activeId){renderAll();persist();return}
  persist();editorStates.set(activeId,view.state);scrollPositions.set(activeId,view.scrollDOM.scrollTop);
  activeId=id;
  const cached=editorStates.get(id);
  view.setState(cached&&cached.doc.toString()===current().text?cached:editorState(current().text));
  // A cached state may predate preference changes made in another document.
  view.dispatch({effects:[lineConfig.reconfigure(prefs.lines?lineNumbers():[]),spellConfig.reconfigure(EditorView.contentAttributes.of({spellcheck:String(prefs.spell),'aria-label':'Markdown 编辑器'}))]});
  view.scrollDOM.scrollTop=scrollPositions.get(id)||0;renderAll();persist();
}
function renderPreview(){const html=renderMarkdown(current().text);$('#preview').innerHTML=DOMPurify.sanitize(html,{FORBID_TAGS:['iframe','style','form','video','audio'],FORBID_ATTR:['srcset']});$('#preview').querySelectorAll('img').forEach(img=>{const src=img.getAttribute('src')||'';if(!src.startsWith('data:image/')&&!src.startsWith('file:')){img.removeAttribute('src');img.title='远程图片已阻止，避免自动网络请求'}});$('#preview').querySelectorAll('a').forEach(a=>{a.onclick=e=>{e.preventDefault();const href=a.getAttribute('href');if(/^https?:\/\//i.test(href||''))bridge('link',{url:href})}})}
function renderOutline(){
  const list=$('#outline-list');list.replaceChildren();
  const codeRanges=[];
  syntaxTree(view.state).iterate({enter(node){if(node.name==='FencedCode'||node.name==='CodeBlock'){codeRanges.push([node.from,node.to]);return false}}});
  let offset=0,rangeIndex=0;
  for(const line of current().text.split('\n')){
    while(rangeIndex<codeRanges.length&&codeRanges[rangeIndex][1]<=offset)rangeIndex++;
    const inCode=rangeIndex<codeRanges.length&&codeRanges[rangeIndex][0]<=offset+Math.min(line.length,1);
    const m=!inCode&&line.match(/^ {0,3}(#{1,6})(?:\s+|(?=[^\s#]))(.+)/);
    if(m){const button=document.createElement('button');button.className='outline-item';button.style.paddingLeft=(10+(m[1].length-1)*12)+'px';button.textContent=m[2].replace(/[*_`~]/g,'');const pos=offset;button.onclick=()=>{if(mode==='preview')setMode('edit');view.dispatch({selection:{anchor:pos},effects:EditorView.scrollIntoView(pos,{y:'start'})});view.focus()};list.append(button)}
    offset+=line.length+1;
  }
  if(!list.children.length)list.innerHTML='<p class="outline-empty">使用 # 标题组织文稿，大纲会在这里自动出现。</p>';
}
function updateStats(){const text=current().text;const cjk=(text.match(/[\u3400-\u9fff]/g)||[]).length;const words=(text.replace(/[\u3400-\u9fff]/g,' ').match(/[\p{L}\p{N}]+/gu)||[]).length;$('#words').textContent=(cjk+words).toLocaleString()+' 字';$('#reading').textContent=Math.max(1,Math.ceil((cjk+words)/300))+' 分钟阅读'}
function updateCursor(){let pos=view.state.selection.main.head,line=view.state.doc.lineAt(pos);$('#cursor').textContent=`行 ${line.number}，列 ${pos-line.from+1}`}
function renderAll(){clearTimeout(renderTimer);renderDocuments();renderPreview();renderOutline();updateStats();updateCursor();$('#title').textContent=current().name}
function newDoc(){persist();let doc={id:crypto.randomUUID(),name:'未命名文稿',text:'',updated:Date.now()};docs.unshift(doc);switchDoc(doc.id);view.focus()}
function wrap(mark){const sel=view.state.selection.main;let text=view.state.sliceDoc(sel.from,sel.to)||'文字';view.dispatch({changes:{from:sel.from,to:sel.to,insert:mark+text+mark},selection:{anchor:sel.from+mark.length,head:sel.from+mark.length+text.length}});view.focus()}
function insert(text){const sel=view.state.selection.main;view.dispatch({changes:{from:sel.from,to:sel.to,insert:text},selection:{anchor:sel.from+text.length}});view.focus()}
function insertLink(){const sel=view.state.selection.main;let text=view.state.sliceDoc(sel.from,sel.to)||'链接文字';insert(`[${text}](https://example.com)`)}
function prefix(text){const sel=view.state.selection.main,first=view.state.doc.lineAt(sel.from),last=view.state.doc.lineAt(sel.to);let changes=[];for(let n=first.number;n<=last.number;n++)changes.push({from:view.state.doc.line(n).from,insert:text});view.dispatch({changes});view.focus()}
function updateVisibility(){const hidden=['minimal','focus','hide-sidebar'].some(c=>document.body.classList.contains(c));$('.sidebar').inert=hidden;$('.editor-pane').inert=mode==='preview';$('.preview-pane').inert=mode==='edit'||document.body.classList.contains('minimal')}
function setMode(next){mode=next;$('#workspace').className='workspace '+mode;$$('[data-mode]').forEach(b=>b.classList.toggle('active',b.dataset.mode===mode));const btn=$(`[data-mode="${mode}"]`);$('.segment-thumb').style.transform=`translateX(${btn.offsetLeft-3}px)`;updateVisibility();setTimeout(()=>view.requestMeasure(),350)}
function bridge(action,data={}){if(window.webkit?.messageHandlers?.native){window.webkit.messageHandlers.native.postMessage({action,id:activeId,...data})}else if(action==='open'){let input=document.createElement('input');input.type='file';input.accept='.md,.markdown,.txt,.mdown';input.onchange=async()=>{const f=input.files[0];if(f&&f.size>10_000_000){toast('文稿超过 10 MB，请拆分后打开');return}if(f)window.receiveNative({action:'opened',name:f.name,text:await f.text()})};input.click()}else if(['save','saveAs','exportHTML'].includes(action)){let blob=new Blob([data.text],{type:action==='exportHTML'?'text/html':'text/markdown'}),a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download=data.name;a.click();setTimeout(()=>URL.revokeObjectURL(a.href),1000);toast('已导出文件')}else if(action==='print')window.print();else if(action==='link')window.open(data.url,'_blank','noopener')}
function save(as=false){if(!as&&current().nasRemote&&!current().path){openNASUpload();return}persist();bridge(as?'saveAs':'save',{name:current().name.replace(/\.md$/i,'')+'.md',text:current().text,path:current().path||null,savedText:current().savedText})}
function command(action){$('#menu').hidden=true;if(action==='minimal')toggleMinimal();else if(action==='nas')openNASUpload();else if(action==='nasOpen')openNASBrowserForRead();else if(action==='new')newDoc();else if(action==='open')bridge('open');else if(action==='save')save();else if(action==='saveAs')save(true);else if(action==='find')openSearchPanel(view);else if(action==='focus')toggleFocus();else if(action==='exportHTML'){const safe=DOMPurify.sanitize(renderMarkdown(current().text));bridge('exportHTML',{name:current().name+'.html',text:'<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><style>body{max-width:760px;margin:60px auto;padding:24px;font:16px/1.8 system-ui}pre{padding:20px;background:#f5f5f7;overflow:auto}img{max-width:100%}table{border-collapse:collapse}td,th{border:1px solid #ddd;padding:8px}blockquote{border-left:3px solid #ddd;padding-left:20px}</style>'+safe})}else if(action==='print')bridge('print');else if(action==='rename'){$('#rename-input').value=current().name;$('#rename-dialog').showModal();$('#rename-input').select()}else if(action==='delete'){if(!confirm('删除「'+current().name+'」的草稿？已保存的本机和 NAS 文件不受影响。'))return;if(native){bridge('deleteDraft',{doc:current()});return}removeDraft(activeId)}}
function removeDraft(id){clearTimeout(saveTimer);editorStates.set(activeId,view.state);scrollPositions.set(activeId,view.scrollDOM.scrollTop);editorStates.delete(id);scrollPositions.delete(id);docs=docs.filter(d=>d.id!==id);if(!docs.length)docs=[{id:crypto.randomUUID(),name:'未命名文稿',text:'',updated:Date.now()}];if(!docs.some(d=>d.id===activeId))activeId=docs[0].id;const cached=editorStates.get(activeId);view.setState(cached&&cached.doc.toString()===current().text?cached:editorState(current().text));renderAll();persist()}
window.nativeCommand=command;
window.receiveNative=data=>{
if(data.action==='aiResult'){receiveAI(data);return}
if(data.action==='draftDeleted'){removeDraft(data.id);return}
if(data.action==='persisted'){refreshSaveState();return}
if(data.action==='accessibility'){document.body.classList.toggle('reduce-transparency',data.reduceTransparency);return}
if(data.action==='nasListed'){receiveFolders(data);return}
if(data.action==='nasOpened'){receiveNASFile(data);return}
if(data.action==='nasConfigResult'){$('#nas-result').textContent=data.message;$('#nas-test').disabled=false;$('#nas-save').disabled=false;$('#nas-dot').textContent=data.ok?'最近测试成功':'连接失败';if(data.saved){nasConfig=data.config;$('#nas-password').value='';$('#nas-dot').textContent='最近测试成功';}return}
if(data.action==='nasUploaded'){uploadInFlight=false;const doc=docs.find(d=>d.id===data.id);if(doc){doc.nasRemote={...data.remote,path:remotePath(data.remote)};doc.nasSavedText=data.savedText;delete doc.pendingUpload;persist()}toast('文稿已保存到 NAS');return}
if(data.action==='nasFailed'){uploadInFlight=false;const doc=docs.find(d=>d.id===data.id);if(doc&&(data.pending||doc.pendingUpload)){doc.pendingUpload={...(data.pending||doc.pendingUpload),retryable:data.retryable,message:data.message};persist()}$('#nas-result').textContent=data.message;toast(data.message);return}
if(data.action==='opened'){const existing=data.path&&docs.find(d=>d.path===data.path);if(existing){
  if(existing.text===existing.savedText&&existing.text!==data.text){existing.text=data.text;existing.savedText=data.savedText??data.text;editorStates.delete(existing.id);if(existing.id===activeId)view.setState(editorState(existing.text))}
  else if(existing.savedText!==data.text){toast('磁盘文件已变化，已保留你的编辑；保存时会检查冲突。')}
  switchDoc(existing.id);return
}let doc={id:crypto.randomUUID(),name:data.name.replace(/\.(md|markdown|txt|mdown)$/i,''),text:data.text,path:data.path,savedText:data.savedText??data.text,updated:Date.now()};docs.unshift(doc);switchDoc(doc.id)}else if(data.action==='saved'){const doc=docs.find(d=>d.id===data.id);if(doc){doc.path=data.path;doc.name=data.name.replace(/\.md$/i,'');doc.savedText=data.savedText;persist();$('#title').textContent=current().name}toast('已保存到本地文件')}else if(data.action==='error')toast(data.message)};
function toggleMinimal(force){const next=force??!document.body.classList.contains('minimal');if(next){sessionMode=mode;setMode('edit');document.body.classList.remove('focus');}else if(sessionMode){setMode(sessionMode);sessionMode=null}document.body.classList.toggle('minimal',next);updateVisibility();prefs.minimal=next;$('#minimal-setting').checked=next;$('#minimal').setAttribute('aria-pressed',String(next));persist();setTimeout(()=>view.requestMeasure(),360);view.focus()}
function toggleFocus(){document.body.classList.toggle('focus');updateVisibility();$('#focus').classList.toggle('active',document.body.classList.contains('focus'));view.requestMeasure()}
$$('[data-section]').forEach((b,i)=>b.onclick=()=>{currentSection=b.dataset.section;$$('[data-section]').forEach(x=>x.classList.toggle('active',x===b));$('.nav-pill').style.transform=`translateY(${i*40}px)`;$$('.section').forEach(s=>s.classList.toggle('active',s.id===currentSection))});
$$('[data-mode]').forEach(b=>b.onclick=()=>setMode(b.dataset.mode));
$$('[data-wrap]').forEach(b=>b.onclick=()=>wrap(b.dataset.wrap));$$('[data-prefix]').forEach(b=>b.onclick=()=>prefix(b.dataset.prefix));
$$('[data-action]').forEach(b=>b.onclick=()=>{if(b.dataset.action==='link')insertLink();if(b.dataset.action==='code')insert('\n```javascript\n// 在这里写下代码\n```\n');if(b.dataset.action==='table')insert('\n| 标题 | 内容 |\n| --- | --- |\n| 项目 | 说明 |\n')});
$$('[data-command]').forEach(b=>b.onclick=()=>command(b.dataset.command));
$('#new').onclick=newDoc;$('#open').onclick=()=>bridge('open');$('#search').onclick=()=>{openSearchPanel(view)};$('#focus').onclick=toggleFocus;$('#minimal').onclick=()=>toggleMinimal();
$('#sidebar-toggle').onclick=()=>{document.body.classList.toggle('hide-sidebar');updateVisibility();setTimeout(()=>view.requestMeasure(),350)};
$('#more').onclick=e=>{e.stopPropagation();$('#menu').hidden=!$('#menu').hidden};document.addEventListener('click',e=>{if(!$('#menu').contains(e.target))$('#menu').hidden=true});
$('#rename-dialog').addEventListener('close',()=>{if($('#rename-dialog').returnValue==='ok'&&$('#rename-input').value.trim()){current().name=$('#rename-input').value.trim();$('#title').textContent=current().name;persist()}});
const darkMedia=matchMedia('(prefers-color-scheme: dark)');
const editorFonts={mono:'"SF Mono",Menlo,"PingFang SC",monospace',system:'-apple-system,"PingFang SC",sans-serif',pingfang:'"PingFang SC",sans-serif',songti:'"Songti SC",serif',menlo:'Menlo,"PingFang SC",monospace'};
$('#font-family').onchange=e=>{prefs.fontFamily=e.target.value;applyPrefs();view.requestMeasure()};
function applyPrefs(){if(!editorFonts[prefs.fontFamily])prefs.fontFamily='mono';document.documentElement.style.setProperty('--editor-font',editorFonts[prefs.fontFamily]);$('#font-family').value=prefs.fontFamily;if(native)bridge('appearance',{theme:prefs.theme});document.documentElement.dataset.theme=prefs.theme==='auto'?(darkMedia.matches?'dark':'light'):prefs.theme;document.documentElement.style.setProperty('--editor-size',prefs.fontSize+'px');document.documentElement.style.setProperty('--paper-opacity',String(1-prefs.translucency/100));document.body.classList.toggle('ruled',prefs.ruled);$('#ruled-lines').checked=prefs.ruled;$('#scroll-sync').checked=prefs.scrollSync!==false;$('#translucency').value=prefs.translucency;$('#translucency-value').textContent=prefs.translucency+'%';$('#minimal-setting').checked=prefs.minimal;document.body.classList.toggle('reduce-motion',prefs.motion);$('#theme').value=prefs.theme;$('#font-size').value=prefs.fontSize;$('#font-value').textContent=prefs.fontSize;$('#line-numbers').checked=prefs.lines;$('#spellcheck').checked=prefs.spell;$('#reduce-motion').checked=prefs.motion;view.dispatch({effects:[lineConfig.reconfigure(prefs.lines?lineNumbers():[]),spellConfig.reconfigure(EditorView.contentAttributes.of({spellcheck:String(prefs.spell),'aria-label':'Markdown 编辑器'}))]});try{localStorage.setItem('moye.v11.prefs',JSON.stringify(prefs));if(native)bridge('persist',{snapshot:window.exportSnapshot()})}catch{}}
$('#ruled-lines').onchange=e=>{prefs.ruled=e.target.checked;applyPrefs()};$('#scroll-sync').onchange=e=>{prefs.scrollSync=e.target.checked;applyPrefs()};$('#translucency').oninput=e=>{prefs.translucency=+e.target.value;applyPrefs()};$('#minimal-setting').onchange=e=>toggleMinimal(e.target.checked);
$('#theme').onchange=e=>{prefs.theme=e.target.value;applyPrefs()};$('#font-size').oninput=e=>{prefs.fontSize=+e.target.value;applyPrefs()};$('#line-numbers').onchange=e=>{prefs.lines=e.target.checked;applyPrefs()};$('#spellcheck').onchange=e=>{prefs.spell=e.target.checked;applyPrefs()};$('#reduce-motion').onchange=e=>{prefs.motion=e.target.checked;applyPrefs()};darkMedia.addEventListener('change',applyPrefs);
document.addEventListener('keydown',e=>{if(e.key==='Escape'&&!document.querySelector('dialog[open]')){if(document.body.classList.contains('minimal'))toggleMinimal(false);if(document.body.classList.contains('focus'))toggleFocus();$('#menu').hidden=true}if(!(e.metaKey||e.ctrlKey))return;const k=e.key.toLowerCase();if(['s','o','n'].includes(k)){e.preventDefault();command(k==='s'?(e.shiftKey?'saveAs':'save'):k==='o'?(e.shiftKey?'nasOpen':'open'):'new')}if(k==='m'&&e.shiftKey){e.preventDefault();toggleMinimal()}if(k==='f'&&e.shiftKey){e.preventDefault();toggleFocus()}});
window.addEventListener('beforeunload',persist);window.addEventListener('resize',()=>setMode(mode));
let syncingScroll=null,syncScrollTimer=0;
function syncScroll(source,target){if(mode!=='split'||prefs.scrollSync===false)return;if(syncingScroll&&syncingScroll!==source)return;syncingScroll=source;clearTimeout(syncScrollTimer);syncScrollTimer=setTimeout(()=>{syncingScroll=null},80);const maxSource=source.scrollHeight-source.clientHeight,maxTarget=target.scrollHeight-target.clientHeight;if(maxSource<=0||maxTarget<=0){target.scrollTop=0;return}target.scrollTop=(source.scrollTop/maxSource)*maxTarget}
view.scrollDOM.addEventListener('scroll',()=>syncScroll(view.scrollDOM,$('#preview')),{passive:true});
$('#preview').addEventListener('scroll',()=>syncScroll($('#preview'),view.scrollDOM),{passive:true});
window.addEventListener('dragover',e=>{if(e.dataTransfer?.types?.includes('Files')){e.preventDefault();e.dataTransfer.dropEffect='copy'}});
window.addEventListener('drop',async e=>{if(!e.dataTransfer?.files?.length)return;e.preventDefault();for(const file of e.dataTransfer.files){if(file.size>10_000_000){toast('文稿超过 10 MB，请拆分后打开');continue}if(/\.(md|markdown|mdown|txt)$/i.test(file.name)||file.type==='text/markdown'||file.type==='text/plain'){window.receiveNative({action:'opened',name:file.name,text:await file.text()})}else{toast('仅支持拖入 Markdown 或纯文本文件')}}});
function configFingerprint(){return nasConfig.address+'|'+nasConfig.username+'|'+nasConfig.folder}
function configureNAS(save){if(!native){toast('请在 macOS 应用内配置 NAS');return}if(!$('#nas-form').reportValidity())return;$('#nas-test').disabled=true;$('#nas-save').disabled=true;$('#nas-result').textContent='正在连接 NAS…';bridge(save?'nasSave':'nasTest',{config:{address:$('#nas-address').value.trim().replace(/\/+$/,''),username:$('#nas-user').value.trim(),folder:$('#nas-folder').value.trim(),allowHTTP:$('#nas-http').checked},password:$('#nas-password').value});}
$('#nas-test').onclick=()=>configureNAS(false);$('#nas-form').onsubmit=e=>{e.preventDefault();configureNAS(true)};
function openNASUpload(){if(!nasConfig.address){if(document.body.classList.contains('minimal'))toggleMinimal(false);document.body.classList.remove('hide-sidebar','focus');$('[data-section="nas"]').click();updateVisibility();toast('请先填写 NAS 的 WebDAV 配置');return}const doc=current(),same=doc.nasRemote?.fingerprint===configFingerprint(),targetFolder=same&&doc.nasRemote?.folder!==undefined?doc.nasRemote.folder:nasConfig.folder;$('#nas-filename').value=same?doc.nasRemote.name:doc.name+'.md';$('#nas-copy').checked=false;$('#nas-target').textContent=nasConfig.address+'/'+(targetFolder||'');$('#nas-upload-dialog').showModal();}
function startUpload(doc,pending){if(uploadInFlight){toast('正在上传，稍后可重试其他文稿');return}if(!native){toast('请在 macOS 应用内上传');return}doc.pendingUpload={...pending,retryable:true};persist();uploadInFlight=true;bridge('nasUpload',{...pending,id:doc.id});$('#nas-result').textContent='正在上传「'+doc.name+'」…';}
$('#nas-upload').onclick=openNASUpload;
$('#nas-upload-dialog').addEventListener('close',()=>{if($('#nas-upload-dialog').returnValue!=='upload')return;const doc=current();let name=$('#nas-filename').value.trim();if(!name||/[\\/]/.test(name)){toast('请填写不含路径分隔符的文件名');return}if(!/\.md$/i.test(name))name+='.md';if($('#nas-copy').checked)name=name.replace(/\.md$/i,'')+'-'+new Date().toISOString().replace(/[:.]/g,'-')+'.md';const remote=doc.nasRemote,same=remote?.fingerprint===configFingerprint();const updating=same&&remote.name===name;const payload={id:doc.id,name,text:doc.text,etag:updating?remote.etag:null,updating,fingerprint:configFingerprint()};if(same&&remote?.folder!==undefined)payload.folder=remote.folder;startUpload(doc,payload)});
function retryPending(manual=false){if(uploadInFlight||!nasConfig.address)return;const doc=docs.find(d=>d.pendingUpload&&(manual||d.pendingUpload.retryable!==false)&&d.pendingUpload.fingerprint===configFingerprint());if(doc)startUpload(doc,doc.pendingUpload);else if(manual)toast('没有可重试的上传；配置变化后请重新选择目标。')}
$('#nas-retry').onclick=()=>retryPending(true);window.addEventListener('online',()=>retryPending());setInterval(()=>retryPending(),60000);
for(const [id,key] of [['nas-address','address'],['nas-folder','folder'],['nas-user','username']])$( '#'+id).value=nasConfig[key]||'';$('#nas-http').checked=!!nasConfig.allowHTTP;if(nasConfig.address){$('#nas-result').textContent='已保存配置，可测试连接或上传文稿。';$('#nas-dot').textContent='已配置'}
for(const id of ['quick-heading','quick-list'])$('#'+id).onchange=e=>{if(e.target.value)prefix(e.target.value);e.target.value=''};
document.body.classList.toggle('reduce-transparency',!!bootstrap.reduceTransparency);
applyPrefs();renderAll();persist();requestAnimationFrame(()=>{setMode(mode);if(prefs.minimal)toggleMinimal(true)});iconify();setTimeout(()=>retryPending(),2000);

// A browser result is tied to a specific request and credential snapshot.
let browserState = {requestID:null,folder:'',config:null,password:'',valid:false};
function formNASConfig(){return {address:($('#nas-address').value.trim()||nasConfig.address||'').replace(/\/+$/,''),username:$('#nas-user').value.trim()||nasConfig.username||'',folder:'',allowHTTP:$('#nas-http').checked||!!nasConfig.allowHTTP}}
function browseFolder(folder){
  browserState.requestID=crypto.randomUUID();browserState.valid=false;
  $('#nas-browser-choose').disabled=true;$('#nas-folders').replaceChildren();
  $('#nas-browser-status').textContent='正在读取目录…';
  $('#nas-current-path').textContent=folder?'/'+folder:'/';
  $('#nas-up').disabled=!browserState.folder;
  bridge('nasBrowse',{requestID:browserState.requestID,config:browserState.config,password:browserState.password,folder});
}
function openNASRemoteFile(file){
  browserState.requestID=crypto.randomUUID();
  $('#nas-browser-status').textContent='正在打开「'+file.name+'」…';
  bridge('nasOpenFile',{requestID:browserState.requestID,config:browserState.config,password:browserState.password,path:file.path});
}
function remotePath(remote){return remote.path||[remote.folder??nasConfig.folder,remote.name].filter(Boolean).join('/')}
function receiveNASFile(data){
  if(!$('#nas-browser').open||!browserState.requestID||data.requestID!==browserState.requestID)return;
  if(!data.ok){if($('#nas-browser').open)$('#nas-browser-status').textContent=data.message;toast(data.message);return}
  if($('#nas-browser').open)$('#nas-browser').close();
  const remote=data.remote||{name:data.name,fingerprint:configFingerprint(),text:data.text};
  const existing=docs.find(d=>d.nasRemote&&d.nasRemote.fingerprint===remote.fingerprint&&remotePath(d.nasRemote)===remotePath(remote));
  if(existing&&existing.text===existing.nasSavedText){existing.text=data.text;existing.nasSavedText=data.text;existing.nasRemote=remote;existing.updated=Date.now();editorStates.delete(existing.id);if(existing.id===activeId)view.setState(editorState(existing.text));switchDoc(existing.id)}
  else{let doc={id:crypto.randomUUID(),name:data.name.replace(/\.(md|markdown|txt|mdown)$/i,''),text:data.text,nasRemote:remote,nasSavedText:data.text,updated:Date.now()};docs.unshift(doc);switchDoc(doc.id)}
  toast('已从 NAS 打开「'+current().name+'」');
}
function receiveFolders(data){
  if(data.requestID!==browserState.requestID||!$('#nas-browser').open)return;
  const list=$('#nas-folders');list.replaceChildren();
  if(!data.ok){$('#nas-browser-status').textContent=data.message+' 可返回根目录或刷新重试；尚未更改保存目录。';return}
  browserState.folder=data.folder;browserState.valid=true;
  $('#nas-up').disabled=!data.folder;$('#nas-current-path').textContent=data.folder?'/'+data.folder:'/';
  $('#nas-browser-choose').disabled=false;
  const files=Array.isArray(data.files)?data.files:[];
  $('#nas-browser-status').textContent=data.folders.length||files.length?'点击文件夹进入，点击文稿直接打开；底部按钮选择当前目录。':'此目录没有可见的子文件夹，可以直接选择当前目录。';
  for(const folder of data.folders){const button=document.createElement('button');button.className='nas-folder';button.setAttribute('role','listitem');button.innerHTML='<i data-lucide="folder"></i><span></span><i data-lucide="chevron-right"></i>';button.querySelector('span').textContent=folder.name;button.onclick=()=>browseFolder(folder.path);list.append(button)}
  for(const file of files){const button=document.createElement('button');button.className='nas-file';button.setAttribute('role','listitem');button.innerHTML='<i data-lucide="file-text"></i><span></span><small>打开</small>';button.querySelector('span').textContent=file.name;button.onclick=()=>openNASRemoteFile(file);list.append(button)}
  iconify();
}
function openNASBrowserForRead(){
  if(!native){toast('请在 macOS 应用内从 NAS 打开文稿');return}
  if(!nasConfig.address&&!$('#nas-address').value.trim()){if(document.body.classList.contains('minimal'))toggleMinimal(false);document.body.classList.remove('hide-sidebar','focus');$('[data-section="nas"]').click();updateVisibility();toast('请先填写 NAS 的 WebDAV 配置');return}
  const initialFolder=nasConfig.folder||$('#nas-folder').value.trim()||'';
  browserState={requestID:null,folder:initialFolder,config:formNASConfig(),password:$('#nas-password').value,valid:false};
  $('#nas-browser').showModal();browseFolder(initialFolder);
}
$('#nas-open').onclick=openNASBrowserForRead;
$('#nas-browse').onclick=()=>{
  if(!native){toast('请在 macOS 应用内浏览 NAS');return}
  if(!$('#nas-form').reportValidity())return;
  browserState={requestID:null,folder:'',config:formNASConfig(),password:$('#nas-password').value,valid:false};
  $('#nas-browser').showModal();browseFolder('');
};
$('#nas-root').onclick=()=>browseFolder('');$('#nas-refresh').onclick=()=>browseFolder(browserState.folder);
$('#nas-up').onclick=()=>browseFolder(browserState.folder.split('/').slice(0,-1).join('/'));
$('#nas-browser-choose').onclick=()=>{if(!browserState.valid)return;$('#nas-folder').value=browserState.folder;$('#nas-result').textContent=browserState.folder?'已选择 WebDAV 目录：/'+browserState.folder+'。点击保存配置生效。':'已选择 WebDAV 根目录。点击保存配置生效。';$('#nas-browser').close()};
$('#nas-browser-cancel').onclick=()=>$('#nas-browser').close();
$('#nas-browser').addEventListener('close',()=>{browserState.password='';browserState.requestID=null;browserState.config=null});

// Report native draggable titlebar regions after every layout/mode change.
let dragLayoutFrame=0;
function syncTitlebarRegions(){
  dragLayoutFrame=0;if(!native)return;
  const rect=(element,pad=0)=>{const r=element.getBoundingClientRect();return {x:r.x-pad,y:r.y-pad,width:r.width+pad*2,height:r.height+pad*2}};
  const regions=[$('.toolbar'),$('.brand')].map(e=>rect(e)).filter(r=>r.width>0&&r.height>0);
  const exclusions=$$('.toolbar button,.toolbar select,.toolbar .segmented,.toolbar .compact-format').filter(e=>e.getClientRects().length).map(e=>rect(e,4));
  for(const element of $$('dialog[open],#menu:not([hidden])'))exclusions.push(rect(element,4));
  exclusions.push({x:0,y:0,width:90,height:35}); // macOS traffic lights
  bridge('titlebarRegions',{regions,exclusions,enabled:true});
}
function scheduleTitlebarRegions(){if(!dragLayoutFrame)dragLayoutFrame=requestAnimationFrame(syncTitlebarRegions)}
const titlebarResize=new ResizeObserver(scheduleTitlebarRegions);
for(const element of [$('.toolbar'),$('.brand'),$('.sidebar'),...$$('dialog,#menu')])titlebarResize.observe(element);
const titlebarMutation=new MutationObserver(scheduleTitlebarRegions);
titlebarMutation.observe(document.body,{attributes:true,attributeFilter:['class']});
for(const element of $$('dialog,#menu'))titlebarMutation.observe(element,{attributes:true,attributeFilter:['open','hidden']});
window.addEventListener('resize',scheduleTitlebarRegions);scheduleTitlebarRegions();

let aiJob=null;
$('#ai-executable').value=localStorage.getItem('moye.codex.path')||'';
$('#ai-toggle').onclick=()=>{if(native)bridge('aiShow');else window.open('assistant.html','moye-assistant','width=440,height=780')};
let aiContext={};
window.beginAssistant=data=>{aiContext=data;$('#ai-instruction').value=data.instruction;$('#ai-executable').value=data.executable||'';$('#ai-generate').click()};
function stopAI(){bridge('aiCancel');aiJob=null;$('#ai-generate').disabled=false;$('#ai-apply').disabled=true;$('#ai-status').textContent='已停止，文稿未改变。'}
$('#ai-close').onclick=()=>{stopAI();$('#ai-panel').hidden=true};$('#ai-cancel').onclick=stopAI;
$('#ai-generate').onclick=()=>{
 if(!native){toast('请在 macOS 应用中连接 Codex');return}
 const instruction=$('#ai-instruction').value.trim();if(!instruction)return;
 const doc=current(),sel=view.state.selection.main,from=sel.empty?0:sel.from,to=sel.empty?doc.text.length:sel.to;
 aiJob={requestID:crypto.randomUUID(),id:doc.id,base:doc.text,from,to,result:''};
 $('#ai-before').textContent=doc.text.slice(from,to);$('#ai-after').value='';$('#ai-apply').disabled=true;$('#ai-generate').disabled=true;$('#ai-status').textContent='正在连接 Codex…';
 localStorage.setItem('moye.codex.path',$('#ai-executable').value.trim());
 bridge('aiUI',{before:doc.text.slice(from,to),scope:sel.empty?'全文':'选区',name:doc.name});
 bridge('aiRequest',{model:aiContext.model||'',references:aiContext.references||'',requestID:aiJob.requestID,text:doc.text.slice(from,to),instruction,executable:$('#ai-executable').value.trim()});
};
function receiveAI(data){
 if(!aiJob||data.requestID!==aiJob.requestID)return;
 if(data.status==='model')return;
 if(data.status==='error'){$('#ai-status').textContent=data.text;$('#ai-generate').disabled=false;$('#ai-apply').disabled=true;return}
 $('#ai-after').value=data.text;aiJob.result=data.text;
 $('#ai-status').textContent=data.status==='done'?'建议已生成，请对照原文后应用。':'正在生成…';
 if(data.status==='done'){$('#ai-generate').disabled=false;$('#ai-apply').disabled=false}
}
$('#ai-apply').onclick=()=>{
 const job=aiJob;if(!job||!job.result)return;
 const doc=docs.find(d=>d.id===job.id);
 if(!doc||doc.text!==job.base){$('#ai-status').textContent='原文已变化，已阻止覆盖。请重新生成。';bridge('aiUI',{error:$('#ai-status').textContent});$('#ai-apply').disabled=true;return}
 if(activeId!==job.id){$('#ai-status').textContent='请切回生成建议时的文稿，再应用修改。';bridge('aiUI',{error:$('#ai-status').textContent});return}
 docs.push({id:crypto.randomUUID(),name:doc.name+' · AI 修改前',text:doc.text,updated:Date.now()});
 view.dispatch({changes:{from:job.from,to:job.to,insert:job.result},annotations:isolateHistory.of("full")});persist();
 bridge('aiUI',{applied:true});$('#ai-apply').disabled=true;aiJob=null;$('#ai-status').textContent='已应用；可用 ⌘Z 撤销，也可打开修改前草稿。';
};
