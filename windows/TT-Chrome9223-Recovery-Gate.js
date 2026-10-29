'use strict';
// Recovery gate v1. READ-ONLY, no Chrome writes. Fail closed if a page might be busy.
// Never collect or print page text, URLs, drafts, cookies, account data or tokens.
const fs=require('node:fs'),path=require('node:path');
const BASE='http://127.0.0.1:9223';
const HOME='C:\\TTiTTulares';
function pin(name){try{return String(JSON.parse(fs.readFileSync(path.join(HOME,name),'utf8')).target_id||'')}catch{return ''}}
const imagePins=new Set(['ttittulares-image-tab.json','ttendencias-image-tab.json'].map(pin).filter(Boolean));
function inspect(t){
 return new Promise(resolve=>{
   let ws,done=false;
   const stop=setTimeout(()=>end({unknown:'CDP-inspect-timeout'}),6000);
   function end(value){if(done)return;done=true;clearTimeout(stop);try{ws?.close()}catch{}resolve(value)}
   if(!t.webSocketDebuggerUrl||typeof WebSocket!=='function')return end({unknown:'CDP-unavailable'});
   const expr="(()=>{const stop=!!document.querySelector('button[data-testid=\"stop-button\"]')||[...document.querySelectorAll('button')].some(b=>/^(stop|detener|parar|cancelar)(\\b|\\s)/i.test(String(b.getAttribute('aria-label')||b.getAttribute('title')||'')));const loading=!!document.querySelector('[aria-busy=\"true\"]');const c=document.querySelector('#prompt-textarea,[data-testid=prompt-textarea],textarea,[contenteditable=true][role=textbox]');const draft=String(c?.textContent||c?.value||'').trim();return {ready:document.readyState,busy:stop||loading,draftChars:draft.length}})()";
   try{
     ws=new WebSocket(t.webSocketDebuggerUrl);
     ws.addEventListener('open',()=>{try{ws.send(JSON.stringify({id:1,method:'Runtime.evaluate',params:{expression:expr,returnByValue:true}}))}catch(e){end({unknown:'CDP-send-error'})}},{once:true});
     ws.addEventListener('message',e=>{try{const m=JSON.parse(String(e.data));if(m.id!==1)return;if(m.error||m.result?.exceptionDetails||!m.result?.result?.value)return end({unknown:'CDP-eval-error'});end(m.result.result.value)}catch{end({unknown:'CDP-response-error'})}});
     ws.addEventListener('error',()=>end({unknown:'CDP-socket-error'}),{once:true});
     ws.addEventListener('close',()=>end({unknown:'CDP-socket-closed'}),{once:true});
   }catch{end({unknown:'CDP-connect-error'})}
 });
}
(async()=>{
 const r=await fetch(BASE+'/json/list',{cache:'no-store',signal:AbortSignal.timeout(8000)});
 if(!r.ok)throw Error('CDP HTTP '+r.status);
 const all=await r.json();
 if(!Array.isArray(all))throw Error('Invalid CDP targets');
 const pages=all.filter(x=>x.type==='page');
 if(pages.length>80)throw Error('Too many tabs to verify');
 const results=[];
 let idx=0;
 await Promise.all(Array.from({length:Math.min(3,pages.length)},async()=>{
   while(idx<pages.length){
     const t=pages[idx++];
     const url=(()=>{try{return new URL(t.url)}catch{return null}})();
     const safe=url&&((url.protocol==='https:'&&url.hostname==='chatgpt.com')||url.protocol==='about:');
     const state=safe?await inspect(t):{unknown:'unrecognized-page'};
     results.push({id:t.id,pinned:imagePins.has(t.id),...state});
   }
 }));
 const uncertain=results.filter(x=>x.unknown||x.busy||x.draftChars>0||x.ready!=='complete');
 console.log('TT9223_RECOVERY_GATE_V1 pages='+pages.length+' pinned='+results.filter(x=>x.pinned).length+
  ' busy='+results.filter(x=>x.busy).length+' drafts='+results.filter(x=>x.draftChars>0).length+
  ' unknown='+results.filter(x=>!!x.unknown).length);
 if(uncertain.length){console.error('TT9223_RECOVERY_BLOCKED: '+uncertain.length+
  ' page(s) may be active or not inspectable. No recovery allowed.');process.exitCode=2}
 else console.log('TT9223_RECOVERY_SAFE: no active, unsent or unknown page detected');
})().catch(e=>{console.error('TT9223_RECOVERY_BLOCKED '+String(e.message||e));process.exitCode=2});
