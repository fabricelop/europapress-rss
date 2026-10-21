'use strict';
// TT_EDITORIAL_TAB_WATCH_V1: monitors only temporary tabs registered by Ejecutar.js.
// Never closes fixed image tabs, and never kills Chrome or another process.
// Uses Node 20+ built-in fetch and WebSocket; no npm dependency.
const fs=require('node:fs');
const path=require('node:path');
const cp=require('node:child_process');
const BASE='http://127.0.0.1:9223';
const HOME='C:\\TTiTTulares';
const JOB_DIR=path.join(HOME,'editorial-tab-watch');
const LOG=path.join(HOME,'editorial-tab-watch.log');
const LOCK=path.join(JOB_DIR,'watcher.lock');
const SAMPLE_MS=30000;
const CLOSE_AFTER_MS=9*60000;
const STABLE_MS=5*60000;
const MAX_JOB_MS=3*3600000;
const OLD_JOB_POLL_MS=5*60000;
const LANDING_MIN_AGE_MS=20*60000;
const LANDING_IDLE_MS=6*60000;
const LANDING_MIN_SAMPLES=3;
// Long-empty registered conversation is a stale candidate, not proof of job completion.
const BLANK_CONVERSATION_MIN_AGE_MS=60*60000;
const BLANK_CONVERSATION_IDLE_MS=12*60000;
const BLANK_CONVERSATION_MIN_SAMPLES=5;
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const log=s=>{try{fs.appendFileSync(LOG,new Date().toISOString()+' '+s+'\n','utf8')}catch{}};
const pidAlive=pid=>{if(!Number.isInteger(pid)||pid<=0)return false;try{process.kill(pid,0);return true}catch(e){return e?.code==='EPERM'}};
const jobFile=id=>path.join(JOB_DIR,id+'.json');
const idOk=id=>/^[a-f0-9-]{16,80}$/i.test(id);
function safeUrl(url){
  try{const u=new URL(url);return u.protocol==='https:'&&u.hostname==='chatgpt.com'&&(/^\/(?:c|g|project)(?:\/|$)/.test(u.pathname)||u.pathname==='/')}
  catch{return false}
}
function imagePins(){
  const ids=new Set();
  for(const n of ['ttittulares-image-tab.json','ttendencias-image-tab.json']){
    try{const j=JSON.parse(fs.readFileSync(path.join(HOME,n),'utf8'));if(j.target_id)ids.add(String(j.target_id))}catch{}
  }
  return ids
}
function readJob(f){try{return JSON.parse(fs.readFileSync(f,'utf8'))}catch{return null}}
function saveJob(f,obj){
  const tmp=f+'.'+process.pid+'.tmp';
  fs.writeFileSync(tmp,JSON.stringify(obj,null,2)+'\n','utf8');
  fs.renameSync(tmp,f);
}
function stopTracking(f,why){
  const j=readJob(f);
  if(j)log('STOP_TRACKING '+String(j.id).slice(0,18)+' '+why);
  try{fs.unlinkSync(f)}catch{}
}
async function targets(){
  const r=await fetch(BASE+'/json/list',{signal:AbortSignal.timeout(7000),cache:'no-store'});
  if(!r.ok)throw Error('CDP HTTP '+r.status);
  const data=await r.json();
  if(!Array.isArray(data))throw Error('CDP target list invalid');
  return data
}
async function inspect(t){
  return await new Promise((resolve,reject)=>{
    if(typeof WebSocket!=='function'||!t.webSocketDebuggerUrl)return reject(Error('No CDP WebSocket'));
    let ws,done=false;
    const timer=setTimeout(()=>finish(Error('CDP inspector timeout')),7000);
    function finish(err,value){
      if(done)return;done=true;clearTimeout(timer);try{ws&&ws.close()}catch{}
      err?reject(err):resolve(value)
    }
    // Return only status and a numeric fingerprint. Never persist chat contents.
    // Avoid forcing layout on long answers: textContent is cheaper than innerText.
    const expression=`(()=>{const allMessages=document.querySelectorAll('[data-message-author-role]');const a=document.querySelectorAll('[data-message-author-role="assistant"]');const last=a.length?a[a.length-1]:null;const s=String(last?.textContent||'');const tail=s.slice(-8192);let hash=5381;for(let i=0;i<tail.length;i++)hash=((hash<<5)+hash+tail.charCodeAt(i))|0;const stop=[...document.querySelectorAll('button')].some(x=>/^(stop|detener|parar|cancelar)(\\b|\\s)/i.test(String(x.getAttribute('aria-label')||x.getAttribute('title')||'')))||!!document.querySelector('button[data-testid="stop-button"]');const busy=stop||!!document.querySelector('[aria-busy="true"]');const editor=document.querySelector('#prompt-textarea,[data-testid="prompt-textarea"],textarea,[contenteditable="true"][role="textbox"]');const draft=String(editor?.textContent||editor?.value||'').trim();return {url:location.href,ready:document.readyState,assistantCount:a.length,messageCount:allMessages.length,assistantChars:s.length,fingerprint:s.length+':'+hash,busy,draftChars:draft.length,focused:document.hasFocus()}})()`;
    try{
      ws=new WebSocket(t.webSocketDebuggerUrl);
      ws.addEventListener('open',()=>{
        try{ws.send(JSON.stringify({id:12,method:'Runtime.evaluate',params:{expression,returnByValue:true}}))}
        catch(e){finish(e)}
      },{once:true});
      ws.addEventListener('message',e=>{
        try{const m=JSON.parse(String(e.data));if(m.id!==12)return;
          if(m.error)throw Error(String(m.error.message||'CDP Runtime error'));
          const val=m.result?.result?.value;
          if(!val)throw Error('No browser status');
          finish(null,val);
        }catch(err){finish(err)}
      });
      ws.addEventListener('error',()=>finish(Error('CDP WebSocket error')),{once:true});
      ws.addEventListener('close',()=>finish(Error('CDP WebSocket closed')),{once:true});
    }catch(e){finish(e)}
  })
}
function lock(){
  fs.mkdirSync(JOB_DIR,{recursive:true});
  for(let i=0;i<2;i++){
    try{
      const fd=fs.openSync(LOCK,'wx');
      try{fs.writeFileSync(fd,JSON.stringify({pid:process.pid,started:Date.now()}))}
      finally{fs.closeSync(fd)}
      return true;
    }catch(e){
      if(e.code!=='EEXIST')throw e;
      const old=readJob(LOCK);
      if(old&&pidAlive(old.pid))return false;
      // Do not delete a lock while a new daemon is still writing it.
      if(!old&&Date.now()-fs.statSync(LOCK).mtimeMs<6000)return false;
      try{fs.unlinkSync(LOCK)}catch{}
    }
  }
  return false
}
function unlock(){
  const entry=readJob(LOCK);
  if(entry?.pid===process.pid)try{fs.unlinkSync(LOCK)}catch{}
}
function register(id,url){
  if(!idOk(id)||!safeUrl(url))throw Error('Invalid tab id or conversation URL');
  fs.mkdirSync(JOB_DIR,{recursive:true});
  const f=jobFile(id);
  const current=readJob(f);
  if(!current)saveJob(f,{id,url,created:Date.now(),firstStable:0,lastFingerprint:'',failures:0});
  log('REGISTER '+id.slice(0,18));
  const child=cp.spawn(process.execPath,[__filename,'--daemon'],{detached:true,stdio:'ignore',windowsHide:true});
  child.unref();
}
async function sweep(){
  const jobs=fs.readdirSync(JOB_DIR).filter(n=>/^[a-f0-9-]{16,80}\.json$/i.test(n));
  if(!jobs.length)return 0;
  const all=await targets();
  const pinned=imagePins();
  for(const name of jobs){
    const f=path.join(JOB_DIR,name),j=readJob(f);
    if(!j||!idOk(j.id)||!safeUrl(j.url)){stopTracking(f,'invalid_job');continue}
    if(pinned.has(j.id)){stopTracking(f,'pinned_image_tab');continue}
    // Never forget a tracked tab solely because it is more than three hours old.
    // Unverified tabs were previously dropped from tracking and left open forever.
    // Keep monitoring older jobs at a reduced frequency; close ONLY once the
    // existing completed-response checks below confirm that it is safe.
    if(Date.now()-j.created>MAX_JOB_MS){
      const now=Date.now();
      if(now-Number(j.lastOldCheck||0)<OLD_JOB_POLL_MS)continue;
      j.lastOldCheck=now;
      saveJob(f,j);
    }
    const t=all.find(x=>x.id===j.id&&x.type==='page');
    if(!t){stopTracking(f,'target_missing');continue}
    if(!safeUrl(t.url)){stopTracking(f,'changed_to_nonconversation_LEFT_OPEN');continue}
    let s;
    try{s=await inspect(t)}catch(e){log('INSPECT_RETRY '+j.id.slice(0,18)+' '+String(e.message||e));continue}
    // ChatGPT moves a fresh / or /g/ project landing page into a /c/ URL
    // after submission. Adopt that ONE initial transition for this owned tab.
    // Subsequent navigation to another chat stops tracking without closing it.
    if(!safeUrl(s.url)){stopTracking(f,'navigated_outside_chat_LEFT_OPEN');continue}
    if(new URL(s.url).pathname!==new URL(j.url).pathname){
      const from=new URL(j.url).pathname;
      const to=new URL(s.url).pathname;
      const landing=from==='/'||from.startsWith('/g/')||from.startsWith('/project/');
      const conversation=/(?:^|\/)c\/[^/]+/.test(to);
      if(!j.followedRoute&&landing&&conversation){
        j.url=s.url;
        j.followedRoute=true;
        j.firstStable=0;
        j.lastFingerprint='';
        saveJob(f,j);
        log('ADOPT_CONVERSATION '+j.id.slice(0,18));
      }else{stopTracking(f,'navigated_elsewhere_LEFT_OPEN');continue}
    }
    // A temporary project landing may remain at /g/g-p-... after the actual
    // message was submitted in a new conversation. These tabs never acquire
    // assistant text. Only consider the launcher's REGISTERED target.
    const pathname=new URL(s.url).pathname;
    const ownedLanding=/^\/g\/g-p-[a-z0-9-]+\/?$/i.test(pathname)||
      /^\/project\/[a-z0-9-]+\/?$/i.test(pathname);
    if(ownedLanding){
      const idle=s.ready==='complete'&&!s.busy&&s.draftChars===0&&s.messageCount===0;
      if(!idle){
        if(j.landingIdleSince||j.landingSamples){
          j.landingIdleSince=0;j.landingSamples=0;saveJob(f,j);
        }
        continue;
      }
      const now=Date.now();
      if(!j.landingIdleSince){
        j.landingIdleSince=now;
        log('LANDING_IDLE_START '+j.id.slice(0,18)+' age_min='+Math.floor((now-j.created)/60000));
      }
      if(!j.lastLandingSampleAt||now-j.lastLandingSampleAt>=60000){
        j.landingSamples=Number(j.landingSamples||0)+1;
        j.lastLandingSampleAt=now;
        saveJob(f,j);
      }
      if(now-j.created<LANDING_MIN_AGE_MS||
         now-j.landingIdleSince<LANDING_IDLE_MS||
         j.landingSamples<LANDING_MIN_SAMPLES)continue;
      // Recheck actual target, URL, message state and pins just before closure.
      const refreshed=(await targets()).find(x=>x.id===j.id&&x.type==='page');
      if(!refreshed||imagePins().has(j.id)||refreshed.url!==s.url)continue;
      let verify;
      try{verify=await inspect(refreshed)}catch{continue}
      const verifyPath=verify.url?new URL(verify.url).pathname:'';
      if(verifyPath!==pathname||verify.busy||verify.ready!=='complete'||
         verify.draftChars!==0||verify.messageCount!==0)continue;
      const result=await fetch(BASE+'/json/close/'+encodeURIComponent(j.id),{signal:AbortSignal.timeout(6000)});
      if(result.ok){
        log('CLOSED_IDLE_PROJECT_LANDING '+j.id.slice(0,18)+' age_min='+Math.floor((now-j.created)/60000));
        stopTracking(f,'closed_verified_idle_project_landing');
      }else log('LANDING_CLOSE_RETRY '+j.id.slice(0,18)+' HTTP '+result.status);
      continue;
    }
    // Chrome may route a registered project landing into /g/<project>/c/<id>
    // while its React message list stays unmounted. It must NOT be considered
    // "complete" merely because zero messages are rendered. Instead, after
    // an hour, check that this owned target remains blank for 12 more minutes.
    const blankConversation=/(?:^|\/)c\/[^/]+/.test(pathname);
    const blankIdle=blankConversation&&s.ready==='complete'&&s.messageCount===0&&
      s.assistantCount===0&&!s.busy&&s.draftChars===0&&s.focused===false;
    if(blankIdle){
      const now=Date.now();
      if(!j.blankIdleSince){
        j.blankIdleSince=now;
        j.blankSamples=0;
        log('BLANK_CONVERSATION_OBSERVED '+j.id.slice(0,18)+' age_min='+Math.floor((now-j.created)/60000));
      }
      if(!j.lastBlankSampleAt||now-j.lastBlankSampleAt>=60000){
        j.blankSamples=Number(j.blankSamples||0)+1;
        j.lastBlankSampleAt=now;
        saveJob(f,j);
      }
      if(now-j.created<BLANK_CONVERSATION_MIN_AGE_MS||
         now-j.blankIdleSince<BLANK_CONVERSATION_IDLE_MS||
         j.blankSamples<BLANK_CONVERSATION_MIN_SAMPLES)continue;
      const refreshed=(await targets()).find(x=>x.type==='page'&&x.id===j.id);
      if(!refreshed||imagePins().has(j.id)||refreshed.url!==s.url)continue;
      let verify;
      try{verify=await inspect(refreshed)}catch{continue}
      if(verify.url!==s.url||verify.ready!=='complete'||verify.messageCount!==0||
         verify.assistantCount!==0||verify.busy||verify.draftChars!==0||
         verify.focused!==false)continue;
      const res=await fetch(BASE+'/json/close/'+encodeURIComponent(j.id),{signal:AbortSignal.timeout(6000)});
      if(res.ok){
        log('CLOSED_STALE_BLANK_CONVERSATION '+j.id.slice(0,18)+' age_min='+Math.floor((now-j.created)/60000));
        stopTracking(f,'closed_verified_stale_blank_conversation');
      }else log('BLANK_CLOSE_RETRY '+j.id.slice(0,18)+' HTTP '+res.status);
      continue;
    }
    if(j.blankIdleSince){
      j.blankIdleSince=0;j.blankSamples=0;j.lastBlankSampleAt=0;saveJob(f,j);
    }
    if(s.busy||s.draftChars>0||s.ready!=='complete'||s.assistantCount<1||s.assistantChars<20){
      j.firstStable=0;j.lastFingerprint='';saveJob(f,j);continue
    }
    if(j.lastFingerprint!==s.fingerprint){j.lastFingerprint=s.fingerprint;j.firstStable=Date.now();saveJob(f,j);continue}
    const elapsed=Date.now()-j.created;
    if(elapsed<CLOSE_AFTER_MS||Date.now()-j.firstStable<STABLE_MS)continue;
    // Recheck active target and current status immediately before closing.
    const refreshed=(await targets()).find(x=>x.id===j.id&&x.type==='page');
    if(!refreshed||imagePins().has(j.id)||!safeUrl(refreshed.url))continue;
    let verify;
    try{verify=await inspect(refreshed)}catch{continue}
    if(verify.busy||verify.draftChars>0||verify.ready!=='complete'||verify.assistantChars<20||verify.fingerprint!==s.fingerprint||verify.url!==s.url)continue;
    const response=await fetch(BASE+'/json/close/'+encodeURIComponent(j.id),{signal:AbortSignal.timeout(6000)});
    if(response.ok){
      log('CLOSED_COMPLETED_TAB '+j.id.slice(0,18)+' age_min='+Math.floor(elapsed/60000));
      stopTracking(f,'closed_after_completed_response');
    }else log('CLOSE_RETRY '+j.id.slice(0,18)+' HTTP '+response.status)
  }
  return fs.readdirSync(JOB_DIR).filter(n=>/^[a-f0-9-]{16,80}\.json$/i.test(n)).length;
}
async function daemon(){
  if(!lock())return;
  log('WATCHER_START pid='+process.pid);
  try{
    let emptyCount=0;
    while(true){
      let remaining;
      try{remaining=await sweep();emptyCount=remaining?0:emptyCount+1}
      catch(e){log('WATCHER_ERROR '+String(e.message||e));emptyCount=0}
      if(emptyCount>=3)break;
      await sleep(SAMPLE_MS)
    }
  }finally{unlock();log('WATCHER_STOP pid='+process.pid)}
}
(async()=>{
  if(process.argv[2]==='--register'){register(String(process.argv[3]||''),String(process.argv[4]||''))}
  else if(process.argv[2]==='--daemon')await daemon();
  else {console.log('TT editorial tab watcher. Only --register and --daemon are supported.')}
})().catch(e=>{log('FATAL '+String(e.stack||e));process.exitCode=1});
