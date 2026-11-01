'use strict';
// Optional GitHub transport for already-generated TTiTTulares originals.
// No ImageGen, no Telegram, no Cloudflare dependency, no stored credentials.
// A GitHub Actions consumer validates the outbox before associating a READY item.
const crypto=require('node:crypto');
const {execFileSync}=require('node:child_process');
const REPO='fabricelop/europapress-rss';
const PREFIX='ttittulares/image-outbox/';
const safeId=v=>/^[A-Za-z0-9._-]{3,160}$/.test(String(v||''));

function githubToken(){
  for(const name of ['TT_IMAGES_GITHUB_TOKEN','GH_TOKEN','GITHUB_TOKEN']){
    const value=String(process.env[name]||'').trim();
    if(value)return value;
  }
  try{
    return execFileSync('gh',['auth','token','-h','github.com'],{
      encoding:'utf8',windowsHide:true,timeout:6000,stdio:['ignore','pipe','ignore'],
      maxBuffer:4096}).trim();
  }catch{return '';}
}
async function githubRequest(method,endpoint,body,token){
  if(!token)throw Error('github_auth_missing');
  if(!/^\/(?:repos\/fabricelop\/europapress-rss\/git\/)/.test(endpoint))
    throw Error('github_endpoint_not_allowed');
  const response=await fetch('https://api.github.com'+endpoint,{
    method,headers:{'Authorization':'Bearer '+token,'Accept':'application/vnd.github+json',
      'X-GitHub-Api-Version':'2022-11-28','User-Agent':'ttittulares-original-receiver',
      ...(body===undefined?{}:{'Content-Type':'application/json'})},
    ...(body===undefined?{}:{body:JSON.stringify(body)}),
    signal:AbortSignal.timeout(30000)});
  if(!response.ok){
    const error=Error('github_api_HTTP_'+response.status);
    error.status=response.status;
    throw error;
  }
  return response.json();
}
function buildReceipt(task,row,raster){
  if(!safeId(task.command_id)||!safeId(task.target_id)||
    String(row.event_id||'')!==String(task.target_id)||
    Number(row.revision||0)!==Number(task.revision)||
    !/^[a-f0-9]{64}$/.test(String(task.editorial_sha256||'')))
    throw Error('github_outbox_context_mismatch');
  const attempt=Number(row.ai_image_attempt||1);
  if(!Number.isInteger(attempt)||attempt<1||attempt>100)throw Error('github_outbox_attempt_invalid');
  const match=/^data:(image\/(?:png|jpeg|webp));base64,([A-Za-z0-9+/=]+)$/.exec(String(raster.dataUrl||''));
  if(!match)throw Error('github_outbox_data_url_invalid');
  const raw=Buffer.from(match[2],'base64');
  if(raw.length<12000||raw.length>8388608||!Number.isInteger(raster.width)||
    !Number.isInteger(raster.height)||raster.width<1024||raster.height<576)
    throw Error('github_outbox_image_invalid');
  const hash=crypto.createHash('sha256').update(raw).digest('hex');
  if(raster.sha256&&raster.sha256!==hash)throw Error('github_outbox_sha256_mismatch');
  const name=task.command_id+'.b64';
  const receipt={
    status:'ready',event_id:task.target_id,revision:task.revision,attempt,
    command_id:task.command_id,editorial_sha256:task.editorial_sha256,
    ai_image:{chunk_files:[name],chunk_mime:match[1],chunk_sha256:hash,
      source:'TTiTTulares / ChatGPT ImageGen',rights_status:'generated',
      generated:true,provider:'chat-imagegen',origin:'executing_chat',
      context_guard:{version:3,event_id:task.target_id,revision:task.revision,
        scope:'current_item_only',command_id:task.command_id,
        editorial_sha256:task.editorial_sha256}}
  };
  return {receipt,originalBase64:match[2],sha256:hash,
    imagePath:PREFIX+name,receiptPath:PREFIX+task.command_id+'.json'};
}
// The caller has already compared the command, revision, editorial fingerprint
// and READY row with main. Server-side outbox processing checks again.
async function pushReceipt(task,row,raster,options={}){
  const token=options.token===undefined?githubToken():options.token;
  if(!token)return {status:'unavailable',reason:'github_auth_missing'};
  const request=options.request||githubRequest;
  const data=buildReceipt(task,row,raster);
  const root='/repos/'+REPO+'/git/';
  // Immutable content-addressed Git blobs: retries never invent a new raster.
  const original=await request('POST',root+'blobs',
    {content:data.originalBase64,encoding:'utf-8'},token);
  const metadata=await request('POST',root+'blobs',
    {content:JSON.stringify(data.receipt)+'\n',encoding:'utf-8'},token);
  if(!/^[a-f0-9]{40}$/.test(String(original.sha||''))||
     !/^[a-f0-9]{40}$/.test(String(metadata.sha||'')))
    throw Error('github_blob_response_invalid');
  for(let attempt=1;attempt<=4;attempt++){
    const head=await request('GET',root+'ref/heads/main',undefined,token);
    const parent=String(head?.object?.sha||'');
    if(!/^[a-f0-9]{40}$/.test(parent))throw Error('github_main_ref_invalid');
    const commit=await request('GET',root+'commits/'+parent,undefined,token);
    const baseTree=String(commit?.tree?.sha||'');
    if(!/^[a-f0-9]{40}$/.test(baseTree))throw Error('github_base_tree_invalid');
    const tree=await request('POST',root+'trees',{base_tree:baseTree,tree:[
      {path:data.imagePath,mode:'100644',type:'blob',sha:original.sha},
      {path:data.receiptPath,mode:'100644',type:'blob',sha:metadata.sha}
    ]},token);
    const next=await request('POST',root+'commits',{
      message:'Recibir original IA de noticia '+task.target_id+' r'+task.revision,
      tree:tree.sha,parents:[parent]},token);
    try{
      await request('PATCH',root+'refs/heads/main',{sha:next.sha,force:false},token);
      return {status:'committed',sha256:data.sha256,
        github_outbox_committed_at:new Date().toISOString()};
    }catch(error){
      if(attempt===4||![409,422].includes(Number(error.status)))throw error;
    }
  }
  throw Error('github_outbox_push_retry_exhausted');
}
module.exports={githubToken,buildReceipt,pushReceipt};
