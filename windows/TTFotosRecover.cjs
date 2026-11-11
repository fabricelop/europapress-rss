'use strict';
// TT Fotos: reconcile locally saved exact PNG originals with the existing
// private TTActualidad inbox. Does not generate, browse ChatGPT Images,
// approve, publish, alter other queues or send any chat prompt.
// --audit: read-only. --apply-cached: send ONLY durable, exact originals.
// Designed for Windows Node >= 22 in C:\TTiTTulares.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {execFileSync}=require('node:child_process');
const HASH=/^[a-f0-9]{64}$/i;
const CMD=/^[A-Za-z0-9_.-]{3,160}$/;
const FILES=[['ttendencias','ttendencias-web-images','TTendenciasWebImages.cjs'],
             ['ttittulares','ttittulares-web-images','TTiTTularesWebImages.cjs']];
function sha(b){return crypto.createHash('sha256').update(b).digest('hex')}
function readJSON(p){try{return JSON.parse(fs.readFileSync(p,'utf8'))}catch{return null}}
function safeString(v){return String(v==null?'':v).slice(0,160)}
function exactReceipt(r,task){
  return r&&r.commandId===task.command_id&&r.project===task.project&&
    r.editorialId===task.target_id&&Number(r.revision)===Number(task.revision)&&
    HASH.test(String(r.rasterSHA256||''))&&HASH.test(String(r.id||''));
}
function paths(base,command){
  const root=path.join(base,'image-approval-receipts');
  return {root,receipt:path.join(root,command+'.json'),
    cached:path.join(root,'original-cache',command+'.png'),
    cachedMeta:path.join(root,'original-cache',command+'.json'),
    staged:path.join(root,'immediate-originals',command+'.png'),
    stagedMeta:path.join(root,'immediate-originals',command+'.json')};
}
function scan(base){
  const items=[],indexed=new Set(),duplicates=new Set();
  for(const [project,folder] of FILES){
    const dir=path.join(base,folder);
    if(!fs.existsSync(dir))continue;
    for(const name of fs.readdirSync(dir).filter(n=>n.endsWith('.json'))){
      const task=readJSON(path.join(dir,name));
      if(!task||!CMD.test(task.command_id)||!CMD.test(task.target_id)||
         !Number.isInteger(Number(task.revision))||Number(task.revision)<0)continue;
      const command=task.command_id;
      if(indexed.has(command)){duplicates.add(command);continue}
      indexed.add(command);
      const loc=paths(base,command);
      const receipt=readJSON(loc.receipt),received=exactReceipt(receipt,{...task,project});
      const cached=fs.existsSync(loc.cached)&&fs.existsSync(loc.cachedMeta);
      const staged=fs.existsSync(loc.staged)&&fs.existsSync(loc.stagedMeta);
      const malformed=Boolean(receipt)&&!received;
      const state=duplicates.has(command)?'DUPLICATE_COMMAND':
        malformed?'RECEIPT_IDENTITY_CONFLICT':
        received?'RECEIVED_CONFIRMED_LOCAL':
        cached||staged?'ORIGINAL_CACHED_NEEDS_DELIVERY':
        'ORIGINAL_NOT_PRESERVED_LOCALLY';
      items.push({project,commandId:command,editorialId:task.target_id,revision:Number(task.revision),
        date:safeString(task.created_at||task.requested_at),
        state,cached,staged,hasSecret:Boolean(task.secret_dpapi),
        jobStatus:safeString(task.status),
        _task:{...task,project}});
    }
  }
  for(const item of items)if(duplicates.has(item.commandId))item.state='DUPLICATE_COMMAND';
  const orphans=[];
  const root=path.join(base,'image-approval-receipts');
  for(const folder of ['original-cache','immediate-originals']){
    const dir=path.join(root,folder);
    if(!fs.existsSync(dir))continue;
    for(const name of fs.readdirSync(dir).filter(n=>n.endsWith('.png'))){
      const command=name.slice(0,-4);
      if(!indexed.has(command))orphans.push({commandId:safeString(command),folder,
        state:'ORPHAN_WITHOUT_ENROLLMENT'});
    }
  }
  const count=(label)=>items.filter(x=>x.state===label).length;
  return {items,orphans,summary:{enrolled:items.length,
    received:count('RECEIVED_CONFIRMED_LOCAL'),
    cachedPending:count('ORIGINAL_CACHED_NEEDS_DELIVERY'),
    noLocalOriginal:count('ORIGINAL_NOT_PRESERVED_LOCALLY'),
    conflict:count('RECEIPT_IDENTITY_CONFLICT')+count('DUPLICATE_COMMAND'),
    orphanPNG:orphans.length}};
}
function unprotectDPAPI(encrypted){
  // Mirrors the existing private inbox receiver. Never logs secret.
  const code='$s=ConvertTo-SecureString ([Console]::In.ReadToEnd());$p=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($s);try{[Console]::Write([Runtime.InteropServices.Marshal]::PtrToStringBSTR($p))}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p)}';
  const token=execFileSync('powershell.exe',['-NoProfile','-NonInteractive','-Command',code],
    {input:encrypted,encoding:'utf8',windowsHide:true,timeout:15000,maxBuffer:65536}).trim();
  if(token.length<32)throw Error('DPAPI_TOKEN_UNAVAILABLE');
  return token;
}
function inspectOriginal(base,item,task,meta,receiver,immediate){
  let original=null;
  if(item.cached)original=receiver.cachedOriginal(base,task,meta);
  if(item.staged){
    const staged=immediate.loadStaged(base,task);
    if(!staged)throw Error('STAGED_FILE_NOT_VERIFIED');
    if(original&&sha(original)!==sha(staged))throw Error('TWO_ORIGINALS_CONFLICT');
    original=original||staged;
  }
  if(!original)throw Error('ORIGINAL_NOT_FOUND');
  if(original.length<24||original.length>8388608||
    original.subarray(0,8).toString('hex')!=='89504e470d0a1a0a')
    throw Error('ORIGINAL_PNG_REQUIRED');
  return original;
}
async function recoverOne(base,item,{source,receiver,immediate,unprotect=unprotectDPAPI,send=null}){
  const task=item._task,loc=paths(base,item.commandId);
  if(readJSON(loc.receipt))throw Error('RECEIPT_ALREADY_EXISTS_OR_CONFLICT');
  if(!item.cached&&!item.staged)throw Error('ORIGINAL_NOT_PRESERVED');
  if(!task.secret_dpapi)throw Error('ENROLLMENT_SECRET_UNAVAILABLE');
  // Every uploader must verify a fresh immutable job and the complete frozen
  // episode: project, command, editorial ID, revision, exact content and date.
  const job=await receiver.editorialJob(source,task);
  const meta=receiver.metadata(task,job);
  if(meta.project!==item.project||meta.commandId!==item.commandId||
     meta.editorialId!==item.editorialId||meta.revision!==item.revision||
     !HASH.test(meta.episodeFingerprint))throw Error('EPISODE_MISMATCH');
  const bytes=inspectOriginal(base,item,task,meta,receiver,immediate);
  // Re-read the authoritative job immediately before sending to detect
  // changed revision, identity or command even if the first lookup succeeded.
  const latest=await receiver.editorialJob(source,task);
  const checked=receiver.metadata(task,latest);
  if(checked.episodeFingerprint!==meta.episodeFingerprint||
     checked.commandId!==meta.commandId||
     checked.revision!==meta.revision)throw Error('EPISODE_CHANGED');
  // The actual server uses the same immutable candidate store as the iPhone.
  const token=unprotect(task.secret_dpapi);
  const reply=await (send||receiver.send)(meta,bytes,token);
  if(!reply||!HASH.test(reply.id)||!HASH.test(reply.rasterSHA256)||
     reply.rasterSHA256!==sha(bytes)||reply.state==='rejected')
    throw Error('PRIVATE_RECEIPT_NOT_PROVEN');
  if(fs.existsSync(loc.receipt))throw Error('CONCURRENT_RECEIPT_CREATED_VERIFY_MANUALLY');
  fs.mkdirSync(loc.root,{recursive:true});
  const record={project:item.project,commandId:item.commandId,editorialId:item.editorialId,
    revision:item.revision,id:reply.id,state:reply.state,rasterSHA256:reply.rasterSHA256,
    receivedAt:new Date().toISOString(),recovery:'tt-fotos-exact-original-v1'};
  const tmp=loc.receipt+'.recovery-'+process.pid+'.tmp';
  try{
    fs.writeFileSync(tmp,JSON.stringify(record,null,2),{flag:'wx',mode:0o600});
    if(fs.existsSync(loc.receipt))throw Error('CONCURRENT_RECEIPT_CREATED_VERIFY_MANUALLY');
    fs.renameSync(tmp,loc.receipt);
  }finally{try{fs.unlinkSync(tmp)}catch{}}
  if(!exactReceipt(readJSON(loc.receipt),task))throw Error('RECEIPT_NOT_DURABLE');
  // Original cache is intentionally NEVER deleted by this tool.
  return {commandId:item.commandId,project:item.project,state:'DELIVERED_CONFIRMED_LOCAL',receiptState:reply.state};
}
async function applyCached(base,{dependencyLoader=null,unprotect,send}={}){
  const scanResult=scan(base),results=[];
  if(scanResult.summary.conflict)throw Error('GLOBAL_IDENTITY_CONFLICT: audit and resolve before apply');
  const receiver=(dependencyLoader?dependencyLoader('TTImageApprovalReceiver.cjs'):
    require(path.join(base,'TTImageApprovalReceiver.cjs')));
  const immediate=(dependencyLoader?dependencyLoader('TTImagesImmediateInbox.cjs'):
    require(path.join(base,'TTImagesImmediateInbox.cjs')));
  const sources={};
  for(const [project,,file] of FILES){
    sources[project]=dependencyLoader?dependencyLoader(file):require(path.join(base,file));
  }
  for(const item of scanResult.items.filter(x=>x.state==='ORIGINAL_CACHED_NEEDS_DELIVERY')){
    try{
      results.push(await recoverOne(base,item,{source:sources[item.project],receiver,immediate,
        ...(unprotect?{unprotect}:{}),...(send?{send}:{})}));
    }catch(e){results.push({commandId:item.commandId,project:item.project,
      state:'NOT_DELIVERED',reason:safeString(e.message).replace(/https?:\/\/\S+/g,'[url]')})}
  }
  return {before:scanResult.summary,after:scan(base).summary,results,
    unresolvedOriginals:scan(base).orphans};
}
function publicReport(data){
  return {generatedAt:new Date().toISOString(),mode:'audit_read_only',
    scope:'enrollments_and_local_originals_only',summary:data.summary,
    items:data.items.map(({_task,...x})=>x),orphans:data.orphans,
    cautions:[
      'LAUNCHED is not proof of an image.',
      'Local receipt proves delivery then, not current pending state in private inbox.',
      'Images in ChatGPT Images without enrollment are NOT enumerated.',
      'An unmatched PNG is NEVER automatically associated with a news item.',
      'The official iPhone approval inbox is unchanged.'
    ]};
}
async function main(argv=process.argv.slice(2)){
  const operation=argv.includes('--apply-cached')?'apply-cached':'audit';
  const where=argv.indexOf('--base'),base=where>=0?String(argv[where+1]||''):'C:\\TTiTTulares';
  if(!fs.existsSync(base))throw Error('BASE_DIRECTORY_MISSING');
  if(operation==='audit'){process.stdout.write(JSON.stringify(publicReport(scan(base)),null,2)+'\n');return}
  if(process.platform!=='win32')throw Error('WINDOWS_REQUIRED_FOR_APPLY');
  const answer=await applyCached(base);
  process.stdout.write(JSON.stringify({mode:operation,...answer},null,2)+'\n');
}
module.exports={scan,publicReport,inspectOriginal,exactReceipt,recoverOne,applyCached};
if(require.main===module)main().catch(e=>{console.error('TT_FOTOS_RECOVERY_ERROR '+safeString(e.message));process.exitCode=1});
