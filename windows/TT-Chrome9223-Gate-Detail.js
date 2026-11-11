'use strict';
// TT9223_GATE_DETAIL_V1. Read-only diagnostic; never closes, edits or restarts anything.
const fs=require('node:fs'),path=require('node:path');
const HOME='C:\\TTiTTulares',BASE='http://127.0.0.1:9223';
const read=f=>{try{return JSON.parse(fs.readFileSync(f,'utf8'))}catch{return null}};
const pins=new Set(['ttittulares-image-tab.json','ttendencias-image-tab.json'].map(n=>read(path.join(HOME,n))?.target_id).filter(Boolean).map(String));
const jobs=new Map();try{
 for(const name of fs.readdirSync(path.join(HOME,'editorial-tab-watch'))){
  if(!/^[a-f0-9-]{16,80}\.json$/i.test(name))continue;
  const j=read(path.join(HOME,'editorial-tab-watch',name));
  if(j&&/^[a-f0-9-]{16,80}$/i.test(String(j.id||'')))jobs.set(String(j.id),j);
 }
}catch{}
function inspect(t){
 return new Promise(resolve=>{
  if(!t.webSocketDebuggerUrl||typeof WebSocket!=='function')return resolve({unknown:'websocket_unavailable'});
  let ws,done=false;const timer=setTimeout(()=>end({unknown:'timeout'}),6500);
  function end(v){if(done)return;done=true;clearTimeout(timer);try{ws?.close()}catch{}resolve(v)}
  const expr=String.raw\`(()=>{const buttons=[...document.querySelectorAll('button')];const stop=!!document.querySelector('button[data-testid="stop-button"]')||buttons.some(b=>/^(stop|detener|parar|cancelar)(\\b|\\s)/i.test(String(b.getAttribute('aria-label')||b.getAttribute('title')||'').trim()));const c=document.querySelector('#prompt-textarea,[data-testid="prompt-textarea"],textarea,[contenteditable="true"][role="textbox"]');const draft=String(c?.innerText||c?.value||c?.textContent||'').trim();return {ready:document.readyState,stop,ariaBusy:document.querySelectorAll('[aria-busy="true"]').length,mainAriaBusy:document.querySelectorAll('main [aria-busy="true"]').length,spinner:document.querySelectorAll('[data-testid="loading-spinner"]').length,draftChars:draft.length,focused:document.hasFocus(),messageCount:document.querySelectorAll('[data-message-author-role]').length,assistantCount:document.querySelectorAll('[data-message-author-role="assistant"]').length}})()\`;
  try{
   ws=new WebSocket(t.webSocketDebuggerUrl);
   ws.addEventListener('open',()=>{try{ws.send(JSON.stringify({id:32,method:'Runtime.evaluate',params:{expression:expr,returnByValue:true}}))}catch{end({unknown:'send_failure'})}},{once:true});
   ws.addEventListener('message',e=>{try{const v=JSON.parse(String(e.data));if(v.id!==32)return;const o=v.result?.result?.value;if(v.error||v.result?.exceptionDetails||!o)return end({unknown:'evaluation_failure'});end(o)}catch{end({unknown:'response_failure'})}});
   ws.addEventListener('error',()=>end({unknown:'socket_error'}),{once:true});
   ws.addEventListener('close',()=>end({unknown:'socket_closed'}),{once:true});
  }catch{end({unknown:'connection_failure'})}
 });
}
(async()=>{
 const r=await fetch(BASE+'/json/list',{cache:'no-store',signal:AbortSignal.timeout(8500)});
 if(!r.ok)throw Error('CDP HTTP '+r.status);
 const list=await r.json();if(!Array.isArray(list))throw Error('CDP invalid data');
 const pages=list.filter(t=>t.type==='page'),result=new Array(pages.length);let next=0;
 await Promise.all(Array.from({length:Math.min(3,pages.length)},async()=>{while(next<pages.length){const i=next++,t=pages[i],j=jobs.get(String(t.id));result[i]={id:String(t.id||'').slice(0,18),pinned:pins.has(String(t.id)),tracked:!!j,age:j?Math.round((Date.now()-Number(j.created||Date.now()))/60000):null,...await inspect(t)}}}));
 const n=fn=>result.filter(fn).length;
 console.log('TT9223_GATE_DETAIL_V1 read_only=true pages='+pages.length+' tracked='+jobs.size+' pinned='+n(x=>x.pinned));
 console.log('COUNTS '+JSON.stringify({unknown:n(x=>!!x.unknown),stopButton:n(x=>!!x.stop),ariaBusyAny:n(x=>x.ariaBusy>0),ariaOnly:n(x=>x.ariaBusy>0&&!x.stop&&!x.unknown),mainAriaBusy:n(x=>x.mainAriaBusy>0),draft:n(x=>x.draftChars>0),focused:n(x=>!!x.focused),oldTracked:n(x=>x.tracked&&x.age>=60),oldTrackedNoStopNoDraft:n(x=>x.tracked&&x.age>=60&&!x.stop&&!x.draftChars&&!x.unknown)}));
 for(const x of result)if(x.unknown||x.stop||x.ariaBusy||x.draftChars||x.pinned)console.log('TAB id='+x.id+' age='+String(x.age??'?')+' tracked='+x.tracked+' pinned='+x.pinned+' ready='+(x.ready||'?')+' stop='+!!x.stop+' aria_busy='+(x.ariaBusy??'?')+' main_busy='+(x.mainAriaBusy??'?')+' spinner='+(x.spinner??'?')+' draft_chars='+(x.draftChars??'?')+' focused='+!!x.focused+' msgs='+(x.messageCount??'?')+' unknown='+(x.unknown||'-'));
 console.log('NO_CHANGES to Chrome, tabs, drafts, listeners, images, queues or jobs.');
})().catch(e=>{console.error('DIAG_ERROR '+String(e.message||e));process.exitCode=2});
