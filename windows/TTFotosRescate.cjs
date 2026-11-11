'use strict';
/*
 * TT Fotos: recovery / reconciliation without regenerating images or approving.
 * --scan       Local inventory only, including caches, staged rasters, receipts, and orphans.
 * --capture    Read ONLY already-open ChatGPT conversation tabs with an exact command marker.
 * --deliver    Retry ONLY exact, verified local originals to the existing private inbox.
 * --rescue     Capture from already-open chats, then retry local deliveries.
 * --serve      Host private read-only recovery dashboard on 127.0.0.1:8765.
 * --import-dir PATH  Inventory downloaded PNGs; never auto-bind by appearance.
 * No interactions with the ChatGPT Images library API; none is available here.
 */
const fs=require('node:fs');
const path=require('node:path');
const http=require('node:http');
const crypto=require('node:crypto');
const {execFileSync}=require('node:child_process');
const SHA=/^[a-f0-9]{64}$/i;
const COMMAND=/^(tt|tr)-img-auto-[a-z0-9_-]{12,145}$/i;
const PROJECTS={ttittulares:'ttittulares-web-images',ttendencias:'ttendencias-web-images'};
const basename=path.basename;
const hash=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
const safe=x=>String(x==null?'':x).slice(0,250);
const safeRead=(file)=>{try{return JSON.parse(fs.readFileSync(file,'utf8'))}catch{return null}};
const validId=x=>/^[A-Za-z0-9_.-]{3,160}$/.test(String(x||''));
const goodPNG=(bytes)=>Buffer.isBuffer(bytes)&&bytes.length>=24&&bytes.length<=8388608&&bytes.subarray(0,8).equals(Buffer.from('89504e470d0a1a0a','hex'));
const dirs=base=>({receipts:path.join(base,'image-approval-receipts'),staged:path.join(base,'image-approval-receipts','immediate-originals'),cached:path.join(base,'image-approval-receipts','original-cache')});
const DATE=/^\d{4}-\d{2}-\d{2}$/;
function madridDate(value){
  const date=new Date(value||'');
  if(!Number.isFinite(date.getTime()))return null;
  const parts=Object.fromEntries(new Intl.DateTimeFormat('en-GB',{timeZone:'Europe/Madrid',year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(date).map(x=>[x.type,x.value]));
  return `${parts.year}-${parts.month}-${parts.day}`;
}
function eligibleDate(task,since){
  if(!since)return true;
  if(!DATE.test(since)||!Number.isFinite(Date.parse(since)))throw Error('INVALID_SINCE_DATE');
  const candidate=madridDate(task.created_at||task.createdAt||task.requested_at);
  return candidate!==null&&candidate>=since;
}
function validImportDir(importDir){
  if(!importDir)return null;
  if(!fs.existsSync(importDir)||!fs.statSync(importDir).isDirectory())throw Error('IMPORT_DIRECTORY_NOT_FOUND');
  return fs.realpathSync(importDir);
}

function enrollmentFiles(base){
  const rows=[];
  for(const [project,folder] of Object.entries(PROJECTS)){
    const dir=path.join(base,folder);
    if(!fs.existsSync(dir))continue;
    for(const name of fs.readdirSync(dir).filter(x=>x.endsWith('.json'))){
      const task=safeRead(path.join(dir,name));
      if(!task||!COMMAND.test(String(task.command_id||''))||!validId(task.target_id)||!Number.isInteger(task.revision)||task.revision<0)continue;
      rows.push({...task,project});
    }
  }
  // Exact enrollment per command: collisions are recorded and never automatically sent.
  const map=new Map(),duplicates=new Set();
  for(const t of rows){
    const prev=map.get(t.command_id);
    if(prev)duplicates.add(t.command_id);
    else if(!prev)map.set(t.command_id,t);
  }
  return {map,duplicates};
}
function checkedOriginal(file,meta){
  if(!fs.existsSync(file)||!meta)return null;
  const bytes=fs.readFileSync(file);
  if(!goodPNG(bytes)||!SHA.test(String(meta.sha256||meta.rasterSHA256||''))||hash(bytes)!==String(meta.sha256||meta.rasterSHA256).toLowerCase())return null;
  return bytes;
}
function storedOriginal(base,task){
  const d=dirs(base),id=task.command_id;
  let staged=null,cached=null;
  const stagedMeta=safeRead(path.join(d.staged,id+'.json'));
  if(stagedMeta&&stagedMeta.project===task.project&&stagedMeta.commandId===id&&
      stagedMeta.editorialId===task.target_id&&Number(stagedMeta.revision)===task.revision&&
      stagedMeta.editorialFingerprint===String(task.editorial_sha256||task.explanation_sha256||'')){
    staged=checkedOriginal(path.join(d.staged,id+'.png'),stagedMeta);
  }
  const cacheMeta=safeRead(path.join(d.cached,id+'.json'));
  if(cacheMeta&&cacheMeta.commandId===id&&cacheMeta.editorialId===task.target_id&&
      Number(cacheMeta.revision)===task.revision){
    cached=checkedOriginal(path.join(d.cached,id+'.png'),cacheMeta);
  }
  // Disagreement between two originals for the same command is not evidence
  // to choose the newest: it is a conflict that requires inspection.
  if(staged&&cached&&hash(staged)!==hash(cached))return null;
  if(staged)return {bytes:staged,source:'immediate-originals'};
  if(cached)return {bytes:cached,source:'original-cache'};
  return null;
}
// A downloaded PNG is a human-confirmed editorial association, NOT proof that
// the original ImageGen command generated these exact bytes. Preserve this
// distinction in the ledger and require the editor to select a precise job.
function readManualLinks(base){
  const file=path.join(dirs(base).receipts,'tt-fotos-manual-links.json');
  const data=safeRead(file);
  return Array.isArray(data?.items)?data.items:[];
}
function manualOriginal(base,link){
  if(!SHA.test(String(link?.sha256||'')))return null;
  const file=path.join(dirs(base).receipts,'manual-originals',link.sha256+'.png');
  const bytes=checkedOriginal(file,{sha256:link.sha256});
  return bytes||null;
}
function writeManualLinks(base,links){
  const root=dirs(base).receipts,file=path.join(root,'tt-fotos-manual-links.json');
  fs.mkdirSync(root,{recursive:true,mode:0o700});
  const tmp=file+'.'+process.pid+'.'+crypto.randomBytes(6).toString('hex')+'.tmp';
  try{fs.writeFileSync(tmp,JSON.stringify({version:1,items:links},null,2),{flag:'wx',mode:0o600});fs.renameSync(tmp,file)}
  finally{try{fs.unlinkSync(tmp)}catch{}}
}
function associateManual(base,importDir,{file,commandId,sha256,confirmation}){
  if(confirmation!=='CONFIRMO_ASOCIACION_MANUAL')throw Error('EDITOR_CONFIRMATION_REQUIRED');
  if(!importDir)throw Error('IMPORT_DIRECTORY_REQUIRED');
  if(typeof file!=='string'||file.length>245||file!==path.basename(file)||!file.toLowerCase().endsWith('.png'))throw Error('BAD_IMPORT_NAME');
  if(!COMMAND.test(String(commandId||''))||!SHA.test(String(sha256||'')))throw Error('BAD_ASSOCIATION_IDENTITY');
  const {map,duplicates}=enrollmentFiles(base),task=map.get(commandId);
  if(!task||duplicates.has(commandId))throw Error('JOB_IDENTITY_NOT_UNIQUE');
  const root=validImportDir(importDir),pathCandidate=path.join(root,file);
  if(!fs.existsSync(pathCandidate)||!fs.statSync(pathCandidate).isFile())throw Error('IMPORT_NOT_FOUND');
  if(!fs.realpathSync(pathCandidate).startsWith(root+path.sep))throw Error('IMPORT_PATH_OUTSIDE_DIRECTORY');
  if(fs.statSync(pathCandidate).size>8388608)throw Error('IMPORT_TOO_BIG');
  const bytes=fs.readFileSync(pathCandidate);
  if(!goodPNG(bytes)||hash(bytes)!==sha256.toLowerCase())throw Error('IMPORTED_PNG_HASH_CHANGED');
  if(storedOriginal(base,task))throw Error('EXACT_ORIGINAL_ALREADY_AVAILABLE');
  if(fs.existsSync(path.join(dirs(base).receipts,commandId+'.json')))throw Error('EXISTING_RECEIPT_REPLACEMENT_NOT_SUPPORTED');
  const existing=readManualLinks(base).find(x=>x.commandId===commandId);
  if(existing){
    if(existing.sha256!==sha256.toLowerCase())throw Error('DIFFERENT_MANUAL_IMAGE_FOR_COMMAND');
    return existing;
  }
  const originalDir=path.join(dirs(base).receipts,'manual-originals');
  fs.mkdirSync(originalDir,{recursive:true,mode:0o700});
  const dest=path.join(originalDir,sha256.toLowerCase()+'.png');
  if(fs.existsSync(dest)){
    if(hash(fs.readFileSync(dest))!==sha256.toLowerCase())throw Error('ORIGINAL_HASH_COLLISION');
  }else{
    const tmp=dest+'.'+process.pid+'.'+crypto.randomBytes(6).toString('hex')+'.tmp';
    try{fs.writeFileSync(tmp,bytes,{flag:'wx',mode:0o600});if(!fs.existsSync(dest))fs.renameSync(tmp,dest)}
    finally{try{fs.unlinkSync(tmp)}catch{}}
  }
  const entry={commandId,project:task.project,editorialId:task.target_id,revision:task.revision,
    sha256:sha256.toLowerCase(),sourceFile:file,confirmedAt:new Date().toISOString(),
    provenance:'editor_manual_selection_from_download',state:'CONFIRMED_MANUALLY_NOT_DELIVERED'};
  // Persist for audit. Duplicate requests of the exact image are idempotent.
  const links=readManualLinks(base);
  const late=links.find(x=>x.commandId===commandId);
  if(late){if(late.sha256===entry.sha256)return late;throw Error('MANUAL_ASSOCIATION_RACE')}
  writeManualLinks(base,[...links,entry]);
  return entry;
}
async function deliverManual(base,commandId,{getReceiver=receiver,getSource=source,getInbox=null,readSecret=decryptDPAPI,send=null}={}){
  const {map,duplicates}=enrollmentFiles(base),task=map.get(commandId);
  if(!task||duplicates.has(commandId))throw Error('JOB_IDENTITY_NOT_UNIQUE');
  const links=readManualLinks(base),entry=links.find(x=>x.commandId===commandId);
  if(!entry||entry.provenance!=='editor_manual_selection_from_download'||entry.project!==task.project||
     entry.editorialId!==task.target_id||entry.revision!==task.revision)throw Error('MANUAL_ASSOCIATION_NOT_PROVEN');
  if(fs.existsSync(path.join(dirs(base).receipts,commandId+'.json')))throw Error('EXISTING_RECEIPT_REPLACEMENT_NOT_SUPPORTED');
  if(!task.secret_dpapi)throw Error('MISSING_PRIVATE_INGEST_SECRET');
  const bytes=manualOriginal(base,entry);
  if(!bytes)throw Error('MANUAL_ORIGINAL_MISSING_OR_CHANGED');
  const app=getReceiver(base),imageSource=getSource(base,task.project),inbox=getInbox?getInbox(base):require(path.join(base,'TTImagesImmediateInbox.cjs'));
  const job=await app.editorialJob(imageSource,task),meta=app.metadata(task,job);
  if(meta.project!==entry.project||meta.editorialId!==entry.editorialId||
     meta.revision!==entry.revision||meta.commandId!==entry.commandId)throw Error('EDITORIAL_EPISODE_CONFLICT');
  const fresh=await app.editorialJob(imageSource,task);
  if(app.metadata(task,fresh).episodeFingerprint!==meta.episodeFingerprint)throw Error('EDITORIAL_EPISODE_CHANGED');
  const receipt=await (send||app.send)(meta,bytes,readSecret(task.secret_dpapi));
  if(receipt.rasterSHA256!==entry.sha256)throw Error('MANUAL_RECEIPT_SHA_MISMATCH');
  inbox.saveReceipt(base,task,meta,receipt);
  const proof=inbox.readReceipt(base,task);
  if(!proof||proof.rasterSHA256!==entry.sha256)throw Error('RECEIPT_NOT_DURABLE');
  return {commandId,result:'DELIVERED_'+receipt.state,receiptId:receipt.id};
}

function inventory(base,{importDir=null,since=null}={}){
  const d=dirs(base),{map,duplicates}=enrollmentFiles(base),progress=safeRead(path.join(d.receipts,'receiver-status.json'))||{};
  const jobs=[],known=new Set(map.keys()),links=readManualLinks(base),manualByCommand=new Map(links.map(x=>[x.commandId,x]));
  for(const [commandId,task] of map){
    if(!eligibleDate(task,since))continue;
    const rec=safeRead(path.join(d.receipts,commandId+'.json'));
    const receipt=!!(rec&&rec.commandId===commandId&&rec.editorialId===task.target_id&&rec.project===task.project&&Number(rec.revision)===task.revision&&SHA.test(String(rec.rasterSHA256||''))&&SHA.test(String(rec.id||'')));
    const original=storedOriginal(base,task),manual=manualByCommand.get(commandId),manualBytes=manual?manualOriginal(base,manual):null,reason=progress[commandId]?.reason||'';
    const conflict=duplicates.has(commandId);
    let phase=receipt?'RECIBIDA_CON_RECIBO':original?'ORIGINAL_LOCAL_SIN_ENTREGAR':conflict?'IDENTIDAD_DUPLICADA':
       /error|fail|conflict|missing|unavailable|stale|not_ready|not_loaded|unconfirmed/i.test(reason)?'ERROR_O_BLOQUEO':'IMAGEN_NO_VERIFICADA';
    if(conflict)phase='IDENTIDAD_DUPLICADA';
    else if(!receipt&&!original&&manualBytes)phase='ASOCIADA_MANUAL_PENDIENTE_ENTREGA';
    jobs.push({project:task.project,commandId,id:task.target_id,revision:task.revision,
      createdAt:task.created_at||'',title:task.target_name||task.name||task.title||task.target_id,
      phase,reason:safe(reason),originalSource:original?.source||null,originalSha:original?hash(original.bytes):null,
      hasSecret:!!task.secret_dpapi,manualAssociation:manualBytes?{sha256:manual.sha256,confirmedAt:manual.confirmedAt,sourceFile:manual.sourceFile}:null,receiptState:receipt?safe(rec.state):null,
      conversationUrl:typeof task.conversation_url==='string'&&/^https:\/\/chatgpt\.com\/c\/[a-f0-9-]{10,100}$/i.test(task.conversation_url)?task.conversation_url:null});
  }
  const unassociated=[];
  for(const folder of [d.staged,d.cached]){
    if(!fs.existsSync(folder))continue;
    for(const name of fs.readdirSync(folder).filter(x=>x.toLowerCase().endsWith('.png'))){
      const commandId=name.slice(0,-4);
      if(known.has(commandId))continue;
      const meta=safeRead(path.join(folder,commandId+'.json'));
      const bytes=checkedOriginal(path.join(folder,name),meta);
      unassociated.push({file:name,commandId,source:basename(folder),phase:bytes?'ORIGINAL_HUERFANO_VERIFICADO':'ORIGINAL_SIN_METADATOS_VERIFICABLES',sha:bytes?hash(bytes):null,
        project:meta?.project||null,id:meta?.editorialId||null,revision:meta?.revision??null});
    }
  }
  if(importDir&&fs.existsSync(importDir)){
    for(const name of fs.readdirSync(importDir).filter(x=>x.toLowerCase().endsWith('.png')).slice(0,10000)){
      const file=path.join(importDir,name),stat=fs.statSync(file);
      if(!stat.isFile()||stat.size>8388608)continue;
      const bytes=fs.readFileSync(file);
      if(!goodPNG(bytes))continue;
      const exact=[...map.keys()].filter(command=>name.includes(command));
      const already=links.find(x=>x.sourceFile===name&&x.sha256===hash(bytes));
      unassociated.push({file:name,source:'CARPETA_DESCARGAS',sha:hash(bytes),phase:already?'ASOCIADA_MANUAL':exact.length===1?'CANDIDATO_POR_NOMBRE_REQUIERE_REVISION':'HUERFANO_REQUIERE_ASOCIACION',linkedCommandId:already?.commandId||null,
        commandId:exact.length===1?exact[0]:null,project:exact.length===1?map.get(exact[0]).project:null});
    }
  }
  jobs.sort((a,b)=>String(b.createdAt).localeCompare(String(a.createdAt)));
  const counts={total:jobs.length,received:jobs.filter(x=>x.phase==='RECIBIDA_CON_RECIBO').length,
    originalNotDelivered:jobs.filter(x=>x.phase==='ORIGINAL_LOCAL_SIN_ENTREGAR').length,
    blocked:jobs.filter(x=>x.phase==='ERROR_O_BLOQUEO'||x.phase==='IDENTIDAD_DUPLICADA').length,
    notVerified:jobs.filter(x=>x.phase==='IMAGEN_NO_VERIFICADA').length,manualPending:jobs.filter(x=>x.phase==='ASOCIADA_MANUAL_PENDIENTE_ENTREGA').length,orphans:unassociated.length};
  return {generatedAt:new Date().toISOString(),scope:'local_windows_enrollments_and_files_only',since,counts,jobs,orphans:unassociated};
}
function receiver(base){const file=path.join(base,'TTImageApprovalReceiver.cjs');if(!fs.existsSync(file))throw Error('MISSING_APPROVAL_RECEIVER');return require(file)}
function source(base,project){const name=project==='ttendencias'?'TTendenciasWebImages.cjs':'TTiTTularesWebImages.cjs';const file=path.join(base,name);if(!fs.existsSync(file))throw Error('MISSING_IMAGE_SOURCE');return require(file)}
function decryptDPAPI(value){
  if(process.platform!=='win32')throw Error('WINDOWS_REQUIRED_FOR_SECRET');
  const code='$s=ConvertTo-SecureString ([Console]::In.ReadToEnd());$p=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($s);try{[Console]::Write([Runtime.InteropServices.Marshal]::PtrToStringBSTR($p))}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p)}';
  return execFileSync('powershell.exe',['-NoProfile','-NonInteractive','-Command',code],{input:value,encoding:'utf8',windowsHide:true,timeout:15000,maxBuffer:65536}).trim();
}
async function deliver(base,{limit=15,fetcher=undefined,since=null}={}){
  // Manual operation only. Same private-ingest endpoint and same strict identity as the current receiver.
  const out=[];
  {
    const {map,duplicates}=enrollmentFiles(base),app=receiver(base),inbox=require(path.join(base,'TTImagesImmediateInbox.cjs'));
    for(const task of [...map.values()].filter(t=>eligibleDate(t,since)).sort((a,b)=>String(b.created_at||'').localeCompare(String(a.created_at||'')))){
      if(out.length>=limit)break;
      if(duplicates.has(task.command_id)||!task.secret_dpapi||!storedOriginal(base,task)||fs.existsSync(path.join(dirs(base).receipts,task.command_id+'.json')))continue;
      let status='ERROR';
      try{
        const item=await app.editorialJob(source(base,task.project),task);
        const meta=app.metadata(task,item);
        const local=storedOriginal(base,task);if(!local)throw Error('ORIGINAL_NOT_VERIFIED');
        // A receiver-cache PNG also has an episode SHA that must match the
        // freshly reconstructed editorial episode. Do not trust its name alone.
        if(local.source==='original-cache'){
          const verified=app.cachedOriginal(base,task,meta);
          if(!verified||hash(verified)!==hash(local.bytes))throw Error('CACHE_EPISODE_CONFLICT');
        }else{
          const staged=inbox.loadStaged(base,task);
          if(!staged||hash(staged)!==hash(local.bytes))throw Error('STAGED_EPISODE_CONFLICT');
        }
        // Both editorial job, episode SHA, enrollment and original SHA verified just before upload.
        const fresh=await app.editorialJob(source(base,task.project),task);
        if(app.metadata(task,fresh).episodeFingerprint!==meta.episodeFingerprint)throw Error('EDITORIAL_EPISODE_CHANGED');
        const secret=decryptDPAPI(task.secret_dpapi);
        const receipt=await app.send(meta,local.bytes,secret,fetcher);
        if(hash(local.bytes)!==receipt.rasterSHA256)throw Error('RECEIPT_SHA_MISMATCH');
        inbox.saveReceipt(base,task,meta,receipt);
        const proof=inbox.readReceipt(base,task);
        if(!proof||proof.rasterSHA256!==hash(local.bytes))throw Error('RECEIPT_NOT_DURABLE');
        status='DELIVERED_'+receipt.state;
      }catch(e){status=/^[A-Z0-9_]+$/.test(String(e.message))?String(e.message):'DELIVERY_FAILED'}
      out.push({project:task.project,commandId:task.command_id,result:status});
    }
  }
  return out;
}
class CDP{
  constructor(url){this.url=url;this.id=0;this.pending=new Map()}
  async open(){this.ws=new WebSocket(this.url);await new Promise((yes,no)=>{let t=setTimeout(()=>no(Error('CDP_TIMEOUT')),5000);this.ws.addEventListener('open',()=>{clearTimeout(t);yes()},{once:true});this.ws.addEventListener('error',()=>{clearTimeout(t);no(Error('CDP_UNAVAILABLE'))},{once:true})});this.ws.addEventListener('message',e=>{let m;try{m=JSON.parse(String(e.data))}catch{return}const p=this.pending.get(m.id);if(!p)return;this.pending.delete(m.id);clearTimeout(p.timer);m.error?p.no(Error('CDP_FAILED')):p.yes(m.result)})}
  async evaluate(expression){const id=++this.id;const r=await new Promise((yes,no)=>{const timer=setTimeout(()=>{this.pending.delete(id);no(Error('CDP_TIMEOUT'))},15000);this.pending.set(id,{yes,no,timer});this.ws.send(JSON.stringify({id,method:'Runtime.evaluate',params:{expression,returnByValue:true,awaitPromise:true}}))});if(r.exceptionDetails)throw Error('CDP_EVALUATION_FAILED');return r.result?.value}
  close(){for(const p of this.pending.values()){clearTimeout(p.timer);p.no(Error('CDP_CLOSED'))}this.pending.clear();try{this.ws.close()}catch{}}
}
async function openPages(){
  const out=[],seen=new Set();
  for(const port of [9223,9234]){
    let list=[];try{const r=await fetch('http://127.0.0.1:'+port+'/json/list',{signal:AbortSignal.timeout(3000)});list=await r.json()}catch{continue}
    if(!Array.isArray(list))continue;
    for(const p of list){
      if(p.type!=='page'||!p.webSocketDebuggerUrl||!/^https:\/\/chatgpt\.com\/c\//i.test(String(p.url||''))||seen.has(p.id))continue;
      seen.add(p.id);out.push(p);
    }
  }
  return out.slice(0,25);
}
async function capture(base,{limit=25,since=null,offset=null}={}){
  if(process.platform!=='win32')throw Error('WINDOWS_REQUIRED_FOR_CHROME');
  const out=[];
  {
    const pages=await openPages(),{map,duplicates}=enrollmentFiles(base),inbox=require(path.join(base,'TTImagesImmediateInbox.cjs'));
    const all=[...map.values()].filter(t=>eligibleDate(t,since)&&!duplicates.has(t.command_id)&&!storedOriginal(base,t)&&!fs.existsSync(path.join(dirs(base).receipts,t.command_id+'.json')))
      .sort((a,b)=>String(b.created_at||'').localeCompare(String(a.created_at||'')));
    // Remember the last scan position so repeated --rescue passes don't probe
    // the same missing-image commands forever. Explicit --offset can override.
    const cursorFile=path.join(dirs(base).receipts,'tt-fotos-capture-cursor.json');
    const cursor=safeRead(cursorFile);
    const start=Number.isInteger(offset)?Math.max(0,offset):
      (cursor?.since===since&&Number.isInteger(cursor?.offset)?cursor.offset:0);
    const candidates=all.slice(start,start+limit);
    if(!Number.isInteger(offset)&&all.length){
      fs.mkdirSync(dirs(base).receipts,{recursive:true});
      const tmp=cursorFile+'.'+process.pid+'.tmp';
      try{fs.writeFileSync(tmp,JSON.stringify({since,offset:(start+candidates.length)%all.length,at:new Date().toISOString()}));fs.renameSync(tmp,cursorFile)}finally{try{fs.unlinkSync(tmp)}catch{}}
    }
    // No browser navigation, tab creation, user message, or image generation.
    for(const task of candidates){
      const module=source(base,task.project);
      let status='NO_EXACT_ORIGINAL_VISIBLE';
      for(const page of pages){
        let cdp;
        try{
          cdp=new CDP(page.webSocketDebuggerUrl);await cdp.open();
          const found=await cdp.evaluate(module.rasterProbe(task.command_id,true));
          if(found?.ready&&String(found.dataUrl||'').startsWith('data:image/png;base64,')){
            const bytes=inbox.parsePNG(found),valid=goodPNG(bytes);
            if(!valid)throw Error('INVALID_PNG');
            inbox.stageOriginal(base,task,bytes);status='CAPTURED_EXACT_ORIGINAL';break;
          }
        }catch(e){status='CDP_CAPTURE_DEFERRED'}finally{try{cdp?.close()}catch{}}
      }
      out.push({project:task.project,commandId:task.command_id,result:status});
    }
  }
  return out;
}
function serve(base,{port=8765,importDir=null,since=null}={}){
  const html=fs.readFileSync(path.join(__dirname,'TTFotosRescatePanel.html'),'utf8');
  const server=http.createServer((req,res)=>{
    const actualPort=server.address()?.port||port;
    const host=req.headers.host||'';
    const allowed='http://127.0.0.1:'+actualPort;
    const allowedLocalhost='http://localhost:'+actualPort;
    if(host!=='127.0.0.1:'+actualPort&&host!=='localhost:'+actualPort){res.writeHead(403);return res.end()}
    if(req.headers['sec-fetch-site']==='cross-site'||(req.headers.origin&&!([allowed,allowedLocalhost].includes(req.headers.origin)))){res.writeHead(403);return res.end()}
    const pathname=new URL(req.url,allowed).pathname;
    const heads={'Cache-Control':'private, no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer','X-Frame-Options':'DENY','Cross-Origin-Resource-Policy':'same-origin',
      'Content-Security-Policy':"default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'"};
    if(req.method==='POST'&&['/api/associate','/api/deliver-manual'].includes(pathname)){
      if(!importDir||req.headers.origin!==allowed&&req.headers.origin!==allowedLocalhost||
         req.headers['sec-fetch-site']==='cross-site'||
         req.headers['x-tt-fotos-action']!=='manual-editor-confirmation-v1'||
         !/^application\/json(?:;|$)/i.test(req.headers['content-type']||'')){
        res.writeHead(403,heads);return res.end()
      }
      let raw='';
      req.on('data',chunk=>{raw+=chunk;if(raw.length>8192)req.destroy()});
      req.on('end',()=>{
        let body;try{body=JSON.parse(raw)}catch{res.writeHead(400,heads);return res.end()}
        Promise.resolve().then(()=>pathname==='/api/associate'?
          associateManual(base,importDir,body):
          (body?.confirmation==='CONFIRMO_ENTREGA_MANUAL'&&COMMAND.test(body.commandId)?
            deliverManual(base,body.commandId):Promise.reject(Error('EDITOR_CONFIRMATION_REQUIRED'))))
         .then(result=>{res.writeHead(200,{...heads,'Content-Type':'application/json; charset=utf-8'});res.end(JSON.stringify({ok:true,result}))})
         .catch(err=>{const reason=String(err?.message||'UNEXPECTED_ERROR');res.writeHead(/CONFLICT|EXISTING|ALREADY|MISMATCH|CHANGED/.test(reason)?409:400,{...heads,'Content-Type':'application/json; charset=utf-8'});res.end(JSON.stringify({ok:false,error:/^[A-Z0-9_]{3,100}$/.test(reason)?reason:'ACTION_FAILED'}))})
      });
      return
    }
    if(req.method!=='GET'){res.writeHead(405,heads);return res.end()}
    if(pathname==='/'){res.writeHead(200,{...heads,'Content-Type':'text/html; charset=utf-8'});return res.end(html)}
    if(pathname==='/api/status'){const date=new URL(req.url,allowed).searchParams.get('since')||since;try{const doc=inventory(base,{importDir,since:date});res.writeHead(200,{...heads,'Content-Type':'application/json; charset=utf-8'});return res.end(JSON.stringify(doc))}catch{res.writeHead(400,heads);return res.end()}}
    if(pathname.startsWith('/api/orphan/')){
      const parts=pathname.slice('/api/orphan/'.length).split('/');
      if(parts.length!==2){res.writeHead(404,heads);return res.end()}
      let kind,name;
      try{kind=decodeURIComponent(parts[0]);name=decodeURIComponent(parts[1])}catch{res.writeHead(404,heads);return res.end()}
      if(!['immediate-originals','original-cache','CARPETA_DESCARGAS'].includes(kind)||
         typeof name!=='string'||name.length>245||name!==path.basename(name)||!name.toLowerCase().endsWith('.png')||name.includes('..')){
        res.writeHead(404,heads);return res.end()
      }
      const all=inventory(base,{importDir});
      if(!all.orphans.some(x=>x.source===kind&&x.file===name)){res.writeHead(404,heads);return res.end()}
      const dir=kind==='CARPETA_DESCARGAS'?importDir:path.join(dirs(base).receipts,kind);
      if(!dir){res.writeHead(404,heads);return res.end()}
      const file=path.join(dir,name);
      try{if(kind==='CARPETA_DESCARGAS'&&!fs.realpathSync(file).startsWith(validImportDir(importDir)+path.sep))throw Error('IMPORT_PATH_OUTSIDE_DIRECTORY');const size=fs.statSync(file).size;if(size<24||size>8388608)throw Error('BAD_SIZE');
        const bytes=fs.readFileSync(file);if(!goodPNG(bytes))throw Error('BAD_PNG');
        res.writeHead(200,{...heads,'Content-Type':'image/png','Content-Length':bytes.length});return res.end(bytes);
      }catch{res.writeHead(404,heads);return res.end()}
    }
    if(pathname.startsWith('/api/manual-original/')){
      const commandId=decodeURIComponent(pathname.slice('/api/manual-original/'.length));
      if(!COMMAND.test(commandId)){res.writeHead(404,heads);return res.end()}
      const entry=readManualLinks(base).find(x=>x.commandId===commandId),bytes=entry?manualOriginal(base,entry):null;
      if(!bytes){res.writeHead(404,heads);return res.end()}
      res.writeHead(200,{...heads,'Content-Type':'image/png','Content-Length':bytes.length});return res.end(bytes)
    }
    if(pathname.startsWith('/api/original/')){
      const commandId=decodeURIComponent(pathname.slice('/api/original/'.length));
      if(!COMMAND.test(commandId)){res.writeHead(404,heads);return res.end()}
      const {map,duplicates}=enrollmentFiles(base),task=map.get(commandId);
      if(!task||duplicates.has(commandId)){res.writeHead(404,heads);return res.end()}
      const file=storedOriginal(base,task);
      if(!file){res.writeHead(404,heads);return res.end()}
      res.writeHead(200,{...heads,'Content-Type':'image/png','Content-Length':file.bytes.length});return res.end(file.bytes);
    }
    res.writeHead(404,heads);res.end();
  });
  server.listen(port,'127.0.0.1',()=>console.log('TT_FOTOS_PANEL http://127.0.0.1:'+server.address().port+'/ (solo equipo local)'));
  return server;
}
async function main(){
  const args=process.argv.slice(2),baseIdx=args.indexOf('--base'),base=baseIdx>=0?path.resolve(args[baseIdx+1]):__dirname,
    importIdx=args.indexOf('--import-dir'),importDir=importIdx>=0?path.resolve(args[importIdx+1]):null,
    limitIdx=args.indexOf('--limit'),limit=Math.max(1,Math.min(100,Number(limitIdx>=0?args[limitIdx+1]:25)||25)),
    sinceIdx=args.indexOf('--since'),since=sinceIdx>=0?String(args[sinceIdx+1]):null,
    offsetIdx=args.indexOf('--offset'),offset=offsetIdx>=0?Number(args[offsetIdx+1]):null;
  if(since&&(!DATE.test(since)||!Number.isFinite(Date.parse(since))))throw Error('INVALID_SINCE_DATE');
  if(args.includes('--rescue')){
    const captured=await capture(base,{limit,since,offset});
    const delivered=await deliver(base,{limit,since});
    console.log(JSON.stringify({capture:captured,delivery:delivered,counts:inventory(base,{importDir,since}).counts},null,2));
  }else if(args.includes('--capture')){
    const result=await capture(base,{limit,since,offset});console.log(JSON.stringify({capture:result},null,2));
  }else if(args.includes('--deliver')){
    const result=await deliver(base,{limit,since});console.log(JSON.stringify({delivery:result},null,2));
  }else if(args.includes('--serve')){
    serve(base,{importDir,since});
  }else {
    const doc=inventory(base,{importDir,since});
    console.log(JSON.stringify({date:doc.generatedAt,counts:doc.counts,missing:doc.jobs.filter(x=>x.phase!=='RECIBIDA_CON_RECIBO'),orphans:doc.orphans},null,2));
  }
}
if(require.main===module)main().catch(e=>{console.error('TT_FOTOS_RECOVERY_ERROR '+safe(e.message));process.exitCode=1});
module.exports={inventory,enrollmentFiles,storedOriginal,checkedOriginal,goodPNG,deliver,capture,serve,openPages,eligibleDate,madridDate,associateManual,deliverManual,readManualLinks};