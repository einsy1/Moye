const $=s=>document.querySelector(s);
const bridge=(action,data={})=>window.webkit?.messageHandlers?.native?.postMessage({action,...data});
let files=[],busy=false,requestID=null,visibleTab='after';
const status=text=>{$('#status').textContent=text};
function activity(value){busy=value;$('#generate').disabled=value;$('#cancel').disabled=!value;$('#attach').disabled=value}
function showTab(tab){visibleTab=tab;$('#after').hidden=tab!=='after'||!$('#after').textContent;$('#before').hidden=tab!=='before'||!$('#before').textContent;$('#tab-after').classList.toggle('selected',tab==='after');$('#tab-before').classList.toggle('selected',tab==='before')}
function renderFiles(){const list=$('#files');list.replaceChildren();$('#file-count').textContent=files.length;if(!files.length){const empty=document.createElement('div');empty.className='empty-files';empty.textContent='把背景材料，交给助手参考。';list.append(empty)}for(const file of files){const row=document.createElement('div');row.className='file';const icon=document.createElement('span');icon.className='file-icon';icon.textContent='▤';const detail=document.createElement('div'),name=document.createElement('strong'),size=document.createElement('small');name.textContent=file.name;size.textContent=file.text.length.toLocaleString()+' 字符 · 已就绪';detail.append(name,size);const remove=document.createElement('button');remove.textContent='×';remove.setAttribute('aria-label','移除 '+file.name);remove.onclick=()=>{if(busy)return;files=files.filter(f=>f.id!==file.id);renderFiles()};row.append(icon,detail,remove);list.append(row)}}
$('#settings-toggle').onclick=()=>{$('#settings').hidden=!$('#settings').hidden};
for(const el of document.querySelectorAll('[data-prompt]'))el.onclick=()=>{$('#instruction').value=el.dataset.prompt};
$('#attach').onclick=()=>bridge('aiAttach');
$('#tab-before').onclick=()=>showTab('before');$('#tab-after').onclick=()=>showTab('after');
$('#generate').onclick=()=>{if(!$('#instruction').value.trim())return;activity(true);requestID=null;$('#apply').disabled=true;$('#after').textContent='';$('#before').textContent='';$('#result-empty').hidden=false;showTab('after');status('正在连接 Codex…');bridge('aiBegin',{instruction:$('#instruction').value,model:$('#model').value.trim(),executable:$('#executable').value.trim(),references:JSON.stringify(files.map(({name,text})=>({name,text})))})};
$('#cancel').onclick=()=>{bridge('aiCancel');activity(false);requestID='cancelled';$('#apply').disabled=true;status('已停止 · 文稿保持原样')};
$('#apply').onclick=()=>bridge('aiApply');
window.receiveAssistant=data=>{
 if(data.action==='aiSettings'){$('#model').value=data.model;$('#executable').value=data.executable;if(data.model)$('#model-label').textContent=data.model+' · 待确认'}
 if(data.action==='aiTheme'){const dark=data.theme==='dark'||data.theme==='auto'&&matchMedia('(prefers-color-scheme: dark)').matches;document.documentElement.dataset.theme=dark?'dark':'light'}
 if(data.action==='aiAttachments'){for(const file of data.files){if(files.length>=8||new TextEncoder().encode(JSON.stringify([...files,file])).length>115000){status('参考资料最多 8 份，正文合计需小于 110 KB。');break}files.push(file)}renderFiles()}
 if(data.action==='aiAttachmentError')status(data.text);
 if(data.action==='aiUI'){
  if(data.before!==undefined){$('#before').textContent=data.before;$('#scope').textContent=data.scope;$('#document-name').textContent=data.name}
  if(data.error){status(data.error);activity(false)}
  if(data.applied){status('已应用 · 可撤销，修改前草稿已保留');$('#apply').disabled=true}
 }
 if(data.action==='aiResult'){
  if(!busy||requestID==='cancelled')return;
  if(requestID&&requestID!==data.requestID)return;requestID=data.requestID;
  if(data.status==='model'){$('#model-label').textContent=data.text||'Codex 未返回模型标识';return}
  if(data.status==='error'){status(data.text);activity(false);return}
  $('#after').textContent=data.text;$('#result-empty').hidden=true;showTab(visibleTab);
  if(data.status==='done'){activity(false);$('#apply').disabled=false;status('建议已就绪 · 请检查后应用')}else status('正在生成修改建议…');
 }
};
