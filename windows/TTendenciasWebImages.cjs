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
const WEB_DELIVERY_VERSION=10;
const ROOT=path.join(__dirname,'ttendencias-web-images');
const ORIGINALS=path.join(ROOT,'originals');
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
// Strict local receipt: persist verified original bytes BEFORE any remote call.
// The local file is not a replacement for verified publication in GitHub.
function originalPaths(task,directory=ORIGINALS){
 if(!safeID(task.command_id))throw Error('invalid_original_command_id');
 return {meta:path.join(directory,task.command_id+'.json'),directory};
}
function assertSameOriginal(task,meta){
 if(String(meta.command_id)!==String(task.command_id)||
    String(meta.target_id)!==String(task.target_id)||
    Number(meta.revision)!==Number(task.revision)||
    String(meta.explanation_sha256)!==String(task.explanation_sha256))
    throw Error('original_context_mismatch');
 if(!/^[a-f0-9]{64}$/.test(String(meta.sha256||'')))throw Error('invalid_original_sha256');
 if(!/^(image\/png|image\/jpeg|image\/webp)$/.test(String(meta.mime||'')))
    throw Error('original_mime_invalid');
 if(!Number.isInteger(meta.width)||!Number.isInteger(meta.height)||
    meta.width<1024||meta.height<576)throw Error('original_dimensions_invalid');
}
function loadCachedOriginal(task,directory=ORIGINALS){
 const {meta:metaFile}=originalPaths(task,directory);
 if(!fs.existsSync(metaFile))return null;
 const meta=JSON.parse(fs.readFileSync(metaFile,'utf8'));
 assertSameOriginal(task,meta);
 const ext={'image/png':'png','image/jpeg':'jpg','image/webp':'webp'}[meta.mime];
 const filename=task.command_id+'-'+meta.sha256+'.'+ext;
 const absolute=path.join(directory,filename);
 if(!fs.existsSync(absolute))throw Error('original_bytes_missing');
 const raw=fs.readFileSync(absolute);
 if(raw.length<12000||raw.length>8388608||raw.length!==meta.bytes||
    crypto.createHash('sha256').update(raw).digest('hex')!==meta.sha256)
    throw Error('original_bytes_integrity_failed');
 const magic=meta.mime==='image/png'
    ?raw.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10]))
    :meta.mime==='image/jpeg'
     ?raw.subarray(0,3).equals(Buffer.from([255,216,255]))
     :raw.toString('ascii',0,4)==='RIFF'&&raw.toString('ascii',8,12)==='WEBP';
 if(!magic)throw Error('original_image_signature_invalid');
 return {ready:true,dataUrl:'data:'+meta.mime+';base64,'+raw.toString('base64'),
    width:meta.width,height:meta.height,sha256:meta.sha256,source:'durable_local'};
}
function cacheRaster(task,raster,directory=ORIGINALS){
 if(!raster?.ready||!Number.isInteger(raster.width)||!Number.isInteger(raster.height)||
    raster.width<1024||raster.height<576)throw Error('raster_not_verified');
 const match=/^data:(image\/(?:png|jpeg|webp));base64,([A-Za-z0-9+/=]+)$/.exec(String(raster.dataUrl||''));
 if(!match)throw Error('raster_data_url_invalid');
 const raw=Buffer.from(match[2],'base64');
 if(raw.length<12000||raw.length>8388608)throw Error('raster_size_invalid');
 const sha256=crypto.createHash('sha256').update(raw).digest('hex');
 const {meta:metaFile}=originalPaths(task,directory);
 if(fs.existsSync(metaFile)){
   const cached=loadCachedOriginal(task,directory);
   if(cached.sha256!==sha256)throw Error('original_collision_same_command');
   return cached;
 }
 fs.mkdirSync(directory,{recursive:true,mode:0o700});
 const meta={version:1,command_id:task.command_id,target_id:task.target_id,
   revision:task.revision,explanation_sha256:task.explanation_sha256,sha256,
   mime:match[1],width:raster.width,height:raster.height,bytes:raw.length,
   saved_at:new Date().toISOString()};
 assertSameOriginal(task,meta);
 const ext={'image/png':'png','image/jpeg':'jpg','image/webp':'webp'}[match[1]];
 const filename=task.command_id+'-'+sha256+'.'+ext;
 const dest=path.join(directory,filename);
 if(!fs.existsSync(dest)){
   const tmp=dest+'.'+process.pid+'.new';
   try{fs.writeFileSync(tmp,raw,{flag:'wx',mode:0o600});fs.renameSync(tmp,dest);}
   finally{try{fs.unlinkSync(tmp);}catch{}}
 }
 atomic(metaFile,meta);
 return loadCachedOriginal(task,directory);
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
function userTurns(){
 const nodes=[...document.querySelectorAll('[data-message-author-role="user"],[data-testid*="user-message" i],[class*="user-message" i],article[data-turn="user"]')];
 // Multiple selectors can describe nested wrappers of the same user turn.
 return nodes.filter(el=>!nodes.some(other=>other!==el&&typeof el.contains==='function'&&el.contains(other)));
}
function rasterProbe(command){return `(async()=>{
 const command=${JSON.stringify(command)};
 const users=(${userTurns.toString()})();
 const user=users.find(x=>String(x.innerText||x.textContent||'').includes(command));
 if(!user){
  if(document.querySelector('[data-testid="login-button"],a[href="/auth/login"]'))return {ready:false,reason:'capture_requires_sign_in'};
  return {ready:false,reason:users.length?'command_not_in_conversation':'conversation_not_loaded'};
 }
 const last=users[users.length-1],next=users[users.indexOf(user)+1];
 if(users.indexOf(user)!==users.length-1&&
   !(users.indexOf(user)===users.length-2&&
     String(next?.innerText||next?.textContent||'').trim().startsWith('TTENDENCIAS_SITE_RETURN_AFTER_IMAGE_V1 '+command+' ')))
   return {ready:false,reason:'later_user_turn'};
 if(document.querySelector('button[data-testid="stop-button"],button[aria-label*="Stop" i],button[aria-label*="Detener" i]'))return {ready:false,reason:'generating'};
 const images=[...document.querySelectorAll('img')].filter(img=>
  Boolean(user.compareDocumentPosition(img)&Node.DOCUMENT_POSITION_FOLLOWING)&&img.complete&&img.naturalWidth>=1024&&img.naturalHeight>=576&&
  !users.some(u=>typeof u.contains==='function'&&u.contains(img))&&
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
function conversationProbe(command,diagnostic=false){return `(()=>{
 const users=(${userTurns.toString()})();
 const last=users[users.length-1];
 const text=String(last&&(last.innerText||last.textContent)||'').trim();
 const matched=text.includes(${JSON.stringify(command)})&&
   (text.startsWith('TTENDENCIAS_IMAGE_JOB_V4 ')||
    text.startsWith('TTENDENCIAS_SITE_RETURN_AFTER_IMAGE_V1 '));
 return ${diagnostic?'true':'false'}?{url:matched?location.href:null,reason:matched?'matched':last?'last_user_command_differs':'user_turn_not_found'}:matched?location.href:null;
})()`;}
function pinnedTargetId(){
  try{const id=String(JSON.parse(fs.readFileSync(path.join(__dirname,'ttendencias-image-tab.json'),'utf8')).target_id||'');return safeID(id)?id:null;}catch{return null;}
}
async function currentPinnedCommand(pages){
  const id=pinnedTargetId(),own=pages.find(x=>id&&String(x.id)===id&&x.webSocketDebuggerUrl&&chatURL(x.url));
  if(!own)return null;
  const cdp=new CDP(own.webSocketDebuggerUrl);
  try{
    await cdp.open();return await cdp.evaluate(`(()=>{const users=(${userTurns.toString()})();const last=users[users.length-1];const m=String(last&&(last.innerText||last.textContent)||'').match(/^TTENDENCIAS_(?:IMAGE_JOB_V4|SITE_RETURN_AFTER_IMAGE_V1)\\s+([A-Za-z0-9._-]+)\\s+([A-Za-z0-9._-]+)/);return m?{command_id:m[1],target_id:m[2]}:null;})()`);
  }finally{cdp.close();}
}
async function discoverConversation(commandId,browserTargetId,diagnostic=false){
  const pages=await http(GENERATOR_BASE+'/json/list');
  // The producer can recover/replace its fixed target during submission. The
  // enrollment may still carry the former target. Inspect only the recorded
  // target and the producer's OWN current pinned target, never arbitrary tabs.
  let reason='pinned_target_missing';
  for(const id of new Set([String(browserTargetId||''),pinnedTargetId()].filter(Boolean))){
    const own=pages.find(x=>String(x.id||'')===id&&x.webSocketDebuggerUrl);
    if(!own)continue;
    if(!chatURL(own.url)){reason='pinned_url_not_durable';continue;}
    const cdp=new CDP(own.webSocketDebuggerUrl);
    try{await cdp.open();const result=await cdp.evaluate(conversationProbe(commandId,diagnostic));
      const url=chatURL(diagnostic?result?.url:result);
      if(url)return diagnostic?{url,reason:'matched',browser_target_id:id}:url;
      reason=diagnostic?(result?.reason||'conversation_probe_unavailable'):'last_user_command_differs';
    }finally{cdp.close();}
  }
  return diagnostic?{url:null,reason}:null;
}
async function rememberConversation(input){
  enroll(input);
  const url=await discoverConversation(input.commandId,input.browserTargetId);
  if(!url)return false;
  enroll({...input,conversationUrl:url});
  return true;
}
// Safe, no-ImageGen Site/App follow-up using an original image already present.
// Do not touch the generator's fixed tab: only an isolated relay, and never
// while the producer for this exact command is still running.
function producerBusyFor(task){
  try{
    const lock=JSON.parse(fs.readFileSync(path.join(__dirname,'ttendencias-image-bridge.lock.json'),'utf8'));
    if(lock.command_id!==task.command_id||lock.target_id!==task.target_id)return false;
    const pid=Number(lock.pid);
    if(!Number.isSafeInteger(pid)||pid<1)return false;
    process.kill(pid,0);return true;
  }catch{return false;}
}
function siteReturnPrompt(task,job){
  const snapshot=job.context_snapshot||{};
  const context={project_id:'appgprj_6ae4dcf7d7488191a574e5b649e67370',
    target_id:task.target_id,name:String(job.target_name||task.target_id),
    revision:task.revision,scope:'editorial',explanation:String(snapshot.explanation||'').trim(),
    explained_at:String(snapshot.explained_at||'')};
  if(!context.explanation||!context.explained_at)throw Error('site_return_missing_editorial_identity');
  return [
    'TTENDENCIAS_SITE_RETURN_AFTER_IMAGE_V1 '+task.command_id+' '+task.target_id,
    'SEGUIMIENTO AUTOMÁTICO DEL ENCARGO ORIGINAL. NO GENERES NINGUNA IMAGEN. NO uses ImageGen. La imagen ORIGINAL está arriba en ESTA MISMA CONVERSACIÓN y ha sido detectada en el turno de ImageGen del command_id indicado. No pidas ni descargues otro PNG, no te bases en el nombre de una tendencia, no asocies una captura.',
    'CONTEXTO EXACTO Y AUTORITATIVO (revalídalo antes de escribir): '+JSON.stringify(context),
    '1. Usa el conector TTendencias · TTActualidad: inspect_top30_images. El target_id, revision, explanation literal y explained_at del contexto deben coincidir con el Site vigente. Si la revisión cambió o no figura con esa misma identidad editorial, detente sin adjuntar.',
    '2. Ejecuta verify_trend_image con context EXACTO. La imagen NUEVA del command_id actual tiene prioridad sobre imágenes ANTERIORES del mismo target_id, pero jamás sobre otro target_id/revisión. Si el Site está missing y el original PNG de ESTA conversación está disponible como file, ejecuta attach_trend_image con ese file ORIGINAL y el mismo context. Si hay imagen verified anterior, comprueba si la herramienta ofrece reemplazo explícito para esta misma identidad; la operación attach_trend_image actual puede RECHAZAR la sustitución. Si no hay operación autorizada de reemplazo, devuelve REEMPLAZO BLOQUEADO POR SITE, conserva la imagen anterior y NO declares asociada la nueva. Nunca uses thumbnail, URL inventada ni imagen de otro encargo.',
    '3. Vuelve a ejecutar verify_trend_image y exige status verified y SHA-256 y URL reales. En otro caso responde SITE PENDING y conserva el PNG para reintento; NO repitas la generación.',
    '4. Si Site verified, sincroniza SOLO ese (target_id, revision) en fabricelop/europapress-rss rama main trends/site-ai-images.json mediante GitHub fetch_file y update_file. Conserva todos los registros anteriores; usa explanation, explained_at, URL HTTPS y SHA-256 verificados, con relectura del catálogo.',
    '5. Informa SITE verified/pending y APP manifest verified/pending por separado. No afirmes visualización física en el iPhone. No publiques en X ni Telegram. No digas que está asociado si no has usado las herramientas.'
  ].join('\n\n');
}
function siteReturnProbe(commandId,targetId,marker){
  return `(()=>{const marker=${JSON.stringify(marker)},original=${JSON.stringify('TTENDENCIAS_IMAGE_JOB_V4 '+commandId+' '+targetId)};
    const users=(${userTurns.toString()})();const last=users[users.length-1];
    const current=String(last&&(last.innerText||last.textContent)||'').trim();
    if(current.startsWith(marker))return {status:'already_sent'};
    if(!current.startsWith(original))return {status:'different_last_user_turn'};
    if(document.querySelector('button[data-testid="stop-button"],button[aria-label*="Stop" i],button[aria-label*="Detener" i]'))return {status:'generating'};
    const selector='#prompt-textarea,div.ProseMirror[contenteditable="true"],textarea[placeholder],div[contenteditable="true"][role="textbox"]';
    const visible=c=>{const r=c.getBoundingClientRect(),v=getComputedStyle(c);return c.isConnected&&!c.disabled&&!c.readOnly&&r.width>12&&r.height>10&&v.display!=='none'&&v.visibility!=='hidden'&&!c.closest('[inert],[aria-hidden="true"]');};
    const composer=[...document.querySelectorAll(selector)].find(visible);
    if(!composer)return {status:'composer_missing'};
    if(String(composer.value||composer.innerText||composer.textContent||'').trim())return {status:'existing_draft'};
    composer.focus();
    return {status:document.activeElement===composer?'ready':'focus_failed'};
  })()`;
}
async function sendSiteReturnFromPublisher(cdp,task,job){
  const marker='TTENDENCIAS_SITE_RETURN_AFTER_IMAGE_V1 '+task.command_id+' '+task.target_id;
  const initial=await cdp.evaluate(siteReturnProbe(task.command_id,task.target_id,marker));
  if(initial?.status!=='ready')return initial?.status||'probe_unavailable';
  const message=siteReturnPrompt(task,job);
  await cdp.call('Input.insertText',{text:message},15000);
  const result=await cdp.evaluate(`(()=>{const marker=${JSON.stringify(marker)},suffix=${JSON.stringify(message.slice(-60))},min=${Math.floor(message.length*0.8)};
    const selector='#prompt-textarea,div.ProseMirror[contenteditable="true"],textarea[placeholder],div[contenteditable="true"][role="textbox"]';
    const read=c=>String(c&&(c.value||c.innerText||c.textContent)||'');
    const composer=[...document.querySelectorAll(selector)].find(c=>read(c).startsWith(marker)&&read(c).includes(suffix)&&read(c).length>=min);
    if(!composer)return 'incomplete_draft';
    const form=composer.closest('form');
    const buttons=[...(form?[...form.querySelectorAll('button[type="submit"],button[data-testid*="send"],button[aria-label*="Send" i],button[aria-label*="Enviar" i]')]:[]),
      ...document.querySelectorAll('button[data-testid="send-button"],button[data-testid="composer-submit-button"],#composer-submit-button')];
    const btn=buttons.find(b=>{const r=b.getBoundingClientRect();return b.isConnected&&!b.disabled&&r.width>1&&r.height>1;});
    if(btn){btn.click();return 'submitted';}
    if(form&&typeof form.requestSubmit==='function'){form.requestSubmit();return 'submitted';}
    return 'send_button_missing';
  })()`);
  if(result!=='submitted')return result||'not_submitted';
  await sleep(1500);
  const after=await cdp.evaluate(`(()=>{const users=(${userTurns.toString()})();const last=users[users.length-1];return String(last&&(last.innerText||last.textContent)||'').trim().startsWith(${JSON.stringify(marker)});})()`);
  return after?'sent_verified':'submitted_not_yet_visible';
}

function sameEditorialBeforeReturn(task,manual){
  const current=(manual.items||[]).filter(x=>String(x.id||'')===task.target_id)
    .sort((a,b)=>Number(b.revision||0)-Number(a.revision||0)||Date.parse(b.explained_at||0)-Date.parse(a.explained_at||0))[0];
  return !!current&&Number(current.revision||0)===task.revision&&crypto.createHash('sha256').update(String(current.explanation||'').trim()).digest('hex')===task.explanation_sha256;
}
async function recoverSiteAfterUpload(task,job){
  const remote=await confirmedInMain(task,job);
  if(task.site_return_sent_at)return remote;
  if(producerBusyFor(task))return {...remote,site_return_status:'producer_still_running'};
  let url=chatURL(task.conversation_url);
  if(!url){
    try{url=await discoverConversation(task.command_id,task.browser_target_id);}
    catch{return {...remote,site_return_status:'conversation_discovery_unavailable'};}
  }
  if(!url)return {...remote,site_return_status:'conversation_not_available'};
  let capture;
  try{capture=await selectExistingBrowser();}
  catch{return {...remote,site_return_status:'browser_unavailable'};}
  // The generator's fixed tab is NEVER navigated or cloned. If the exact
  // command's conversation is STILL open there after the producer exited,
  // it can safely receive a no-ImageGen Site follow-up. Otherwise only an
  // independently authenticated relay can open the retained conversation.
  let browserCDP,cdp,ownedTarget;
  try{
    if(capture.source==='generator_9223'){
      const pages=await http(capture.base+'/json/list');
      const exact=pages.find(x=>x.type==='page'&&chatURL(x.url)===url&&x.webSocketDebuggerUrl&&
        String(x.id||'')===String(task.browser_target_id||''));
      if(!exact)return {...remote,site_return_status:'original_generator_tab_not_present'};
      cdp=new CDP(exact.webSocketDebuggerUrl);await cdp.open();
    }else{
      browserCDP=new CDP(capture.browser.webSocketDebuggerUrl);await browserCDP.open();
      const made=await browserCDP.call('Target.createTarget',{url,background:true});
      ownedTarget=made.targetId;
      for(let n=0;n<10;n++){
        const pages=await http(capture.base+'/json/list');
        const own=pages.find(x=>x.id===ownedTarget);
        if(own?.webSocketDebuggerUrl){cdp=new CDP(own.webSocketDebuggerUrl);await cdp.open();break;}
        await sleep(400);
      }
    }
    if(!cdp)return {...remote,site_return_status:'relay_tab_not_ready'};
    let raster;
    for(let n=0;n<18;n++){
      await sleep(1000);
      raster=await cdp.evaluate(rasterProbe(task.command_id));
      if(raster?.ready||raster?.reason==='later_user_turn'||raster?.reason==='capture_requires_sign_in')break;
    }
    if(!raster?.ready)return {...remote,site_return_status:raster?.reason||'original_not_ready'};
    const fresh=await readImageJob(task);
    if(!sameContext(task,fresh))return {...remote,site_return_status:'identity_changed'};
    const editorial=await readEditorialState();
    if(!sameEditorialBeforeReturn(task,editorial))return {...remote,site_return_status:'editorial_changed'};
    const status=await sendSiteReturnFromPublisher(cdp,task,fresh);
    const sent=status==='sent_verified'||status==='already_sent';
    return {...remote,site_return_status:status,...(sent?{site_return_sent_at:new Date().toISOString()}:{}),
      ...(task.conversation_url?{}:{conversation_url:url})};
  }catch(e){return {...remote,site_return_status:'deferred_'+String(e?.message||e).replace(/https?:\/\/\S+/g,'[url]').slice(0,65)};}
  finally{
    cdp?.close();
    if(ownedTarget)try{await browserCDP?.call('Target.closeTarget',{targetId:ownedTarget});}catch{}
    browserCDP?.close();
  }
}

async function deliverSavedTrendOriginal(task,raster){
 const fresh=await readImageJob(task);
 if(!sameContext(task,fresh))return {status:'obsolete',reason:'job_changed_before_upload'};
 const manual=await readEditorialState();
 if(!sameEditorialBeforeReturn(task,manual))return {status:'obsolete',reason:'editorial_changed'};
 try{
  const contract=await http('https://tt-control.fabricelop.workers.dev/api/ttendencias-run-status?view=web-image-contract');
  if(contract.web_image_receipt!==2)return {status:'waiting',reason:'receiver_update_pending'};
 }catch{return {status:'waiting',reason:'receiver_update_pending'};}
 const response=await fetch('https://tt-control.fabricelop.workers.dev/api/ttendencias-run',{
  method:'POST',headers:{'content-type':'application/json'},signal:AbortSignal.timeout(45000),
  body:JSON.stringify({task:'web_image_upload',context_explanation_sha256:task.explanation_sha256,
   target_id:task.target_id,command_id:task.command_id,upload_secret:protect(task.secret_dpapi,true),
   image_data_url:raster.dataUrl,
   capture:{method:'original-fetch-img-web-consumer',width:raster.width,height:raster.height}})});
 const result=await response.json();
 if(response.ok&&result.status==='DONE')return {
   status:'waiting',reason:'upload_accepted_awaiting_main_confirmation',
   capture_browser:'durable_local',sha256:String(result.sha256||''),
   image_path:String(result.image_path||''),upload_accepted_at:new Date().toISOString()};
 if([401,409,422].includes(response.status))
    return {status:'rejected',reason:String(result.error||'context_rejected').slice(0,140)};
 throw Error('image_upload_HTTP_'+response.status);
}
async function consume(task){
  const job=await readImageJob(task);
  if(!sameContext(task,job))return {status:'obsolete',reason:'job_identity_changed'};
  if((job.status==='DONE'&&job.upload_sha256)||task.upload_accepted_at||task.status==='published')return recoverSiteAfterUpload(task,job);
  if(['CANCELLED','SUPERSEDED'].includes(String(job.status).toUpperCase()))return {status:'obsolete',reason:'image_job_terminal'};
  // An already-captured original survives temporary receiver/browser outages.
  const saved=loadCachedOriginal(task);
  if(saved)return deliverSavedTrendOriginal(task,saved);
  // ERROR is not proof that no image exists. This consumer NEVER generates:
  // it can only read a raster after this command's exact user turn.
  if(!chatURL(task.conversation_url)){
    try{
      const found=await discoverConversation(task.command_id,task.browser_target_id,true);
      if(!found.url)return {status:'waiting',reason:'awaiting_command_conversation:'+found.reason};
      task.conversation_url=found.url;
      task.browser_target_id=found.browser_target_id;
    }catch{return {status:'waiting',reason:'conversation_discovery_unavailable'};}
  }
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
    // Persist the exact original BEFORE checking the network receiver.
    raster=cacheRaster(task,raster);
    try{
    const contract=await http('https://tt-control.fabricelop.workers.dev/api/ttendencias-run-status?view=web-image-contract');
    if(contract.web_image_receipt!==2)return {status:'waiting',reason:'receiver_update_pending'};
    }catch{return {status:'waiting',reason:'receiver_update_pending'};}
    // Fresh job identity check immediately before sending raster bytes.
    const fresh=await readImageJob(task);
    if(!sameContext(task,fresh))return {status:'obsolete'};
    const manual=await readEditorialState();
    const current=(manual.items||[]).filter(x=>String(x.id)===task.target_id).sort((a,b)=>Number(b.revision||0)-Number(a.revision||0)||Date.parse(b.explained_at||0)-Date.parse(a.explained_at||0))[0];
    if(!current||Number(current.revision||0)!==task.revision||crypto.createHash('sha256').update(String(current.explanation||'').trim()).digest('hex')!==task.explanation_sha256)return {status:'obsolete'};
    // Recover native Site/App attachment from the existing original only.
    let siteReturnStatus=String(task.site_return_status||'');
    if(capture.source==='relay_9234'&&!task.site_return_sent_at&&!producerBusyFor(task)){
      try{siteReturnStatus=await sendSiteReturnFromPublisher(cdp,task,fresh);}
      catch(e){siteReturnStatus='deferred_'+String(e?.message||e).replace(/https?:\/\/\S+/g,'[url]').slice(0,70);}
    }
    const siteReturnSent=siteReturnStatus==='already_sent'||siteReturnStatus==='sent_verified';
    const siteReturnReceipt={site_return_status:siteReturnStatus,
      ...(siteReturnSent?{site_return_sent_at:new Date().toISOString()}:{})};
    const response=await fetch('https://tt-control.fabricelop.workers.dev/api/ttendencias-run',{method:'POST',headers:{'content-type':'application/json'},signal:AbortSignal.timeout(45000),body:JSON.stringify({task:'web_image_upload',context_explanation_sha256:task.explanation_sha256,target_id:task.target_id,command_id:task.command_id,upload_secret:protect(task.secret_dpapi,true),image_data_url:raster.dataUrl,capture:{method:'original-fetch-img-web-consumer',width:raster.width,height:raster.height}})});
    const result=await response.json();
    if(response.ok&&result.status==='DONE')return {status:'waiting',reason:'upload_accepted_awaiting_main_confirmation',capture_browser:capture.source,sha256:String(result.sha256||''),image_path:String(result.image_path||''),upload_accepted_at:new Date().toISOString(),...siteReturnReceipt};
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
// Prefer only the newest eligible command per exact editorial ID.
// Older receipts remain on disk for fallback if the newer attempt fails;
// they never steal capture time from a new image or a different target.
function newestActiveByTarget(entries,now){
  const active=new Map();
  for(const entry of entries){
    const task=entry.task||{},id=String(task.target_id||'');
    if(!safeID(id)||!safeID(task.command_id))continue;
    if(!['waiting','published'].includes(task.status))continue;
    const created=Date.parse(task.created_at||'');
    if(!Number.isFinite(created)||now-created>72*3600000)continue;
    const old=active.get(id),oldDate=Date.parse(old?.task.created_at||'');
    if(!old||created>oldDate||(created===oldDate&&task.command_id>old.task.command_id))active.set(id,entry);
  }
  return active;
}
function dueTasks(entries,now){
  const current=newestActiveByTarget(entries,now);
  return entries.filter(entry=>{
    const t=entry.task||{};
    if(!['waiting','published'].includes(t.status))return false;
    if(current.has(t.target_id)&&current.get(t.target_id)!==entry)return false;
    if(t.status==='published'&&
      (t.site_return_sent_at||!chatURL(t.conversation_url)||
       !Number.isFinite(Date.parse(t.created_at||''))||
       now-Date.parse(t.created_at)>72*3600000))return false;
    return !Number.isFinite(Date.parse(t.next_check_at||''))||Date.parse(t.next_check_at)<=now;
  }).sort((a,b)=>Date.parse(b.task.created_at||0)-Date.parse(a.task.created_at||0));
}
function prioritizeOpenConversation(tasks,pages,currentCommand=null){
  // Opportunistic read of the completed current conversation before the
  // generator reuses its tab. This changes priority, never identity checks.
  const open=new Set(pages.filter(x=>x.type==='page').map(x=>chatURL(x.url)).filter(Boolean));
  const targets=new Set(pages.filter(x=>x.type==='page').map(x=>String(x.id||'')).filter(Boolean));
  // The conversation URL often has not settled at enrollment. Prioritizing
  // only saved URLs let older waiting jobs consume the entire retained-tab
  // window. A pinned target is scheduling evidence ONLY: consume still proves
  // the exact command in that page before accepting its URL or raster.
  return tasks.map((entry,index)=>({entry,index,current:!!currentCommand&&entry.task.command_id===currentCommand.command_id&&entry.task.target_id===currentCommand.target_id,open:open.has(entry.task.conversation_url)||
    (!chatURL(entry.task.conversation_url)&&targets.has(String(entry.task.browser_target_id||'')))}))
    .sort((a,b)=>Number(b.current)-Number(a.current)||Number(b.open)-Number(a.open)||a.index-b.index).map(x=>x.entry);
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
    try{const pages=await http(GENERATOR_BASE+'/json/list');due=prioritizeOpenConversation(due,pages,await currentPinnedCommand(pages));}catch{}
    for(const {file,task} of due.slice(0,1)){
      if(!safeID(task.target_id)||!safeID(task.command_id)||(!chatURL(task.conversation_url)&&!safeID(task.browser_target_id))||
        !/^[a-f0-9]{64}$/.test(String(task.explanation_sha256||''))||
        (!task.secret_dpapi&&task.status==='waiting')){
        atomic(file,{...task,status:'rejected',reason:'invalid_enrollment',secret_dpapi:undefined});
        console.log('TTENDENCIAS_WEB_IMAGE '+String(task.target_id||'?')+' rejected_invalid_enrollment');
        continue;
      }
      // Keep pending images recoverable for three days without ever allowing
      // a stuck/slow generation to delay later images.
      if(!Number.isFinite(Date.parse(task.created_at||''))||now-Date.parse(task.created_at)>72*3600000){
        atomic(file,{...task,status:'needs_review',reason:'original_not_associated_within_72h',
          paused_at:new Date().toISOString(),next_check_at:undefined});
        console.log('TTENDENCIAS_WEB_IMAGE '+task.target_id+' needs_review_preserved_original');
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
module.exports={chatURL,enroll,rememberConversation,conversationProbe,discoverConversation,rasterProbe,cacheRaster,loadCachedOriginal,sameContext,confirmedInMain,dueTasks,prioritizeOpenConversation,readImageJob,readEditorialState,selectExistingBrowser,consume,wakePublisher,watch,once,siteReturnPrompt,siteReturnProbe,producerBusyFor,sameEditorialBeforeReturn,recoverSiteAfterUpload,newestActiveByTarget};
// Existing installed listeners invoke this file without arguments. Drain their
// already-enrolled backlog too; do not require a new image to wake delivery.
if(require.main===module)(process.argv.includes('--once')?once():watch()).catch(()=>{console.error('TTENDENCIAS_WEB_IMAGE exporter unavailable');process.exitCode=1;});
