'use strict';
// Reads only an existing exact command conversation. Never generates or edits,
// associates, posts chat messages, touches catalogs or calls the legacy uploader.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {execFileSync}=require('node:child_process');
const ENDPOINT='https://ttactualidad.rainyraven22.chatgpt.site/api/image-inbox/v1/images/ingest';
const sha=value=>crypto.createHash('sha256').update(value).digest('hex');
const episode=m=>sha(JSON.stringify({project:m.project,editorialId:m.editorialId,revision:m.revision,editorialText:m.editorialText,editorialAt:m.editorialAt}));
class CDP{
 constructor(url){this.url=url;this.seq=0;this.pending=new Map()}
 async open(){this.ws=new WebSocket(this.url);await new Promise((ok,bad)=>{const t=setTimeout(()=>bad(Error('CDP_TIMEOUT')),5000);this.ws.addEventListener('open',()=>{clearTimeout(t);ok()},{once:true});this.ws.addEventListener('error',()=>{clearTimeout(t);bad(Error('CDP_UNAVAILABLE'))},{once:true})});this.ws.addEventListener('message',e=>{const m=JSON.parse(String(e.data)),p=this.pending.get(m.id);if(!p)return;this.pending.delete(m.id);clearTimeout(p.t);m.error?p.bad(Error('CDP_EVALUATION_FAILED')):p.ok(m.result)})}
 async call(method,params){const id=++this.seq;const r=await new Promise((ok,bad)=>{const t=setTimeout(()=>{this.pending.delete(id);bad(Error('CDP_TIMEOUT'))},20000);this.pending.set(id,{ok,bad,t});this.ws.send(JSON.stringify({id,method,params}))});return r}
 async evaluate(expression){const r=await this.call('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});if(r.exceptionDetails)throw Error('RASTER_READ_FAILED');return r.result?.value}
 close(){for(const p of this.pending.values()){clearTimeout(p.t);p.bad(Error('CDP_CLOSED'))}this.pending.clear();try{this.ws?.close()}catch{}}
}
function unprotect(value){const code='$s=ConvertTo-SecureString ([Console]::In.ReadToEnd());$p=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($s);try{[Console]::Write([Runtime.InteropServices.Marshal]::PtrToStringBSTR($p))}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p)}';return execFileSync('powershell.exe',['-NoProfile','-NonInteractive','-Command',code],{input:value,encoding:'utf8',windowsHide:true,timeout:15000,maxBuffer:65536}).trim()}
function metadata(task,job){
 const news=task.project==='ttittulares',snapshot=job.context_snapshot||{};
 const text=String(news?snapshot.tweet_text:snapshot.explanation||'').trim();
 const date=news?snapshot.prepared_at:snapshot.explained_at;
 const fingerprint=news?sha([text,String(snapshot.factual_summary||'').trim(),String(snapshot.remate||'').trim()].join('\n')):sha(text);
 if(job.command_id!==task.command_id||String(job.target_id||job.trend_id||job.event_id)!==task.target_id||Number(job.revision||0)!==task.revision||fingerprint!==(news?task.editorial_sha256:task.explanation_sha256)||!text||!Number.isFinite(Date.parse(date)))throw Error('STALE_EXACT_JOB');
 const m={project:news?'ttittulares':'ttendencias',editorialId:task.target_id,revision:task.revision,commandId:task.command_id,editorialText:text,editorialAt:date,title:String(snapshot.name||snapshot.title||job.target_name||job.name||task.target_id)};m.episodeFingerprint=episode(m);return m;
}
async function send(meta,bytes,secret,fetcher=fetch){
 if(bytes.length>8388608||bytes.length<24||bytes.subarray(0,8).toString('hex')!=='89504e470d0a1a0a')throw Error('ORIGINAL_PNG_REQUIRED');
 meta={...meta,rasterSHA256:sha(bytes)};const form=new FormData();form.set('metadata',JSON.stringify(meta));form.set('image',new Blob([bytes],{type:'image/png'}),'original.png');
 let r;
 try{r=await fetcher(ENDPOINT,{method:'POST',headers:{'X-TT-Ingest-Key':secret,'User-Agent':'TTActualidad/0.4.50'},body:form,redirect:'error',signal:AbortSignal.timeout(45000)})}
 catch{throw Error('PRIVATE_RECEIPT_NETWORK_UNAVAILABLE')}
 if(!r.ok)throw Error('PRIVATE_RECEIPT_HTTP_'+r.status);
 let receipt;try{receipt=await r.json()}catch{throw Error('PRIVATE_RECEIPT_BAD_JSON')}
 // Retrying after a timeout can return "existing": it proves the same
 // command/PNG is already stored but is NOT a claim that it remains pending.
 if(!receipt||!['pending','existing','approved_awaiting_publication','published','rejected'].includes(receipt.state)||!/^[a-f0-9]{64}$/.test(String(receipt.id||'')))throw Error('PRIVATE_RECEIPT_BAD_JSON');
 if(receipt.state==='rejected')throw Error('PRIVATE_RECEIPT_REJECTED');
 return {...receipt,rasterSHA256:meta.rasterSHA256};
}
// Durable PC-only cache: a 503 or closed tab must not erase the generated
// original. This is neither an approval nor a public image catalog.
function originalPaths(base,task){
 if(!/^[A-Za-z0-9_.-]{3,160}$/.test(String(task.command_id||'')))throw Error('CACHED_ORIGINAL_CONFLICT');
 const dir=path.join(base,'image-approval-receipts','original-cache');
 return {dir,png:path.join(dir,task.command_id+'.png'),meta:path.join(dir,task.command_id+'.json')};
}
function cachedOriginal(base,task,meta){
 const files=originalPaths(base,task);
 if(!fs.existsSync(files.meta))return null;
 try{
  const record=JSON.parse(fs.readFileSync(files.meta,'utf8')),bytes=fs.readFileSync(files.png);
  if(record.commandId!==task.command_id||record.editorialId!==meta.editorialId||
     record.revision!==meta.revision||record.episodeFingerprint!==meta.episodeFingerprint||
     !/^[a-f0-9]{64}$/.test(record.rasterSHA256)||sha(bytes)!==record.rasterSHA256||
     bytes.length>8388608||bytes.length<24||
     bytes.subarray(0,8).toString('hex')!=='89504e470d0a1a0a')
     throw Error('CACHED_ORIGINAL_CONFLICT');
  return bytes;
 }catch{throw Error('CACHED_ORIGINAL_CONFLICT')}
}
function persistOriginal(base,task,meta,bytes){
 const existing=cachedOriginal(base,task,meta);
 if(existing){if(sha(existing)!==sha(bytes))throw Error('CACHED_ORIGINAL_CONFLICT');return;}
 if(bytes.length>8388608||bytes.length<24||bytes.subarray(0,8).toString('hex')!=='89504e470d0a1a0a')
  throw Error('ORIGINAL_PNG_REQUIRED');
 const files=originalPaths(base,task);fs.mkdirSync(files.dir,{recursive:true,mode:0o700});
 const nonce=crypto.randomBytes(8).toString('hex'),rasterTmp=files.png+'.'+nonce+'.tmp',metaTmp=files.meta+'.'+nonce+'.tmp';
 try{
  fs.writeFileSync(rasterTmp,bytes,{mode:0o600,flag:'wx'});fs.renameSync(rasterTmp,files.png);
  fs.writeFileSync(metaTmp,JSON.stringify({commandId:task.command_id,
    editorialId:meta.editorialId,revision:meta.revision,
    episodeFingerprint:meta.episodeFingerprint,rasterSHA256:sha(bytes),
    storedAt:new Date().toISOString()}),{mode:0o600,flag:'wx'});
  fs.renameSync(metaTmp,files.meta);
 }finally{for(const file of [rasterTmp,metaTmp])try{fs.unlinkSync(file)}catch{}}
}
function discardOriginal(base,task){
 const files=originalPaths(base,task);
 for(const file of [files.meta,files.png])try{fs.unlinkSync(file)}catch{}
}
function selectTarget(pages,task,chatURL){
 const expected=chatURL(task.conversation_url);
 return pages.find(p=>p.type==='page'&&p.webSocketDebuggerUrl&&chatURL(p.url)&&(expected?chatURL(p.url)===expected:p.id===task.browser_target_id));
}
// Recover the immutable preparation time after a news item leaves Listas.
// Never substitute the timestamp of the image job, a current radar sighting
// or an unrelated revision: the episode fingerprint must remain authentic.
async function editorialJob(source,task,fetcher=fetch){
 const job=await source.readImageJob(task);
 if(task.project!=='ttittulares'||job.context_snapshot?.prepared_at)return job;
 const snapshot=job.context_snapshot||{};
 const root='https://raw.githubusercontent.com/fabricelop/europapress-rss/main/';
 const read=async(name)=>{
  try{
   const response=await fetcher(root+name+'?t='+Date.now(),{signal:AbortSignal.timeout(15000),cache:'no-store'});
   if(!response.ok)return null;
   const doc=await response.json();
   return Array.isArray(doc.items)?doc.items:null;
  }catch{return null}
 };
 const prepared=await read('ttittulares/prepared.json');
 const candidates=(prepared||[]).filter(x=>String(x.event_id)===task.target_id&&Number(x.revision)===task.revision);
 if(candidates.length){
  const row=candidates.find(x=>String(x.tweet?.text||'').trim()===String(snapshot.tweet_text||'').trim()&&!x.rewrite_pending);
  if(!row||!Number.isFinite(Date.parse(row.prepared_at)))throw Error('STALE_EXACT_JOB');
  return {...job,context_snapshot:{...snapshot,prepared_at:row.prepared_at}};
 }
 // The READY processing ledger retains delivered_at (the same timestamp as
 // prepared_at) even when prepared.json has already been cleared by delivery.
 const history=await read('telegram/editorial-processing.json');
 const row=(history||[]).find(x=>
  String(x.event_id||x.id)===task.target_id&&Number(x.revision)===task.revision&&
  x.delivery_confirmation==='prepared_web'&&!x.rewrite_pending&&
  Number.isFinite(Date.parse(x.delivered_at))&&
  String(x.title||x.canonical_title||'').trim()===String(snapshot.title||job.target_name||'').trim());
 if(!row)throw Error('PREPARED_DATE_NOT_RECOVERABLE');
 return {...job,context_snapshot:{...snapshot,prepared_at:row.delivered_at}};
}

function activeIdentities(project,document,decisions,now=Date.now()){
 if(!Array.isArray(document?.items)||!Array.isArray(decisions?.items))throw Error('CURRENT_EDITORIAL_UNAVAILABLE');
 const closed=new Set(['deleted','dismissed','published','removed','delete_pending','delete_failed']),latest=new Map();
 for(const row of document.items){const id=String(project==='ttendencias'?row.id:row.event_id);const previous=latest.get(id);if(!previous||Number(row.revision||0)>Number(previous.revision||0)||Number(row.revision||0)===Number(previous.revision||0)&&Date.parse(row.explained_at||row.prepared_at)>Date.parse(previous.explained_at||previous.prepared_at))latest.set(id,row);}
 const result=new Set();
 for(const [id,row] of latest){const rev=Number(row.revision||0),date=Date.parse(row.explained_at||row.prepared_at);
  if(closed.has(String(row.status||'').toLowerCase())||closed.has(String(row.telegram_package_status||'').toLowerCase())||row.rewrite_pending)continue;
  if(project==='ttendencias'&&(row.status!=='explained'||!row.explanation||!Number.isFinite(date)||now-date>48*3600000||date-now>3600000))continue;
  if(decisions.items.some(x=>String(x.id||x.event_id)===id&&closed.has(String(x.status||'').toLowerCase())&&(project==='ttittulares'||Number(x.revision||0)>rev||Number(x.revision||0)===rev&&(!Number.isFinite(Date.parse(x.updated_at))||Date.parse(x.updated_at)>=date-60000))))continue;
  result.add(project+':'+id+':'+rev);
 }
 return result;
}
// Eligibility: current Listas news; current Top30; or historic Top30 proven by
// the original image job rank. Only jobs enrolled in the last 48 hours enter
// the recovery queue. This is NOT automatic approval or publication.
async function allowedTop30(fetcher=fetch){
 const url='https://raw.githubusercontent.com/fabricelop/europapress-rss/main/trends/site-top30-current.json?t='+Date.now();
 try {
  const r=await fetcher(url,{signal:AbortSignal.timeout(15000),cache:'no-store'});
  if(!r.ok)throw Error('unavailable');
  const doc=await r.json();
  if(!Array.isArray(doc.items)||doc.items.length>30||!doc.items.length)throw Error('invalid');
  return new Set(doc.items.filter(x=>x.editorial_id&&Number.isInteger(x.revision))
   .map(x=>x.editorial_id+':r'+x.revision));
 }catch{return null}
}
const MAX_IMAGE_AGE_MS=48*60*60*1000;
const MAX_ORIGINAL_CHECKS_PER_CYCLE=16;
function inCurrentApprovalScope(task,top30,listNews,now=Date.now()){
 // "Was in Top30 at image creation" is evidenced by the immutable job
 // snapshot, checked after reading that exact job. Do not deny that candidate
 // here just because it is no longer in today's Top30.
 if(!['ttendencias','ttittulares'].includes(task?.project) ||
    !/^[A-Za-z0-9_.-]{3,160}$/.test(String(task?.target_id||'')) ||
    !/^[A-Za-z0-9_.-]{3,160}$/.test(String(task?.command_id||'')) ||
    !Number.isInteger(task?.revision) || task.revision<0 ||
    !['waiting','needs_review'].includes(task?.status) ||
    !task?.secret_dpapi)return false;
 const created=Date.parse(task.created_at||'');
 if(!Number.isFinite(created)||created>now+60000)return false;
 if(task.project==='ttittulares'){
  return listNews instanceof Set && listNews.has(task.target_id);
 }
 return true;
}
function provesTop30AtImageCreation(task,job,top30){
 if(task.project!=='ttendencias')return true;
 if(top30 instanceof Set && top30.has(task.target_id+':r'+task.revision))return true;
 // Historic proof is part of the original TTendencias editorial snapshot,
 // not today's ranking, a title guess or another trend's metadata.
 const snap=job?.context_snapshot||{};
 const rank=Number(snap.rank_at_explanation);
 return Number.isInteger(rank)&&rank>=1&&rank<=30 &&
  String(job.command_id||'')===task.command_id &&
  String(job.target_id||job.trend_id||'')===task.target_id &&
  Number(job.revision||0)===task.revision;
}
function selectCurrentTasks(tasks,progress,top30,limit=MAX_ORIGINAL_CHECKS_PER_CYCLE){
 // No mass recovery: up to 16 eligible image jobs per pass, with the
 // existing strict cap of ONE new Chrome relay tab per pass. As items are
 // checked, their next pass is deferred behind the other recent ones.
 const checked=t=>Number(progress[t.command_id]?.checkedAt||0);
 const isTop30=t=>top30 instanceof Set &&
   top30.has(t.target_id+':r'+t.revision);
 return [...tasks].sort((x,y)=>
   checked(x)-checked(y) ||
   Number(isTop30(y))-Number(isTop30(x)) ||
   (Date.parse(y.created_at||'')||0)-(Date.parse(x.created_at||'')||0) ||
   String(x.command_id).localeCompare(String(y.command_id))
 ).slice(0,limit);
}
async function liveIdentities(sources){
 const all=new Set();
 for(const project of ['ttendencias','ttittulares']){
  const path=project==='ttendencias'?'trends/mobile-decisions.json':'ttittulares/decisions.json';
  const [doc,response]=await Promise.all([sources[project].readEditorialState(),fetch('https://raw.githubusercontent.com/fabricelop/europapress-rss/main/'+path+'?t='+Date.now(),{signal:AbortSignal.timeout(15000),cache:'no-store'})]);if(!response.ok)throw Error('CURRENT_EDITORIAL_UNAVAILABLE');
  for(const id of activeIdentities(project,doc,await response.json()))all.add(id);
 }
 return all;
}
async function once(base=__dirname){
 if(process.platform!=='win32')throw Error('WINDOWS_REQUIRED');
 const sources={};
 for(const [project,file] of [['ttendencias','TTendenciasWebImages.cjs'],['ttittulares','TTiTTularesWebImages.cjs']]){
  const dependency=path.join(base,file);if(!fs.readFileSync(dependency,'utf8').includes("return {status:'waiting',reason:'manual_approval_required'}"))throw Error('INSTALL_ASSOCIATION_PAUSE_FIRST');sources[project]=require(dependency);
 }
 const receipts=path.join(base,'image-approval-receipts');fs.mkdirSync(receipts,{recursive:true});
 const lockPath=path.join(receipts,'receiver.lock');
 try{const old=JSON.parse(fs.readFileSync(lockPath,'utf8'));try{process.kill(old.pid,0);return}catch{fs.unlinkSync(lockPath)}}catch{}
 let lock;try{lock=fs.openSync(lockPath,'wx');fs.writeFileSync(lock,JSON.stringify({pid:process.pid,at:Date.now()}))}catch{return}
 try{
  const statusFile=path.join(receipts,'receiver-status.json');let progress={};try{progress=JSON.parse(fs.readFileSync(statusFile,'utf8'))}catch{}
  function report(task,reason){progress[task.command_id]={...progress[task.command_id],checkedAt:Date.now(),reason};const tmp=statusFile+'.tmp';fs.writeFileSync(tmp,JSON.stringify(progress,null,2),{mode:0o600});fs.renameSync(tmp,statusFile);console.log('PRIVATE_INBOX '+task.command_id+' '+reason)}
  // Never resend a terminal receipt. The pending window is 48h; only
  // current Listas news or present/former Top30 jobs are admitted. A past
  // Top30 rank must be independently proven by the exact original job.
  // No automatic approval, publication or regeneration.
  const tasks=[];
  for(const project of ['ttendencias','ttittulares']){
   const dir=path.join(base,project+'-web-images');if(!fs.existsSync(dir))continue;
   for(const file of fs.readdirSync(dir).filter(x=>x.endsWith('.json'))){try{const task=JSON.parse(fs.readFileSync(path.join(dir,file),'utf8'));if(task.secret_dpapi&&['waiting','needs_review'].includes(task.status)&&/^[A-Za-z0-9_.-]{3,160}$/.test(task.command_id)&&!fs.existsSync(path.join(receipts,task.command_id+'.json')))tasks.push({...task,project});}catch{}}
  }
  // An editorial decision to publish/delete a trend does NOT erase an
  // already-generated image from the editor's private approval inbox.
  const [top30,listasDoc]=await Promise.all([
   allowedTop30(),
   sources.ttittulares.readEditorialState().catch(()=>null)
  ]);
  const listNews=Array.isArray(listasDoc?.items)?
   new Set(listasDoc.items.map(x=>String(x.event_id||x.id||'')).filter(Boolean)):null;
  const eligible=tasks.filter(task=>inCurrentApprovalScope(task,top30,listNews));
  const excludedBacklog=tasks.length-eligible.length;
  const selected=selectCurrentTasks(eligible,progress,top30);
  const current=selected.filter(x=>x.project==='ttittulares'?
    listNews?.has(x.target_id):top30?.has(x.target_id+':r'+x.revision));
  fs.writeFileSync(path.join(receipts,'receiver-cycle.json'),JSON.stringify({
   checkedAt:new Date().toISOString(),queuedLocal:tasks.length,
   eligibleForApproval:eligible.length,excludedBacklog,
   scope:'listas_and_current_or_at_creation_top30_images_max_48h',
   candidatesNotYetVerifiedAsGenerated:true,
   attemptedThisCycle:selected.length,
   queuedForLaterCycles:eligible.length-selected.length,
   skippedByPerCycleLimit:eligible.length-selected.length,
   selectedCurrent:current.length,selectedHistorical:selected.length-current.length,
   historicalQueued:eligible.filter(x=>x.project==='ttendencias' &&
     !(top30 instanceof Set&&top30.has(x.target_id+':r'+x.revision))).length,
   projects:Object.fromEntries(['ttendencias','ttittulares'].map(project=>[project,{
    queued:tasks.filter(x=>x.project===project).length,
    eligible:eligible.filter(x=>x.project===project).length,
    selected:selected.filter(x=>x.project===project).length
   }]))
  },null,2));
  tasks.splice(0,tasks.length,...selected);
  console.log('PRIVATE_INBOX_CYCLE candidates='+tasks.length);
  // All episodes remain eligible, but browser *creation* must be bounded.
  // A fresh tab can spawn multiple Chrome subprocesses.
  const MAX_NEW_RELAY_TABS_PER_CYCLE=1,MAX_RELAY_PAGE_TARGETS=6;
  const RELAY_RETRY_COOLDOWN_MS=15*60*1000;
  const relayGuard=path.join(receipts,'relay-cleanup-unconfirmed.json');
  let newlyOpened=0,relayDeferred=0;
  for(const task of tasks){
   const source=sources[task.project];
   const receiptFile=path.join(receipts,task.command_id+'.json');if(fs.existsSync(receiptFile))continue;
   let cdp,browser,ownedTarget;
   try{
    const job=await editorialJob(source,task);
    if(!provesTop30AtImageCreation(task,job,top30)){
      report(task,'TOP30_ORIGIN_NOT_PROVEN');continue;
    }
    const meta=metadata(task,job);
    let bytes=cachedOriginal(base,task,meta);
    // The generator may have captured the exact original BEFORE a temporary
    // editorial/API outage. Recover its immutable command-bound PNG locally,
    // without reopening Chrome, if its identity still matches this live job.
    if(!bytes){
     try{
      const immediate=require('./TTImagesImmediateInbox.cjs');
      const staged=immediate.loadStaged(base,task);
      if(staged){
       persistOriginal(base,task,meta,staged);
       bytes=staged;
       report(task,'IMMEDIATE_STAGED_ORIGINAL_RECOVERED');
      }
     }catch(e){report(task,'IMMEDIATE_STAGED_ORIGINAL_CONFLICT');continue;}
    }
    if(!bytes){
    if(!source.chatURL(task.conversation_url)){const known=source.chatURL(job.conversation_url||job.chat_url);if(known)task.conversation_url=known;}
    if(!source.chatURL(task.conversation_url)){const found=await source.discoverConversation(task.command_id,task.browser_target_id,true);if(found?.url)task.conversation_url=found.url;}
    let target;
    // Reuse an exact existing conversation first; never create tabs in the generator.
    for(const port of [9223,9234]){try{const r=await fetch('http://127.0.0.1:'+port+'/json/list',{signal:AbortSignal.timeout(3000)});const pages=await r.json();target=selectTarget(pages,task,source.chatURL);if(target)break}catch{}}
    if(!source.chatURL(task.conversation_url)){
     // Recover candidate URLs from the SAME producer tab's navigation history.
     // A URL is only a candidate; rasterProbe must still prove this command.
     try{const r=await fetch('http://127.0.0.1:9223/json/list',{signal:AbortSignal.timeout(3000)});const own=(await r.json()).find(x=>x.id===task.browser_target_id&&x.webSocketDebuggerUrl);if(own){const history=new CDP(own.webSocketDebuggerUrl);try{await history.open();const h=await history.call('Page.getNavigationHistory',{});const urls=[...new Set((h.entries||[]).map(x=>source.chatURL(x.url)).filter(Boolean))].reverse();if(urls.length){const index=progress[task.command_id]?.recoveryIndex||0;task.conversation_url=urls[index%urls.length];progress[task.command_id]={...progress[task.command_id],recoveryIndex:index+1};target=null;}}finally{history.close()}}}catch{}
    }
    if(!target&&source.chatURL(task.conversation_url)){
     // At most one temporary tab per cycle, never in the generator's profile.
     // Jobs deferred by resource safety remain eligible for a later cycle.
     const last=Number(progress[task.command_id]?.lastRelayOpenAt||0);
     if(fs.existsSync(relayGuard)){
      relayDeferred++;report(task,'RELAY_CLEANUP_UNCONFIRMED');continue;
     }
     if(newlyOpened>=MAX_NEW_RELAY_TABS_PER_CYCLE){
      relayDeferred++;report(task,'RELAY_TAB_BUDGET');continue;
     }
     if(Date.now()-last<RELAY_RETRY_COOLDOWN_MS){
      relayDeferred++;report(task,'RELAY_RETRY_COOLDOWN');continue;
     }
     try{
      const pagesResponse=await fetch('http://127.0.0.1:9234/json/list',
       {signal:AbortSignal.timeout(3000)});
      if(!pagesResponse.ok)throw Error('RELAY_LIST_UNAVAILABLE');
      const pages=await pagesResponse.json();
      if(!Array.isArray(pages))throw Error('RELAY_LIST_UNAVAILABLE');
      if(pages.filter(p=>p.type==='page').length>=MAX_RELAY_PAGE_TARGETS){
       relayDeferred++;report(task,'RELAY_CAPACITY_REACHED');continue;
      }
      const r=await fetch('http://127.0.0.1:9234/json/version',
       {signal:AbortSignal.timeout(3000)});
      const version=await r.json();
      if(!version.webSocketDebuggerUrl)throw Error('RELAY_UNAVAILABLE');
      browser=new CDP(version.webSocketDebuggerUrl);await browser.open();
      newlyOpened++;
      progress[task.command_id]={...progress[task.command_id],lastRelayOpenAt:Date.now()};
      ownedTarget=(await browser.call('Target.createTarget',
       {url:source.chatURL(task.conversation_url),background:true})).targetId;
      for(let n=0;n<5;n++){
       const q=await fetch('http://127.0.0.1:9234/json/list',
        {signal:AbortSignal.timeout(3000)});
       target=(await q.json()).find(x=>x.id===ownedTarget&&x.webSocketDebuggerUrl);
       if(target)break;
       await new Promise(r=>setTimeout(r,500));
      }
     }catch{
      // A Target.createTarget request may have reached Chrome even if the
      // transport failed before returning its target ID. Never try to open
      // more tabs automatically when ownership cannot be established.
      if(newlyOpened>0 && !ownedTarget){
       fs.writeFileSync(relayGuard,JSON.stringify({
        at:new Date().toISOString(),reason:'new_tab_id_unconfirmed'
       }),{mode:0o600});
      }
      report(task,'RELAY_OPEN_FAILED');
     }
    }
    if(!target){report(task,'EXACT_CONVERSATION_UNAVAILABLE');continue;}
    cdp=new CDP(target.webSocketDebuggerUrl);await cdp.open();
    let raster;
    // The ChatGPT conversation can be visible in CDP before its user turns
    // and original image are hydrated. Previously an existing tab got only
    // ONE probe, leaving valid images stuck as conversation_not_loaded.
    // Retry only reading the exact original. Never click, navigate, generate,
    // change a job, or accept an image from a different command.
    const maxProbes=ownedTarget?12:7;
    for(let n=0;n<maxProbes;n++){
      try{
        raster=await cdp.evaluate(source.rasterProbe(task.command_id,true));
      }catch(e){
        // A transient Runtime.evaluate navigation race is retriable. An
        // unresponsive CDP connection is not evidence of an invalid image.
        if(!['CDP_EVALUATION_FAILED','RASTER_READ_FAILED'].includes(String(e.message||'')))
          throw e;
        raster={ready:false,reason:'CDP_EVALUATION_FAILED'};
      }
      if(raster?.ready ||
         ['later_user_turn','capture_requires_sign_in'].includes(raster?.reason))break;
      if(n+1<maxProbes)await new Promise(r=>setTimeout(r,1500));
    }
    if(!raster?.ready){const allowed=new Set(['later_user_turn','capture_requires_sign_in','command_not_in_conversation','generating','ambiguous_or_missing_raster','raster_fetch_failed','raster_size_or_type','png_conversion_failed','png_exceeds_private_limit','conversation_not_loaded','CDP_EVALUATION_FAILED']);report(task,allowed.has(raster?.reason)?raster.reason:'ORIGINAL_NOT_READY');continue;}
    if(!String(raster.dataUrl).startsWith('data:image/png;base64,')){report(task,'ORIGINAL_FORMAT_NOT_PNG');continue;}
    bytes=Buffer.from(raster.dataUrl.slice('data:image/png;base64,'.length),'base64');
    const fresh=metadata(task,await editorialJob(source,task));if(fresh.episodeFingerprint!==meta.episodeFingerprint)throw Error('EPISODE_CHANGED');
    persistOriginal(base,task,meta,bytes);
    }
    const receipt=await send(meta,bytes,unprotect(task.secret_dpapi));
    const temp=receiptFile+'.tmp';fs.writeFileSync(temp,JSON.stringify({project:meta.project,revision:meta.revision,commandId:meta.commandId,editorialId:meta.editorialId,...receipt,receivedAt:new Date().toISOString()},null,2),{mode:0o600});fs.renameSync(temp,receiptFile);
    discardOriginal(base,task);
    // Remove the preliminary original only after a durable private receipt.
    try{require('./TTImagesImmediateInbox.cjs').discardStaged(base,task);}catch{}
    report(task,'RECEIVED_'+receipt.state);
   }catch(e){const message=String(e?.message||'');const safe=/^(STALE_EXACT_JOB|EPISODE_CHANGED|CDP_[A-Z_]+|RASTER_READ_FAILED|ORIGINAL_PNG_REQUIRED|PRIVATE_RECEIPT_HTTP_\d+|PRIVATE_RECEIPT_REJECTED|PRIVATE_RECEIPT_BAD_JSON|PRIVATE_RECEIPT_NETWORK_UNAVAILABLE|PREPARED_DATE_NOT_RECOVERABLE|CACHED_ORIGINAL_CONFLICT|image_job_[A-Za-z0-9_ -]+)$/.test(message)?message:'RECEIVER_STEP_FAILED';report(task,safe)}finally{
    cdp?.close();
    if(ownedTarget){
     let closed=false;
     try{
      const reply=await browser?.call('Target.closeTarget',{targetId:ownedTarget});
      closed=reply?.success!==false;
     }catch{}
     if(!closed){
      try{
       const response=await fetch('http://127.0.0.1:9234/json/close/'+encodeURIComponent(ownedTarget),
        {signal:AbortSignal.timeout(3000)});
       closed=response.ok;
      }catch{}
     }
     if(!closed){
      fs.writeFileSync(relayGuard,JSON.stringify({
       at:new Date().toISOString(),reason:'owned_tab_cleanup_unconfirmed'
      }),{mode:0o600});
      console.warn('PRIVATE_INBOX_RELAY_CLEANUP_UNCONFIRMED');
     }
    }
    browser?.close();
   }
  }
  console.log('PRIVATE_INBOX_RELAY created='+newlyOpened+' deferred='+relayDeferred);
 }finally{fs.closeSync(lock);fs.unlinkSync(path.join(receipts,'receiver.lock'))}
}
module.exports={metadata,episode,send,editorialJob,cachedOriginal,persistOriginal,discardOriginal,once,ENDPOINT,selectTarget,activeIdentities,selectCurrentTasks,inCurrentApprovalScope,provesTop30AtImageCreation,allowedTop30,MAX_ORIGINAL_CHECKS_PER_CYCLE,MAX_IMAGE_AGE_MS};
if(require.main===module)once().catch(()=>{console.error('PRIVATE_INBOX_RECEIVER_UNAVAILABLE');process.exitCode=1});
