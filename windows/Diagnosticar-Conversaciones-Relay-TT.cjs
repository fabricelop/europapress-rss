'use strict';
// Read-only diagnosis. Only temporary tabs in the existing private relay 9234.
// Never sends chat messages, fetches image bytes, approves, or edits local tasks.
const fs=require('node:fs'),path=require('node:path');
class CDP {
 constructor(url){this.url=url;this.seq=0;this.pending=new Map()}
 async open(){this.ws=new WebSocket(this.url);await new Promise((ok,bad)=>{const timer=setTimeout(()=>bad(Error('CONNECT_TIMEOUT')),5000);this.ws.addEventListener('open',()=>{clearTimeout(timer);ok()},{once:true});this.ws.addEventListener('error',()=>{clearTimeout(timer);bad(Error('CONNECT_FAILED'))},{once:true})});this.ws.addEventListener('message',e=>{const m=JSON.parse(String(e.data)),p=this.pending.get(m.id);if(!p)return;this.pending.delete(m.id);clearTimeout(p.timer);m.error?p.bad(Error('CDP_ERROR')):p.ok(m.result)})}
 call(method,params={}){const id=++this.seq;return new Promise((ok,bad)=>{const timer=setTimeout(()=>{this.pending.delete(id);bad(Error('CALL_TIMEOUT'))},10000);this.pending.set(id,{ok,bad,timer});this.ws.send(JSON.stringify({id,method,params}))})}
 close(){for(const p of this.pending.values()){clearTimeout(p.timer);p.bad(Error('CLOSED'))}this.pending.clear();try{this.ws?.close()}catch{}}
}
async function json(url){const r=await fetch(url,{signal:AbortSignal.timeout(5000)});if(!r.ok)throw Error('HTTP_'+r.status);return r.json()}
async function main(){
 const base='C:\\TTiTTulares',dir=path.join(base,'ttittulares-web-images');
 const wanted=new Set(['e2c7b2697341','1fe8ac31f236','e61e12b7275e']);
 const tasks=fs.readdirSync(dir).filter(x=>x.endsWith('.json')).flatMap(file=>{try{const d=JSON.parse(fs.readFileSync(path.join(dir,file),'utf8'));return wanted.has(d.target_id)?[d]:[]}catch{return []}});
 const version=await json('http://127.0.0.1:9234/json/version');console.log(JSON.stringify({relay:9234,headless:/HeadlessChrome/i.test(version['User-Agent']||'')}));const browser=new CDP(version.webSocketDebuggerUrl);await browser.open();
 try{for(const task of tasks){let owned,tab;try{
  const u=new URL(task.conversation_url);if(u.origin!=='https://chatgpt.com'||!/^\/(?:c\/[a-f0-9-]+|g\/[^/]+\/c\/[a-f0-9-]+)\/?$/i.test(u.pathname))throw Error('INVALID_CHAT_URL');
  owned=(await browser.call('Target.createTarget',{url:u.origin+u.pathname,background:true})).targetId;
  let result;
  for(let n=0;n<20;n++){
   try{
    if(!tab){const pages=await json('http://127.0.0.1:9234/json/list'),target=pages.find(x=>x.id===owned&&x.webSocketDebuggerUrl);if(!target)throw Error('WAIT_TARGET');tab=new CDP(target.webSocketDebuggerUrl);await tab.open()}
    const expression=`(()=>{const text=document.body?.innerText||'';const bubbles=[...document.querySelectorAll('[data-user-message-bubble="true"]')];const command=${JSON.stringify(task.command_id)};return {readyState:document.readyState,visibility:document.visibilityState,bodyCharacters:text.length,titleClass:/just a moment|checking your browser/i.test(document.title)?'verification':/log in|sign in|iniciar sesi[oó]n/i.test(document.title)?'sign_in':/chatgpt/i.test(document.title)?'chatgpt':'other',verificationRequired:/just a moment|checking your browser/i.test(document.title)||/verify you are human|verifica que eres humano|verifying you are human|checking if the site connection is secure/i.test(text),passwordField:!!document.querySelector('input[type=password]'),scriptElements:document.scripts.length,frames:document.querySelectorAll('iframe').length,chatPath:location.pathname,userBubbles:bubbles.length,commandInBubble:bubbles.some(x=>(x.innerText||x.textContent||'').includes(command)),commandInPage:text.includes(command),jobMarkers:[...new Set(text.match(/(?:TTITTULARES|TTENDENCIAS)_IMAGE_JOB_V4\\s+[A-Za-z0-9_.-]+/g)||[])].slice(0,4),signInVisible:!!document.querySelector('[data-testid="login-button"],a[href="/auth/login"]'),accessError:/unable to load conversation|conversation not found|no se pudo cargar la conversaci[oó]n|no tienes acceso|do not have access/i.test(text),largeImages:[...document.images].filter(x=>x.complete&&x.naturalWidth>=1024&&x.naturalHeight>=576).length}})()`;
    const r=await tab.call('Runtime.evaluate',{expression,returnByValue:true});if(r.exceptionDetails)throw Error('PAGE_CONTEXT_LOADING');result=r.result?.value;
    if(result?.commandInBubble||result?.signInVisible||result?.accessError||result?.verificationRequired||result?.passwordField)break;
   }catch{tab?.close();tab=null;}
   await new Promise(r=>setTimeout(r,1000));
  }
  console.log(JSON.stringify({command:task.command_id,relay:9234,...(result||{reason:'PAGE_UNAVAILABLE'})}));
 }catch{console.log(JSON.stringify({command:task.command_id,reason:'DIAGNOSTIC_UNAVAILABLE'}))}finally{tab?.close();if(owned)try{await browser.call('Target.closeTarget',{targetId:owned})}catch{}}}}
 finally{browser.close()}
}
if(require.main===module)main().catch(()=>{console.error('RELAY_DIAGNOSTIC_UNAVAILABLE');process.exitCode=1});
module.exports={CDP};
