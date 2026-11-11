'use strict';
// TT_EDITORIAL_UNBLOCK_SAFE_V1. Default is READ ONLY. --apply closes ONLY
// twice-inspected, launcher-tracked, old, empty, unfocused editorial tabs.
// It does not close pinned image tabs, drafts, untracked tabs or active jobs.
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process');
const HOME='C:\\TTiTTulares',DIR=path.join(HOME,'editorial-tab-watch');
const CDP='http://127.0.0.1:9223',APPLY=process.argv.includes('--apply');
const MIN_AGE=90*60000,STOP_AT=15,MAX_CLOSE=18;
const read=f=>{try{return JSON.parse(fs.readFileSync(f,'utf8'))}catch{return null}};
const idOK=s=>/^[a-f0-9-]{16,80}$/i.test(String(s||''));
function pins(){return new Set(['ttittulares-image-tab.json','ttendencias-image-tab.json'].map(n=>read(path.join(HOME,n))?.target_id).filter(Boolean).map(String))}
function tracked(){
 const m=new Map();
 for(const n of fs.readdirSync(DIR)){
  if(!/^[a-f0-9-]{16,80}\.json$/i.test(n))continue;
  const j=read(path.join(DIR,n));
  if(j&&idOK(j.id)&&n===j.id+'.json'&&Number(j.created)>0)m.set(j.id,j);
 }
 return m;
}
function isConversation(u){
 try{const x=new URL(u);return x.protocol==='https:'&&x.hostname==='chatgpt.com'&&/(?:^|\/)c\/[^/]+/.test(x.pathname)}
 catch{return false}
}
async function targets(){
 const r=await fetch(CDP+'/json/list',{cache:'no-store',signal:AbortSignal.timeout(8500)});
 if(!r.ok)throw Error('CDP HTTP '+r.status);
 const x=await r.json();if(!Array.isArray(x))throw Error('Unexpected CDP result');
 return x.filter(t=>t.type==='page');
}
function inspect(t){
 return new Promise(resolve=>{
  if(!t.webSocketDebuggerUrl||typeof WebSocket!=='function')return resolve({unknown:true});
  let ws,done=false;const timer=setTimeout(()=>finish({unknown:true}),7000);
  function finish(o){if(done)return;done=true;clearTimeout(timer);try{ws?.close()}catch{}resolve(o)}
  const expr="(()=>{const b=[...document.querySelectorAll('button')];const stop=!!document.querySelector('button[data-testid=\"stop-button\"]')||b.some(x=>/^(stop|detener|parar|cancelar)(\\b|\\s)/i.test(String(x.getAttribute('aria-label')||x.getAttribute('title')||'').trim()));const c=document.querySelector('#prompt-textarea,[data-testid=\"prompt-textarea\"],textarea,[contenteditable=\"true\"][role=\"textbox\"]');const draft=String(c?.innerText||c?.value||c?.textContent||'').trim();return {url:location.href,ready:document.readyState,stop,mainBusy:!!document.querySelector('main [aria-busy=\"true\"]'),spinner:!!document.querySelector('[data-testid=\"loading-spinner\"]'),draftChars:draft.length,focused:document.hasFocus(),messages:document.querySelectorAll('[data-message-author-role]').length,assistant:document.querySelectorAll('[data-message-author-role=\"assistant\"]').length}})()";
  try{
   ws=new WebSocket(t.webSocketDebuggerUrl);
   ws.addEventListener('open',()=>{try{ws.send(JSON.stringify({id:44,method:'Runtime.evaluate',params:{expression:expr,returnByValue:true}}))}catch{finish({unknown:true})}},{once:true});
   ws.addEventListener('message',e=>{try{const o=JSON.parse(String(e.data));if(o.id!==44)return;if(o.error||o.result?.exceptionDetails||!o.result?.result?.value)return finish({unknown:true});finish(o.result.result.value)}catch{finish({unknown:true})}});
   ws.addEventListener('error',()=>finish({unknown:true}),{once:true});
   ws.addEventListener('close',()=>finish({unknown:true}),{once:true});
  }catch{finish({unknown:true})}
 });
}
function reason(t,s,j,pinned){
 if(!j)return 'untracked';
 if(pinned.has(t.id))return 'image_pin';
 if(!isConversation(t.url)||!isConversation(j.url)||!isConversation(s.url)||s.url!==t.url)return 'not_verified_conversation';
 if(Date.now()-Number(j.created)<MIN_AGE)return 'too_recent';
 if(s.unknown||s.ready!=='complete')return 'unverified';
 if(s.stop||s.mainBusy||s.spinner)return 'active';
 if(s.draftChars!==0)return 'draft';
 if(s.focused)return 'focused';
 if(s.messages!==0||s.assistant!==0)return 'rendered_content';
 return '';
}
function noActiveJobs(){
 const script="$a=@(Get-CimInstance Win32_Process -Filter \"Name='node.exe'\" -ErrorAction Stop | Where-Object { [string]$_.CommandLine -match '(TTiTTulares|TTendencias)ImageBridge[.]js|[\\\\/]Ejecutar[.]js|[\\\\/]TT-Editorial-Guard[.]js' }); Write-Output $a.Count";
 const p=cp.spawnSync('powershell.exe',['-NoProfile','-NonInteractive','-Command',script],{encoding:'utf8',timeout:15000,windowsHide:true});
 if(p.error||p.status!==0)throw Error('Cannot validate active jobs');
 const n=Number(String(p.stdout||'').trim());
 if(!Number.isInteger(n)||n<0)throw Error('Unverified active-jobs response');
 if(n)throw Error('ACTIVE_JOBS='+n+'; cleanup deferred without closing tabs');
}
async function main(){
 const jobs=tracked(),pages=await targets(),pin=pins();
 const rows=[];let idx=0;
 await Promise.all(Array.from({length:Math.min(3,pages.length)},async()=>{
  while(idx<pages.length){const i=idx++,t=pages[i],j=jobs.get(t.id),s=await inspect(t);rows[i]={t,j,s,why:reason(t,s,j,pin)}}
 }));
 const eligible=rows.filter(x=>!x.why).sort((a,b)=>Number(a.j.created)-Number(b.j.created));
 const counts={};for(const x of rows)counts[x.why||'eligible']=(counts[x.why||'eligible']||0)+1;
 console.log('TT_EDITORIAL_UNBLOCK_SAFE_V1 mode='+(APPLY?'apply':'audit')+' pages='+pages.length+' tracked='+jobs.size+' pinned='+rows.filter(x=>pin.has(x.t.id)).length+' eligible='+eligible.length);
 console.log('COUNTS '+JSON.stringify(counts));
 for(const x of eligible)console.log('CANDIDATE id='+String(x.t.id).slice(0,18)+' age_min='+Math.floor((Date.now()-Number(x.j.created))/60000));
 if(!APPLY){console.log('AUDIT_ONLY: nothing was closed');return}
 if(!eligible.length){console.log('NO_ELIGIBLE_TABS: nothing was closed');return}
 noActiveJobs();
 // A separate observation is required before any close.
 await new Promise(ok=>setTimeout(ok,10000));
 let closed=0,skipped=0;
 for(const x of eligible){
  if(closed>=MAX_CLOSE)break;
  const currentList=await targets();if(currentList.length<=STOP_AT)break;
  const t=currentList.find(v=>v.id===x.t.id),j=tracked().get(x.t.id);
  if(!t||!j||t.url!==x.t.url||Number(j.created)!==Number(x.j.created)||pins().has(x.t.id)){skipped++;continue}
  const s=await inspect(t);if(reason(t,s,j,pins())||s.url!==x.s.url){skipped++;continue}
  noActiveJobs();
  const last=(await targets()).find(v=>v.id===t.id);
  if(!last||last.url!==t.url||pins().has(t.id)){skipped++;continue}
  const v=await inspect(last);
  if(reason(last,v,j,pins())||v.url!==s.url){skipped++;continue}
  const r=await fetch(CDP+'/json/close/'+encodeURIComponent(t.id),{signal:AbortSignal.timeout(6000)});
  if(!r.ok){skipped++;console.log('CLOSE_FAILED id='+String(t.id).slice(0,18)+' status='+r.status);continue}
  closed++;console.log('CLOSED_VERIFIED_STALE_EDITORIAL_TAB id='+String(t.id).slice(0,18));
 }
 console.log('SUMMARY closed='+closed+' skipped='+skipped+' pages_before='+pages.length+' pages_after='+(await targets()).length);
 console.log('No image pins, drafts, untracked conversations, Chrome processes, listeners or GitHub files were modified.');
}
main().catch(e=>{console.error('TT_EDITORIAL_UNBLOCK_ABORT '+String(e.message||e));process.exitCode=2});
