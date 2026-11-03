'use strict';
// Read-only inspection. No navigation, prompt, image download or remote upload.
const fs=require('node:fs'),crypto=require('node:crypto'),path=require('node:path');
class CDP{
 constructor(url){this.url=url;this.seq=0;this.pending=new Map()}
 async open(){this.ws=new WebSocket(this.url);await new Promise((ok,bad)=>{const t=setTimeout(()=>bad(Error('CONNECT_TIMEOUT')),5000);this.ws.onopen=()=>{clearTimeout(t);ok()};this.ws.onerror=()=>{clearTimeout(t);bad(Error('CONNECT_FAILED'))}});this.ws.onmessage=e=>{const m=JSON.parse(String(e.data));const p=this.pending.get(m.id);if(!p)return;clearTimeout(p.timer);this.pending.delete(m.id);m.error?p.reject(Error('EVALUATE_FAILED')):p.resolve(m.result)}}
 async evaluate(expression){const id=++this.seq;const r=await new Promise((resolve,reject)=>{const timer=setTimeout(()=>{this.pending.delete(id);reject(Error('EVALUATE_TIMEOUT'))},6000);this.pending.set(id,{resolve,reject,timer});this.ws.send(JSON.stringify({id,method:'Runtime.evaluate',params:{expression,returnByValue:true}}))});if(r.exceptionDetails)throw Error('PAGE_EVALUATE_FAILED');return r.result?.value}
 close(){for(const p of this.pending.values()){clearTimeout(p.timer);p.reject(Error('CLOSED'))}this.pending.clear();this.ws?.close()}
}
function probe(){
 const body=document.body?.innerText||'';
 const jobs=[...new Set(body.match(/TT(?:ITTULARES|ENDENCIAS)_IMAGE_JOB_V4\s+([A-Za-z0-9_.-]+)/g)||[])].slice(-4).map(x=>x.trim().split(/\s+/).pop());
 const selector='[data-user-message-bubble="true"],[data-message-author-role="user"],[data-testid*="user-message" i],[class*="user-message" i],article[data-turn="user"]';
 const all=[...document.querySelectorAll(selector)],selected=all.filter(el=>!all.some(other=>other!==el&&el.contains(other)));
 const describe=(nodes,cmd)=>nodes.map(el=>{const t=String(el.innerText||el.textContent||'').trim();const pos=t.indexOf(cmd);return{tag:el.tagName,bubble:el.getAttribute('data-user-message-bubble'),hasCommand:pos>=0,commandOffset:pos,hasJobPrefix:/^TT(?:ITTULARES|ENDENCIAS)_IMAGE_JOB_V4\s/.test(t),leadingCodes:pos>=0?[...t.slice(0,Math.min(pos,40))].map(c=>c.codePointAt(0)):[]}});
 return{url:location.href,selectedCount:selected.length,bubbleCount:document.querySelectorAll('[data-user-message-bubble="true"]').length,jobs:jobs.map(command=>({command,selected:describe(selected,command),bubbles:describe([...document.querySelectorAll('[data-user-message-bubble="true"]')],command)}))};
}
async function main(){
 const base='C:\\TTiTTulares',sources={};
 for(const [project,file] of [['ttendencias','TTendenciasWebImages.cjs'],['ttittulares','TTiTTularesWebImages.cjs']]){
  const p=path.join(base,file);console.log('READER '+project+' '+crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex'));sources[project]=require(p);
 }
 const pages=await fetch('http://127.0.0.1:9223/json/list',{signal:AbortSignal.timeout(5000)}).then(r=>r.json());
 let inspected=0,matched=0;
 for(const page of pages.filter(p=>p.type==='page'&&p.webSocketDebuggerUrl&&/^https:\/\/chatgpt\.com\/(?:c\/|g\/[^/]+\/c\/)/.test(p.url))){
  const cdp=new CDP(page.webSocketDebuggerUrl);
  try{await cdp.open();const report=await cdp.evaluate('('+probe.toString()+')()');inspected++;if(!report.jobs.length)continue;
   for(const job of report.jobs){const source=sources[job.command.startsWith('tt-')?'ttittulares':'ttendencias'];job.reader=await cdp.evaluate(source.conversationProbe(job.command,true));}
   matched++;console.log('OPEN_IMAGE_JOB '+JSON.stringify({target:page.id,...report}));
  }catch{console.log('TAB_INSPECTION_UNAVAILABLE '+page.id)}finally{cdp.close()}
 }
 console.log('DIAGNOSTIC_END '+JSON.stringify({inspected,imageConversations:matched}));
}
if(require.main===module)main().catch(e=>{console.error('DIAGNOSTIC_FAILED '+e.message);process.exitCode=1});
module.exports={probe};
