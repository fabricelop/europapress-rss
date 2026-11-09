'use strict';
// Immediate, command-scoped capture in the SAME ImageGen bridge process.
// Private inbox only: no automatic association, approval, publishing or
// regeneration. The scheduled receiver remains a read-only recovery fallback.
const fs=require('node:fs');
const path=require('node:path');
const crypto=require('node:crypto');
const digest=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
const validID=value=>/^[A-Za-z0-9_.-]{3,160}$/.test(String(value||''));

function makeTask(project,job,commandId,targetId){
 if(!['ttendencias','ttittulares'].includes(project)||
    !validID(commandId)||!validID(targetId)||
    String(job?.command_id||'')!==commandId||
    String(job?.target_id||job?.trend_id||job?.event_id||'')!==targetId||
    !Number.isInteger(Number(job.revision||0))||Number(job.revision||0)<0)
   throw Error('IMMEDIATE_IMAGE_JOB_MISMATCH');
 const snapshot=job.context_snapshot||{};
 const news=project==='ttittulares';
 const text=String(news?snapshot.tweet_text:snapshot.explanation||'').trim();
 const facts=String(snapshot.factual_summary||'').trim();
 const closer=String(snapshot.remate||'').trim();
 if(!text||(news&&!facts))throw Error('IMMEDIATE_IMAGE_EDITORIAL_MISSING');
 return {project,target_id:targetId,command_id:commandId,revision:Number(job.revision||0),
   ...(news?{editorial_sha256:digest([text,facts,closer].join('\n'))}:
      {explanation_sha256:digest(text)})};
}
function receiptPath(base,commandId){
 return path.join(base,'image-approval-receipts',commandId+'.json');
}
function readReceipt(base,task){
 try{
  const r=JSON.parse(fs.readFileSync(receiptPath(base,task.command_id),'utf8'));
  return r.commandId===task.command_id&&r.editorialId===task.target_id&&
    Number(r.revision)===task.revision&&/^[a-f0-9]{64}$/.test(String(r.rasterSHA256||''))&&
    /^[a-f0-9]{64}$/.test(String(r.id||''))?r:null;
 }catch{return null}
}
function saveReceipt(base,task,meta,receipt){
 const dir=path.join(base,'image-approval-receipts');
 fs.mkdirSync(dir,{recursive:true,mode:0o700});
 const file=receiptPath(base,task.command_id);
 if(readReceipt(base,task))return; // The scheduled receiver won the same idempotent race.
 const tmp=file+'.'+process.pid+'.'+crypto.randomBytes(6).toString('hex')+'.tmp';
 const record={project:task.project,commandId:task.command_id,editorialId:task.target_id,
  revision:task.revision,...receipt,receivedAt:new Date().toISOString()};
 try{
  fs.writeFileSync(tmp,JSON.stringify(record,null,2),{mode:0o600,flag:'wx'});
  // The same command's server ingest is idempotent; never overwrite its
  // immutable receipt with a less complete response.
  if(!readReceipt(base,task))fs.renameSync(tmp,file);
 }finally{try{fs.unlinkSync(tmp)}catch{}}
}
async function raster(cdp,expression){
 if(typeof cdp?.call==='function'){
  const response=await cdp.call('Runtime.evaluate',
   {expression,awaitPromise:true,returnByValue:true,userGesture:false},20000);
  if(response?.exceptionDetails)throw Error('IMMEDIATE_RASTER_EVALUATION_FAILED');
  return response?.result?.value;
 }
 if(typeof cdp?.eval==='function')return cdp.eval(expression,true);
 return {ready:false,reason:'cdp_unavailable'};
}
function parsePNG(result){
 if(!result?.ready)return null;
 const data=String(result.dataUrl||'');
 if(!data.startsWith('data:image/png;base64,'))throw Error('IMMEDIATE_PNG_REQUIRED');
 const encoded=data.slice('data:image/png;base64,'.length);
 if(!/^[A-Za-z0-9+/]+={0,2}$/.test(encoded))throw Error('IMMEDIATE_INVALID_BASE64');
 const bytes=Buffer.from(encoded,'base64');
 if(bytes.length<24||bytes.length>8388608||
    bytes.subarray(0,8).toString('hex')!=='89504e470d0a1a0a')
   throw Error('IMMEDIATE_PNG_REQUIRED');
 return bytes;
}

async function deliver({project,job,commandId,targetId,secret,cdp,
                        baseDir=__dirname,dependencies={}}){
 if(typeof secret!=='string'||secret.length<32)throw Error('IMMEDIATE_SECRET_MISSING');
 const task=makeTask(project,job,commandId,targetId);
 if(readReceipt(baseDir,task))return {state:'received',reason:'existing_local_receipt'};
 const receiver=dependencies.receiver||require('./TTImageApprovalReceiver.cjs');
 const source=dependencies.source||require(project==='ttendencias'?
   './TTendenciasWebImages.cjs':'./TTiTTularesWebImages.cjs');
 // Use exactly the editorial snapshot of this ImageGen command. News may
 // recover its original prepared_at from the same exact prepared/processing row.
 const initial=await receiver.editorialJob(source,task);
 const meta=receiver.metadata(task,initial);
 let bytes=receiver.cachedOriginal(baseDir,task,meta);
 if(!bytes){
  const result=await raster(cdp,source.rasterProbe(commandId,true));
  if(!result?.ready)return {state:'waiting',reason:String(result?.reason||'raster_not_ready')};
  bytes=parsePNG(result);
  // Preserve original locally before any remote call or browser reuse.
  receiver.persistOriginal(baseDir,task,meta,bytes);
 }
 // Compare the live command + revision + exact content to the frozen episode.
 // Never send an image from a later user turn or a new editorial revision.
 const latest=await source.readImageJob(task);
 const verified=await receiver.editorialJob(source,task);
 if(String(latest?.command_id)!==commandId||
    String(latest?.target_id||latest?.trend_id||latest?.event_id||'')!==targetId||
    Number(latest?.revision||0)!==task.revision||
    receiver.metadata(task,verified).episodeFingerprint!==meta.episodeFingerprint)
   throw Error('IMMEDIATE_IMAGE_EPISODE_CHANGED');
 if(readReceipt(baseDir,task))return {state:'received',reason:'existing_local_receipt'};
 const receipt=await receiver.send(meta,bytes,secret);
 if(receipt.rasterSHA256!==digest(bytes))throw Error('IMMEDIATE_IMAGE_RECEIPT_HASH_MISMATCH');
 saveReceipt(baseDir,task,meta,receipt);
 if(!readReceipt(baseDir,task))throw Error('IMMEDIATE_IMAGE_RECEIPT_NOT_DURABLE');
 receiver.discardOriginal(baseDir,task);
 return {state:'received',reason:'private_inbox_'+receipt.state,id:receipt.id};
}
module.exports={deliver,makeTask,readReceipt,parsePNG,saveReceipt};
