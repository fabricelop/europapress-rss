'use strict';
// Consumes the EXISTING, command-scoped ImageGen result. Never submits prompts.
// Own temporary tabs belong only to the relay browser. On the generator we
// may inspect an existing exact conversation, but NEVER create/navigate tabs.
const fs=require('node:fs');
const path=require('node:path');
const crypto=require('node:crypto');
const {execFileSync,spawn}=require('node:child_process');
const BASE='http://127.0.0.1:9234';
const GENERATOR_BASE='http://127.0.0.1:9223';
const WEB_CAPTURE_VERSION=5;
const WEB_DELIVERY_VERSION=6;
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
// Only starts the separate consumer AFTER enrollment. No generation command,
// browser navigation or upload secret is passed to the child process.
function wakePublisher(){
  try{
    const lock=JSON.parse(fs.readFileSync(path.join(ROOT,'watch.lock'),'utf8'));
    if(Date.now()-Number(lock.at)<360000){process.kill(lock.pid,0);return;}
  }catch{}
  try{
    const env={...process.env};delete env.TT_IMAGE_UPLOAD_SECRET;
    const child=spawn(process.execPath,[__filename,'--watch'],{detached:true,stdio:'ignore',windowsHide:true,env});
    child.on('error',()=>{});child.unref();
  }catch{}
}
function enroll({job,commandId,targetId,conversationUrl,browserTargetId,secret,startPublisher=true}){
  const url=chatURL(conversationUrl);
  if((!url&&!safeID(browserTargetId))||!safeID(targetId)||!safeID(commandId)||String(job.command_id)!==commandId||String(job.target_id||job.trend_id)!==targetId||String(secret||'').length<32)throw Error('invalid web-image identity');
  const explanation=String(job.context_snapshot?.explanation||'').trim();
  if(!explanation)throw Error('missing authoritative explanation');
  fs.mkdirSync(ROOT,{recursive:true});const file=path.join(ROOT,commandId+'.json');
  if(fs.existsSync(file)){
    const old=JSON.parse(fs.readFileSync(file,'utf8'));
    if(!old.conversation_url&&url&&old.target_id===targetId&&old.command_id===commandId){atomic(file,{...old,conversation_url:url});}
    if(startPublisher)wakePublisher();return;
  }
  atomic(file,{version:1,target_id:targetId,command_id:commandId,revision:Number(job.revision||0),conversation_url:url,browser_target_id:String(browserTargetId||''),
    explanation_sha256:crypto.createHash('sha256').update(explanation).digest('hex'),
    secret_dpapi:protect(secret),created_at:new Date().toISOString(),status:'waiting',attempts:0});
  if(startPublisher)wakePublisher();
}
class CDP{
  constructor(url){this.url=url;this.seq=0;this.pending=new Map();}
  async open(){this.ws=new WebSocket(this.url);await new Promise((ok,bad)=>{const t=setTimeout(()=>bad(Error('CDP connection timeout')),5000);this.ws.addEventListener('open',()=>{clearTimeout(t);ok();},{once:true});this.ws.addEventListener('error',()=>{clearTimeout(t);bad(Error('CDP connection failed'));},{once:true});});this.ws.addEventListener('message',e=>{let m;try{m=JSON.parse(String(e.data));}catch{return;}const p=this.pending.get(m.id);if(!p)return;this.pending.delete(m.id);clearTimeout(p.timer);m.error?p.bad(Error('CDP command failed')):p.ok(m.result);});}
  call(method,params={},timeout=12000){const id=++this.seq;return new Promise((ok,bad)=>{const timer=setTimeout(()=>{this.pending.delete(id);bad(Error('CDP command timeout'));},timeout);this.pending.set(id,{ok,bad,timer});this.ws.send(JSON.stringify({id,method,params}));});}
  async evaluate(expression){const r=await this.call('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});if(r.exceptionDetails)throw Error('Image inspection failed');return r.result?.value;}
  close(){for(const p of this.pending.values()){clearTimeout(p.timer);p.bad(Error('CDP closed'));}this.pending.clear();try{this.ws?.close();}catch{}}
}
function networkStage(url){
  if(url.includes('127.0.0.1:9234'))return url.includes('/json/version')?'relay_version':'relay_targets';
  if(url.includes('127.0.0.1:9223'))return url.includes('/json/version')?'generator_version':'generator_targets';
  if(url.includes('image-runs/jobs/')||url.includes('view=image-job'))return 'image_job';
  if(url.includes('telegram-manual-explained')||url.includes('view=state'))return 'editorial_state';
  return 'receiver';
}
async function http(url,options={}){
  try{const r=await fetch(url,{...options,signal:AbortSignal.timeout(15000)});if(!r.ok)throw Error('HTTP_'+r.status);return await r.json();}
  catch(e){const code=String(e?.cause?.code||e?.message||'unavailable').replace(/[^A-Za-z0-9_ -]/g,'').slice(0,70);throw Error(networkStage(url)+'_'+code);}
}
async function readImageJob(task){
  let last;
  for(const url of [
    'https://raw.githubusercontent.com/fabricelop/europapress-rss/control/ttendencias-run-trigger/trends/image-runs/jobs/'+encodeURIComponent(task.target_id)+'.json?t='+Date.now(),
    'https://tt-control.fabricelop.workers.dev/api/ttendencias-run-status?view=image-job&strong=1&id='+encodeURIComponent(task.target_id)
  ]){try{const doc=await http(url);if(doc.command_id&&doc.context_snapshot){if(sameContext(task,doc))return doc;last=doc;}}catch(e){last=e;}}
  if(last&&!(last instanceof Error))return last;
  throw last||Error('image_job_unavailable');
}
async function readEditorialState(){
  try{return await http('https://raw.githubusercontent.com/fabricelop/europapress-rss/main/trends/telegram-manual-explained.json?t='+Date.now());}
  catch{
    const state=await http('https://tt-control.fabricelop.workers.dev/api/ttendencias-control?view=state&fresh=1');
    if(!Array.isArray(state.explained?.items))throw Error('editorial_state_invalid');
    return state.explained;
  }
}
async function selectExistingBrowser(){
  const failures=[];
  for(const [base,source] of [[BASE,'relay_9234'],[GENERATOR_BASE,'generator_9223']]){
    try{
      const browser=await http(base+'/json/version');
      if(!browser.webSocketDebuggerUrl)throw Error(source+'_debugger_missing');
      const pages=await http(base+'/json/list');
      if(!Array.isArray(pages)||!pages.some(x=>x.type==='page'&&/^https:\/\/chatgpt\.com\//.test(x.url||'')))throw Error(source+'_chat_page_missing');
      return {base,source,browser};
    }catch(e){failures.push(String(e.message||e));}
  }
  throw Error(failures.join(';').slice(0,140));
}
// The user turn carrying this exact command is the only permitted image scope.
// Rejects a later user turn, avatars, previews and unfinished generations.
function rasterProbe(command){return `(async()=>{
 const command=${JSON.stringify(command)};
 const users=[...document.querySelectorAll('[data-message-author-role="user"]')];
 const user=users.find(x=>String(x.innerText||'').includes(command));
 if(!user){
  if(document.querySelector('[data-testid="login-button"],a[href="/auth/login"]'))return {ready:false,reason:'capture_requires_sign_in'};
  return {ready:false,reason:users.length?'command_not_in_conversation':'conversation_not_loaded'};
 }
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
  const manual=await readEditorialState();
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
function conversationProbe(command){return `(()=>{
 const users=[...document.querySelectorAll('[data-message-author-role="user"]')];
 const last=users[users.length-1];
 return last&&String(last.innerText||'').includes(${JSON.stringify(command)})?location.href:null;
})()`;}
async function discoverConversation(commandId,browserTargetId){
  const pages=await http(GENERATOR_BASE+'/json/list');
  const own=pages.find(x=>String(x.id||'')===String(browserTargetId));
  if(!chatURL(own?.url)||!own.webSocketDebuggerUrl)return null;
  const cdp=new CDP(own.webSocketDebuggerUrl);
  try{await cdp.open();return chatURL(await cdp.evaluate(conversationProbe(commandId)));}
  finally{cdp.close();}
}
async function rememberConversation(input){
  enroll(input);
  const url=await discoverConversation(input.commandId,input.browserTargetId);
  if(!url)return false;
  enroll({...input,conversationUrl:url});
  return true;
}
async function consume(task){
  const job=await readImageJob(task);
  if(!sameContext(task,job))return {status:'obsolete',reason:'job_identity_changed'};
  if((job.status==='DONE'&&job.upload_sha256)||task.upload_accepted_at)return confirmedInMain(task,job);
  if(['CANCELLED','SUPERSEDED'].includes(String(job.status).toUpperCase()))return {status:'obsolete',reason:'image_job_terminal'};
  // ERROR is not proof that no image exists. This consumer NEVER generates:
  // it can only read a raster after this command's exact user turn.
  if(!chatURL(task.conversation_url)){
    try{
      const url=await discoverConversation(task.command_id,task.browser_target_id);
      if(!url)return {status:'waiting',reason:'awaiting_command_conversation'};
      task.conversation_url=url;
    }catch{return {status:'waiting',reason:'conversation_discovery_unavailable'};}
  }
  try{
    const contract=await http('https://tt-control.fabricelop.workers.dev/api/ttendencias-run-status?view=web-image-contract');
    if(contract.web_image_receipt!==2)return {status:'waiting',reason:'receiver_update_pending'};
  }catch{return {status:'waiting',reason:'receiver_update_pending'};}
  // Never create capture tabs in the generator profile. Its renderer already
  // failed before submission in the incident; web delivery must not add churn.
  const capture=await selectExistingBrowser();
  const browser=capture.browser;let browserCDP,cdp,ownedTarget;
  try{
    let readTarget;
    if(capture.source==='generator_9223'){
      const pages=await http(capture.base+'/json/list');
      readTarget=pages.find(x=>x.type==='page'&&chatURL(x.url)===task.conversation_url&&x.webSocketDebuggerUrl);
      if(!readTarget)return {status:'waiting',reason:'awaiting_relay_or_existing_conversation'};
      cdp=new CDP(readTarget.webSocketDebuggerUrl);await cdp.open();
    }else{
      browserCDP=new CDP(browser.webSocketDebuggerUrl);await browserCDP.open();
      const made=await browserCDP.call('Target.createTarget',{url:task.conversation_url,background:true});ownedTarget=made.targetId;
    }
    for(let n=0;n<5;n++){
      if(cdp)break;
      const targets=await http(capture.base+'/json/list');const own=targets.find(x=>x.id===ownedTarget);
      if(own?.webSocketDebuggerUrl){cdp=new CDP(own.webSocketDebuggerUrl);await cdp.open();break;}
      await sleep(500);
    }
    if(!cdp)throw Error('export_tab_not_ready');
    let raster;
    for(let n=0;n<30;n++){
      await sleep(1500);raster=await cdp.evaluate(rasterProbe(task.command_id));
      if(raster?.ready||raster?.reason==='capture_requires_sign_in'||
        (capture.source==='generator_9223'&&raster?.reason==='command_not_in_conversation'))break;
    }
    if(!raster?.ready)return {status:'waiting',reason:raster?.reason||'raster_not_ready'};
    // Fresh job identity check immediately before sending raster bytes.
    const fresh=await readImageJob(task);
    if(!sameContext(task,fresh))return {status:'obsolete'};
    const manual=await readEditorialState();
    const current=(manual.items||[]).filter(x=>String(x.id)===task.target_id).sort((a,b)=>Number(b.revision||0)-Number(a.revision||0)||Date.parse(b.explained_at||0)-Date.parse(a.explained_at||0))[0];
    if(!current||Number(current.revision||0)!==task.revision||crypto.createHash('sha256').update(String(current.explanation||'').trim()).digest('hex')!==task.explanation_sha256)return {status:'obsolete'};
    const response=await fetch('https://tt-control.fabricelop.workers.dev/api/ttendencias-run',{method:'POST',headers:{'content-type':'application/json'},signal:AbortSignal.timeout(45000),body:JSON.stringify({task:'web_image_upload',context_explanation_sha256:task.explanation_sha256,target_id:task.target_id,command_id:task.command_id,upload_secret:protect(task.secret_dpapi,true),image_data_url:raster.dataUrl,capture:{method:'original-fetch-img-web-consumer',width:raster.width,height:raster.height}})});
    const result=await response.json();
    if(response.ok&&result.status==='DONE')return {status:'waiting',reason:'upload_accepted_awaiting_main_confirmation',capture_browser:capture.source,sha256:String(result.sha256||''),image_path:String(result.image_path||''),upload_accepted_at:new Date().toISOString()};
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
function prioritizeOpenConversation(tasks,pages){
  // Opportunistic read of the completed current conversation before the
  // generator reuses its tab. This changes priority, never identity checks.
  const open=new Set(pages.filter(x=>x.type==='page').map(x=>chatURL(x.url)).filter(Boolean));
  const targets=new Set(pages.filter(x=>x.type==='page').map(x=>String(x.id||'')).filter(Boolean));
  // The conversation URL often has not settled at enrollment. Prioritizing
  // only saved URLs let older waiting jobs consume the entire retained-tab
  // window. A pinned target is scheduling evidence ONLY: consume still proves
  // the exact command in that page before accepting its URL or raster.
  return tasks.map((entry,index)=>({entry,index,open:open.has(entry.task.conversation_url)||
    (!chatURL(entry.task.conversation_url)&&targets.has(String(entry.task.browser_target_id||'')))}))
    .sort((a,b)=>Number(b.open)-Number(a.open)||a.index-b.index).map(x=>x.entry);
}
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
    let due=dueTasks(tasks,now);
    try{due=prioritizeOpenConversation(due,await http(GENERATOR_BASE+'/json/list'));}catch{}
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
async function watch(){
  fs.mkdirSync(ROOT,{recursive:true});const lock=path.join(ROOT,'watch.lock');
  try{
    console.log('TTENDENCIAS_WEB_IMAGE delivery watcher v'+WEB_DELIVERY_VERSION);
    const fd=fs.openSync(lock,'wx');fs.writeSync(fd,JSON.stringify({pid:process.pid,at:Date.now()}));fs.closeSync(fd);
  }catch{
    try{const old=JSON.parse(fs.readFileSync(lock,'utf8'));process.kill(old.pid,0);return;}
    catch{try{fs.unlinkSync(lock);}catch{}return;}
  }
  try{
    const deadline=Date.now()+300000;
    while(Date.now()<deadline){
      try{await once();}catch(e){console.error('TTENDENCIAS_WEB_IMAGE delivery retry deferred');}
      await sleep(5000);
    }
  }finally{try{const own=JSON.parse(fs.readFileSync(lock,'utf8'));if(own.pid===process.pid)fs.unlinkSync(lock);}catch{}}
}
module.exports={chatURL,enroll,rememberConversation,conversationProbe,discoverConversation,rasterProbe,sameContext,confirmedInMain,dueTasks,prioritizeOpenConversation,readImageJob,readEditorialState,selectExistingBrowser,consume,wakePublisher,watch,once};
if(require.main===module)(process.argv.includes('--watch')?watch():once()).catch(()=>{console.error('TTENDENCIAS_WEB_IMAGE exporter unavailable');process.exitCode=1;});
