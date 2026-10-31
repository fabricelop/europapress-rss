'use strict';
// Consumes the EXISTING, command-scoped ImageGen result. Never submits prompts.
// Reads only its own temporary tab on the relay's already-running Chrome 9234.
const fs=require('node:fs');
const path=require('node:path');
const crypto=require('node:crypto');
const {execFileSync}=require('node:child_process');
const BASE='http://127.0.0.1:9234';
const ROOT=path.join(__dirname,'ttendencias-web-images');
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const safeID=v=>/^[A-Za-z0-9._-]{3,160}$/.test(String(v||''));
function chatURL(value){
  try{const u=new URL(value);return u.origin==='https://chatgpt.com'&&/^\/(?:c\/[a-f0-9-]+|g\/[^/]+\/c\/[a-f0-9-]+)\/?$/i.test(u.pathname)?u.origin+u.pathname:null;}catch{return null;}
}
function protect(value,decode=false){
  if(process.platform!=='win32')throw Error('Windows DPAPI required');
  const code=decode?
    '$s=ConvertTo-SecureString ([Console]::In.ReadToEnd());$p=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($s);try{[Console]::Write([Runtime.InteropServices.Marshal]::PtrToStringBSTR($p))}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p)}':
    '$s=ConvertTo-SecureString ([Console]::In.ReadToEnd()) -AsPlainText -Force;[Console]::Write((ConvertFrom-SecureString $s))';
  return execFileSync('powershell.exe',['-NoProfile','-NonInteractive','-Command',code],{input:value,encoding:'utf8',windowsHide:true,timeout:15000,maxBuffer:65536}).trim();
}
function atomic(file,value){const tmp=file+'.'+process.pid+'.tmp';fs.writeFileSync(tmp,JSON.stringify(value,null,2),{mode:0o600});fs.renameSync(tmp,file);}
function enroll({job,commandId,targetId,conversationUrl,browserTargetId,secret}){
  const url=chatURL(conversationUrl);
  if((!url&&!safeID(browserTargetId))||!safeID(targetId)||!safeID(commandId)||String(job.command_id)!==commandId||String(job.target_id||job.trend_id)!==targetId||String(secret||'').length<32)throw Error('invalid web-image identity');
  const explanation=String(job.context_snapshot?.explanation||'').trim();
  if(!explanation)throw Error('missing authoritative explanation');
  fs.mkdirSync(ROOT,{recursive:true});const file=path.join(ROOT,commandId+'.json');
  if(fs.existsSync(file)){
    const old=JSON.parse(fs.readFileSync(file,'utf8'));
    if(!old.conversation_url&&url&&old.target_id===targetId&&old.command_id===commandId){atomic(file,{...old,conversation_url:url});}
    return;
  }
  atomic(file,{version:1,target_id:targetId,command_id:commandId,revision:Number(job.revision||0),conversation_url:url,browser_target_id:String(browserTargetId||''),
    explanation_sha256:crypto.createHash('sha256').update(explanation).digest('hex'),
    secret_dpapi:protect(secret),created_at:new Date().toISOString(),status:'waiting',attempts:0});
}
class CDP{
  constructor(url){this.url=url;this.seq=0;this.pending=new Map();}
  async open(){this.ws=new WebSocket(this.url);await new Promise((ok,bad)=>{const t=setTimeout(()=>bad(Error('CDP connection timeout')),5000);this.ws.addEventListener('open',()=>{clearTimeout(t);ok();},{once:true});this.ws.addEventListener('error',()=>{clearTimeout(t);bad(Error('CDP connection failed'));},{once:true});});this.ws.addEventListener('message',e=>{let m;try{m=JSON.parse(String(e.data));}catch{return;}const p=this.pending.get(m.id);if(!p)return;this.pending.delete(m.id);clearTimeout(p.timer);m.error?p.bad(Error('CDP command failed')):p.ok(m.result);});}
  call(method,params={},timeout=12000){const id=++this.seq;return new Promise((ok,bad)=>{const timer=setTimeout(()=>{this.pending.delete(id);bad(Error('CDP command timeout'));},timeout);this.pending.set(id,{ok,bad,timer});this.ws.send(JSON.stringify({id,method,params}));});}
  async evaluate(expression){const r=await this.call('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});if(r.exceptionDetails)throw Error('Image inspection failed');return r.result?.value;}
  close(){for(const p of this.pending.values()){clearTimeout(p.timer);p.bad(Error('CDP closed'));}this.pending.clear();try{this.ws?.close();}catch{}}
}
async function http(url,options={}){const r=await fetch(url,{...options,signal:AbortSignal.timeout(15000)});if(!r.ok)throw Error('HTTP '+r.status);return r.json();}
// The user turn carrying this exact command is the only permitted image scope.
// Rejects a later user turn, avatars, previews and unfinished generations.
function rasterProbe(command){return `(async()=>{
 const command=${JSON.stringify(command)};
 const users=[...document.querySelectorAll('[data-message-author-role="user"]')];
 const user=users.find(x=>String(x.innerText||'').includes(command));
 if(!user)return {ready:false,reason:'command_not_visible'};
 if(users.indexOf(user)!==users.length-1)return {ready:false,reason:'later_user_turn'};
 if(document.querySelector('button[data-testid="stop-button"],button[aria-label*="Stop" i],button[aria-label*="Detener" i]'))return {ready:false,reason:'generating'};
 const images=[...document.querySelectorAll('[data-message-author-role="assistant"] img')].filter(img=>
  Boolean(user.compareDocumentPosition(img)&Node.DOCUMENT_POSITION_FOLLOWING)&&img.complete&&img.naturalWidth>=1024&&img.naturalHeight>=576&&
  !/avatar|emoji|icon|profile/i.test(String(img.alt||'')));
 if(images.length!==1)return {ready:false,reason:'ambiguous_or_missing_raster'};
 const img=images[0];const response=await fetch(img.currentSrc||img.src,{credentials:'include'});
 if(!response.ok)return {ready:false,reason:'raster_fetch_failed'};
 const blob=await response.blob();
 if(!/^image\\/(png|jpeg|webp)$/.test(blob.type)||blob.size<12000||blob.size>8388608)return {ready:false,reason:'raster_size_or_type'};
 const bytes=new Uint8Array(await blob.arrayBuffer());let binary='';for(let i=0;i<bytes.length;i+=32768)binary+=String.fromCharCode(...bytes.subarray(i,i+32768));
 return {ready:true,dataUrl:'data:'+blob.type+';base64,'+btoa(binary),width:img.naturalWidth,height:img.naturalHeight};
})()`;}
function sameContext(task,job){return String(job.command_id||'')===task.command_id&&String(job.target_id||job.trend_id||'')===task.target_id&&Number(job.revision||0)===task.revision&&crypto.createHash('sha256').update(String(job.context_snapshot?.explanation||'').trim()).digest('hex')===task.explanation_sha256;}
async function confirmedInMain(task,job){
  const manual=await http('https://raw.githubusercontent.com/fabricelop/europapress-rss/main/trends/telegram-manual-explained.json?t='+Date.now());
  const current=(manual.items||[]).filter(x=>String(x.id||'')===task.target_id)
    .sort((a,b)=>Number(b.revision||0)-Number(a.revision||0)||Date.parse(b.explained_at||0)-Date.parse(a.explained_at||0))[0];
  if(!current||Number(current.revision||0)!==task.revision||
    crypto.createHash('sha256').update(String(current.explanation||'').trim()).digest('hex')!==task.explanation_sha256){
    return {status:'obsolete',reason:'editorial_context_changed'};
  }
  const ai=current.ai_image||{};
  const url=String(ai.url||'');
  const sha=String(ai.sha256||ai.content_sha256||current.ai_image_sha256||'');
  const guard=ai.context_guard||{};
  const command=String(guard.command_id||ai.command_id||current.ai_image_command_id||'');
  const expected=String(job.upload_sha256||task.sha256||'');
  const provenanceMatch=(!!sha&&sha===expected)||(!!command&&command===task.command_id);
  if((job.status==='DONE'||task.upload_accepted_at)&&expected&&ai.generated===true&&/^https:\/\//i.test(url)&&
     /\/generated-images\//i.test(url)&&provenanceMatch&&(!sha||sha===expected)&&(!command||command===task.command_id)&&
     (!guard.trend_id||String(guard.trend_id)===task.target_id)&&(!ai.target_id||String(ai.target_id)===task.target_id)&&
     (guard.revision==null||Number(guard.revision)===task.revision)&&(ai.revision==null||Number(ai.revision)===task.revision)){
    return {status:'published',sha256:expected,image_path:String(job.image_path||''),image_url:url};
  }
  return {status:'waiting',reason:'remote_image_not_confirmed'};
}
async function rememberConversation({job,commandId,targetId,browserTargetId,secret}){
  // Preserve the upload capability BEFORE clicking Send. Discover only this
  // pinned target's durable URL; never select another conversation by name.
  enroll({job,commandId,targetId,browserTargetId,secret});
  try{
    const pages=await http('http://127.0.0.1:9223/json/list');
    const own=pages.find(x=>String(x.id||'')===String(browserTargetId));
    if(own&&chatURL(own.url))enroll({job,commandId,targetId,browserTargetId,secret,conversationUrl:own.url});
  }catch{}
}
async function consume(task){
  const job=await http('https://raw.githubusercontent.com/fabricelop/europapress-rss/control/ttendencias-run-trigger/trends/image-runs/jobs/'+encodeURIComponent(task.target_id)+'.json?t='+Date.now());
  if(!sameContext(task,job))return {status:'obsolete',reason:'job_identity_changed'};
  if((job.status==='DONE'&&job.upload_sha256)||task.upload_accepted_at)return confirmedInMain(task,job);
  if(['CANCELLED','SUPERSEDED'].includes(String(job.status).toUpperCase()))return {status:'obsolete',reason:'image_job_terminal'};
  // ERROR is not proof that no image exists. This consumer NEVER generates:
  // it can only read a raster after this command's exact user turn.
  if(!chatURL(task.conversation_url)){
    try{
      const pages=await http('http://127.0.0.1:9223/json/list');
      const own=pages.find(x=>String(x.id||'')===String(task.browser_target_id||''));
      const url=chatURL(own?.url);
      if(!url)return {status:'waiting',reason:'awaiting_command_conversation'};
      task.conversation_url=url;
    }catch{return {status:'waiting',reason:'conversation_discovery_unavailable'};}
  }
  try{
    const contract=await http('https://tt-control.fabricelop.workers.dev/api/ttendencias-run-status?view=web-image-contract');
    if(contract.web_image_receipt!==2)return {status:'waiting',reason:'receiver_update_pending'};
  }catch{return {status:'waiting',reason:'receiver_update_pending'};}
  // Verify the existing relay browser is reachable; never start or restart Chrome.
  await http(BASE+'/json/version');
  const pages=await http(BASE+'/json/list');
  if(!pages.some(x=>x.type==='page'&&/^https:\/\/chatgpt\.com\//.test(x.url||'')))throw Error('relay_browser_not_signed_in_or_missing');
  const browser=await http(BASE+'/json/version');let browserCDP,cdp,ownedTarget;
  try{
    browserCDP=new CDP(browser.webSocketDebuggerUrl);await browserCDP.open();
    const made=await browserCDP.call('Target.createTarget',{url:task.conversation_url,background:true});ownedTarget=made.targetId;
    for(let n=0;n<5;n++){
      const targets=await http(BASE+'/json/list');const own=targets.find(x=>x.id===ownedTarget);
      if(own?.webSocketDebuggerUrl){cdp=new CDP(own.webSocketDebuggerUrl);await cdp.open();break;}
      await sleep(500);
    }
    if(!cdp)throw Error('export_tab_not_ready');
    let raster;
    for(let n=0;n<6;n++){await sleep(1500);raster=await cdp.evaluate(rasterProbe(task.command_id));if(raster?.ready)break;}
    if(!raster?.ready)return {status:'waiting',reason:raster?.reason||'raster_not_ready'};
    // Fresh job identity check immediately before sending raster bytes.
    const fresh=await http('https://raw.githubusercontent.com/fabricelop/europapress-rss/control/ttendencias-run-trigger/trends/image-runs/jobs/'+encodeURIComponent(task.target_id)+'.json?t='+Date.now());
    if(!sameContext(task,fresh))return {status:'obsolete'};
    const manual=await http('https://raw.githubusercontent.com/fabricelop/europapress-rss/main/trends/telegram-manual-explained.json?t='+Date.now());
    const current=(manual.items||[]).filter(x=>String(x.id)===task.target_id).sort((a,b)=>Number(b.revision||0)-Number(a.revision||0)||Date.parse(b.explained_at||0)-Date.parse(a.explained_at||0))[0];
    if(!current||Number(current.revision||0)!==task.revision||crypto.createHash('sha256').update(String(current.explanation||'').trim()).digest('hex')!==task.explanation_sha256)return {status:'obsolete'};
    const response=await fetch('https://tt-control.fabricelop.workers.dev/api/ttendencias-run',{method:'POST',headers:{'content-type':'application/json'},signal:AbortSignal.timeout(45000),body:JSON.stringify({task:'web_image_upload',context_explanation_sha256:task.explanation_sha256,target_id:task.target_id,command_id:task.command_id,upload_secret:protect(task.secret_dpapi,true),image_data_url:raster.dataUrl,capture:{method:'original-fetch-img-web-consumer',width:raster.width,height:raster.height}})});
    const result=await response.json();
    if(response.ok&&result.status==='DONE')return {status:'waiting',reason:'upload_accepted_awaiting_main_confirmation',sha256:String(result.sha256||''),image_path:String(result.image_path||''),upload_accepted_at:new Date().toISOString()};
    if([401,409,422].includes(response.status))return {status:'rejected',reason:String(result.error||'context_rejected').slice(0,140)};
    throw Error('image_upload_HTTP_'+response.status);
  }finally{
    cdp?.close();
    if(ownedTarget)try{await browserCDP?.call('Target.closeTarget',{targetId:ownedTarget});}catch{}
    browserCDP?.close();
  }
}
async function telemetry(task,result){
  try{
    await fetch('https://tt-control.fabricelop.workers.dev/api/ttendencias-run',{method:'POST',headers:{'content-type':'application/json'},signal:AbortSignal.timeout(10000),body:JSON.stringify({task:'web_image_telemetry',target_id:task.target_id,command_id:task.command_id,upload_secret:protect(task.secret_dpapi,true),stage:result.status,reason:String(result.reason||'confirmed').slice(0,140),version:2})});
  }catch{}
}
function dueTasks(tasks,now){return tasks.filter(x=>x.task.status==='waiting')
  .filter(x=>!Number.isFinite(Date.parse(x.task.next_check_at||''))||Date.parse(x.task.next_check_at)<=now)
  .sort((a,b)=>Date.parse(a.task.checked_at||a.task.created_at||0)-Date.parse(b.task.checked_at||b.task.created_at||0));}
async function once(){
  fs.mkdirSync(ROOT,{recursive:true});const lock=path.join(ROOT,'publisher.lock');
  try{const fd=fs.openSync(lock,'wx');fs.writeSync(fd,JSON.stringify({pid:process.pid,at:Date.now()}));fs.closeSync(fd);}catch{
    try{const previous=JSON.parse(fs.readFileSync(lock));process.kill(previous.pid,0);return;}catch{try{fs.unlinkSync(lock);}catch{}return;}
  }
  try{
    const now=Date.now();
    // A missing image must not monopolize the queue. Each waiting item has its
    // own backoff; process the oldest due check, not the oldest original job.
    const tasks=fs.readdirSync(ROOT).filter(x=>x.endsWith('.json')).flatMap(name=>{
      try{return [{file:path.join(ROOT,name),task:JSON.parse(fs.readFileSync(path.join(ROOT,name),'utf8'))}];}catch{return [];}
    });
    const due=dueTasks(tasks,now);
    for(const {file,task} of due.slice(0,1)){
      if(!safeID(task.target_id)||!safeID(task.command_id)||(!chatURL(task.conversation_url)&&!safeID(task.browser_target_id))||
        !/^[a-f0-9]{64}$/.test(String(task.explanation_sha256||''))||
        !task.secret_dpapi){
        atomic(file,{...task,status:'rejected',reason:'invalid_enrollment',secret_dpapi:undefined});
        console.log('TTENDENCIAS_WEB_IMAGE '+String(task.target_id||'?')+' rejected_invalid_enrollment');
        continue;
      }
      // Keep pending images recoverable for three days without ever allowing
      // a stuck/slow generation to delay later images.
      if(!Number.isFinite(Date.parse(task.created_at||''))||now-Date.parse(task.created_at)>72*3600000){
        atomic(file,{...task,status:'expired',reason:'image_not_confirmed_within_72h',secret_dpapi:undefined});
        console.log('TTENDENCIAS_WEB_IMAGE '+task.target_id+' expired_without_confirmation');
        continue;
      }
      let result;
      try{result=await consume(task);}
      catch(e){result={status:'waiting',reason:String(e&&e.message||'export_unavailable_retry').replace(/https?:\/\/\S+/g,'[url]').slice(0,140)};}
      const report=task.status!==result.status||task.reason!==result.reason||
        !task.telemetry_at||Date.now()-Date.parse(task.telemetry_at)>15*60000;
      if(report)await telemetry(task,result);
      const count=(task.attempts||0)+1;
      const delay=Math.min(10*60000,Math.max(60000,60000*Math.min(10,Math.ceil(count/6))));
      const next={...task,...result,attempts:count,checked_at:new Date().toISOString(),
        next_check_at:new Date(Date.now()+delay).toISOString(),
        telemetry_at:report?new Date().toISOString():task.telemetry_at};
      if(next.status!=='waiting'){delete next.secret_dpapi;delete next.next_check_at;}
      atomic(file,next);
      console.log('TTENDENCIAS_WEB_IMAGE '+task.target_id+' '+next.status+' reason='+String(next.reason||'confirmed').slice(0,90));
    }
  }finally{try{fs.unlinkSync(lock);}catch{}}
}
module.exports={chatURL,enroll,rememberConversation,rasterProbe,sameContext,confirmedInMain,dueTasks,consume};
if(require.main===module)once().catch(()=>{console.error('TTENDENCIAS_WEB_IMAGE exporter unavailable');process.exitCode=1;});
