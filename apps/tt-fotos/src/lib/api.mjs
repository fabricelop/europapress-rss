import {MAX_PNG,SHA_RE,validPng,rasterSha,commandDetails,exactJob,sourceEvidence,assertMatch,safeLabel,validChatUrl} from './core.mjs';
import {createGithubJobProvider} from './job-provider.mjs';

const ROOT='/api/tt-fotos/v1';
const response=(data,status=200)=>new Response(JSON.stringify(data),{status,headers:{'content-type':'application/json; charset=utf-8','cache-control':'no-store','x-content-type-options':'nosniff'}});
const reject=(code,status=400)=>response({ok:false,error:code},status);
const now=()=>new Date().toISOString();
const imgKey=sha=>'tt-fotos/originals/'+sha+'.png';
function dateOnly(s){return /^\d{4}-\d{2}-\d{2}$/.test(s||'') && !Number.isNaN(Date.parse(s)) ? s:null}
function jobInfo(j){const c=commandDetails(j.command_id);if(!c||!exactJob(j,c))return null;return {
  commandId:c.commandId,project:c.project,editorialId:c.editorialId,revision:c.revision,
  title:safeLabel(j.target_name||j.context_snapshot?.title||j.context_snapshot?.name||''),
  requestedAt:typeof j.requested_at==='string'?j.requested_at:null,
  conversationUrl:validChatUrl(j.conversation_url||j.chat_url||''),
  verification:j.verification==='editorial_identity_only'?'editorial_identity_only':'exact_job'
}}
async function registerJob(db,job){const j=jobInfo(job);if(!j)return null;
 await db.prepare(`INSERT INTO tt_fotos_jobs(command_id,project,editorial_id,revision,title,requested_at,conversation_url,registered_at)
 VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(command_id) DO UPDATE SET
 title=CASE WHEN excluded.title<>'' THEN excluded.title ELSE tt_fotos_jobs.title END,
 requested_at=COALESCE(excluded.requested_at,tt_fotos_jobs.requested_at),
 conversation_url=COALESCE(excluded.conversation_url,tt_fotos_jobs.conversation_url)`).bind(j.commandId,j.project,j.editorialId,j.revision,j.title,j.requestedAt,j.conversationUrl,now()).run();
 return j;
}
async function matchAsset(db,identity,sha,confidence){
 const date=now();
 const former=await db.prepare('SELECT asset_sha,confidence FROM tt_fotos_matches WHERE project=? AND editorial_id=? AND revision=? AND command_id=?')
 .bind(identity.project,identity.editorialId,identity.revision,identity.commandId).first();
 // A repeated import of the same image must not rewrite its association or
 // create a spurious historical action. Preserve the existing confidence.
 if(former?.asset_sha===sha){
   return {operation:'unchanged',project:identity.project,editorialId:identity.editorialId,
     revision:identity.revision,commandId:identity.commandId,assetSha:sha,
     confidence:former.confidence,alreadyAssociated:true};
 }
 const operation=former?'replace':'associate';
 // Batch is atomic in D1. A history row must not exist without corresponding match.
 await db.batch([
  db.prepare(`INSERT INTO tt_fotos_matches(project,editorial_id,revision,command_id,asset_sha,confidence,updated_at)
 VALUES(?,?,?,?,?,?,?) ON CONFLICT(project,editorial_id,revision,command_id) DO UPDATE SET
 asset_sha=excluded.asset_sha, confidence=excluded.confidence, updated_at=excluded.updated_at`)
  .bind(identity.project,identity.editorialId,identity.revision,identity.commandId,sha,confidence,date),
  db.prepare(`INSERT INTO tt_fotos_match_history(project,editorial_id,revision,command_id,asset_sha,confidence,changed_at,action)
 VALUES(?,?,?,?,?,?,?,?)`).bind(identity.project,identity.editorialId,identity.revision,identity.commandId,sha,confidence,date,operation)
 ]);
 return {operation,project:identity.project,editorialId:identity.editorialId,revision:identity.revision,commandId:identity.commandId,assetSha:sha,confidence};
}
function validAssetId(s){return SHA_RE.test(s||'')}
function ownOrigin(request){const u=new URL(request.url), origin=request.headers.get('origin');
 return origin===u.origin && request.headers.get('x-tt-fotos-action')==='editor-v1' && request.headers.get('sec-fetch-site')!=='cross-site';
}
export function createTTFotosApi({db,r2,authenticate,jobProvider=createGithubJobProvider()}={}){
 if(!db||!r2||typeof authenticate!=='function'||typeof jobProvider?.find!=='function')throw Error('SITE_BINDINGS_AND_AUTH_REQUIRED');
 return async function handler(request){
  const url=new URL(request.url),p=url.pathname;
  if(!p.startsWith(ROOT+'/'))return null;
  let editor;try{editor=await authenticate(request)}catch{return reject('EDITOR_AUTH_UNAVAILABLE',503)}
  if(!editor?.isEditor)return reject('EDITOR_SIGNIN_REQUIRED',403);
  const isGet=request.method==='GET';if(!isGet&&!ownOrigin(request))return reject('SAME_ORIGIN_EDITOR_ACTION_REQUIRED',403);
  try{
   if(isGet && p===ROOT+'/status'){
     const counts=await Promise.all([
       db.prepare('SELECT COUNT(*) n FROM tt_fotos_assets').first(),
       db.prepare('SELECT COUNT(*) n FROM tt_fotos_matches').first(),
       db.prepare('SELECT COUNT(*) n FROM tt_fotos_jobs').first(),
       db.prepare('SELECT COUNT(*) n FROM tt_fotos_assets a WHERE NOT EXISTS(SELECT 1 FROM tt_fotos_matches m WHERE m.asset_sha=a.sha)').first(),
     ]);
     return response({ok:true,counts:{assets:counts[0]?.n||0,associated:counts[1]?.n||0,jobsRegistered:counts[2]?.n||0,withoutMatch:counts[3]?.n||0},source:'tt_fotos_private_r2_d1_not_iphone'});
   }
   if(isGet && p===ROOT+'/assets'){
     const state=url.searchParams.get('state')||'all';if(!['all','unmatched'].includes(state))return reject('BAD_FILTER');
     const where=state==='unmatched'?'WHERE NOT EXISTS(SELECT 1 FROM tt_fotos_matches m WHERE m.asset_sha=a.sha)':'';
     const rows=await db.prepare(`SELECT a.sha,a.size_bytes,a.created_at,a.source_kind,a.conversation_url,a.evidence_command,a.evidence_reason,a.title, (SELECT COUNT(*) FROM tt_fotos_matches m WHERE m.asset_sha=a.sha) matches FROM tt_fotos_assets a ${where} ORDER BY a.created_at DESC LIMIT 500`).all();
     return response({ok:true,items:rows.results||[]});
   }
   if(isGet && p===ROOT+'/jobs'){
     const since=dateOnly(url.searchParams.get('since'));
     if(url.searchParams.has('since')&&!since)return reject('BAD_DATE');
     const limit=Math.min(500,Math.max(1,Number(url.searchParams.get('limit'))||200));
     const query=`SELECT j.command_id,j.project,j.editorial_id,j.revision,j.title,j.requested_at,j.conversation_url,m.asset_sha,m.confidence,m.updated_at
       FROM tt_fotos_jobs j LEFT JOIN tt_fotos_matches m ON m.command_id=j.command_id
       ${since?'WHERE COALESCE(j.requested_at,j.registered_at) >= ?':''} ORDER BY COALESCE(j.requested_at,j.registered_at) DESC LIMIT ?`;
     const q=db.prepare(query);const result=await (since?q.bind(since,limit):q.bind(limit)).all();
     return response({ok:true,items:result.results||[],coverage:'registered_jobs_only_not_all_historical_images'});
   }
   if(isGet && p.startsWith(ROOT+'/assets/') && p.endsWith('/original')){
     const sha=p.slice((ROOT+'/assets/').length,-'/original'.length);
     if(!validAssetId(sha))return reject('BAD_ASSET',404);
     const exists=await db.prepare('SELECT sha FROM tt_fotos_assets WHERE sha=?').bind(sha).first();if(!exists)return reject('ASSET_NOT_FOUND',404);
     const obj=await r2.get(imgKey(sha));if(!obj)return reject('ORIGINAL_MISSING_R2',404);
     const headers=new Headers({'content-type':'image/png','cache-control':'private, no-store','x-content-type-options':'nosniff','content-security-policy':"default-src 'none'"});
     return new Response(obj.body,{headers});
   }
   if(isGet && p.startsWith(ROOT+'/jobs/')){
     const cmd=decodeURIComponent(p.slice((ROOT+'/jobs/').length)),job=await jobProvider.find(cmd);
     if(!job)return reject('EXACT_JOB_UNAVAILABLE',404);
     const info=jobInfo(job);return response({ok:true,job:info});
   }
   if(request.method==='POST'&&p===ROOT+'/assets'){
     const form=await request.formData();const upload=form.get('image');const source=form.get('source');
     if(!upload||typeof upload.arrayBuffer!=='function')return reject('PNG_REQUIRED');
     if(upload.size>MAX_PNG||upload.size<24)return reject('PNG_SIZE_INVALID');
     const bytes=new Uint8Array(await upload.arrayBuffer());if(!validPng(bytes))return reject('ORIGINAL_PNG_REQUIRED');
     let evidence;try{evidence=source?JSON.parse(source):{}}catch{return reject('SOURCE_JSON_INVALID')}
     const sha=await rasterSha(bytes);if(form.get('expectedSHA256')&&String(form.get('expectedSHA256')).toLowerCase()!==sha)return reject('RASTER_SHA_MISMATCH');
     const maybe=commandDetails(evidence.commandId),job=maybe?await jobProvider.find(maybe.commandId):null;
     const sourceProof=maybe&&job?sourceEvidence(evidence,maybe,job):{automatic:false,reason:maybe?'EXACT_JOB_UNAVAILABLE':'COMMAND_UNAVAILABLE'};
     const exactReceipt=Boolean(job&&job.verification!=='editorial_identity_only');
     // Current editorial records verify only ID+revision, not that a specific
     // generated-image command existed. Never silently downgrade auto_exact.
     const existing=await db.prepare('SELECT sha FROM tt_fotos_assets WHERE sha=?').bind(sha).first();
     if(!existing){
       await r2.put(imgKey(sha),bytes,{httpMetadata:{contentType:'image/png'},customMetadata:{kind:'tt-fotos-private',sha}});
       await db.prepare(`INSERT INTO tt_fotos_assets(sha,size_bytes,created_at,source_kind,conversation_url,evidence_command,evidence_reason,title)
 VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(sha) DO NOTHING`).bind(sha,bytes.length,now(),safeLabel(evidence.kind||'unknown',50),validChatUrl(evidence.conversationUrl),maybe?.commandId||null,sourceProof.reason,safeLabel(evidence.title)).run();
     }
     let association=null;
     if(sourceProof.automatic&&exactReceipt){await registerJob(db,job);association=await matchAsset(db,maybe,sha,'auto_exact')}
     return response({ok:true,assetSha:sha,stored:true,association,needsReview:!association,
       reason:association?'AUTO_EXACT_TURN':sourceProof.automatic&&!exactReceipt?'EDITORIAL_ID_CORROBORATED_EXACT_JOB_MISSING':sourceProof.reason,existing:Boolean(existing)});
   }
   if(request.method==='POST'&&p===ROOT+'/matches'){
     const body=await request.json().catch(()=>null);if(!body||body.confirmation!=='CONFIRMAR_ASOCIACION_EDITOR')return reject('EDITOR_CONFIRMATION_REQUIRED');
     if(!validAssetId(body.assetSha))return reject('BAD_ASSET');
     const asset=await db.prepare('SELECT sha FROM tt_fotos_assets WHERE sha=?').bind(body.assetSha).first();
     if(!asset)return reject('ASSET_NOT_FOUND',404);
     const job=await jobProvider.find(body.commandId);try{assertMatch(body,job)}catch{return reject('EXACT_JOB_NOT_VERIFIED',409)}
     await registerJob(db,job);
     return response({ok:true,verification:job.verification==='editorial_identity_only'?'editorial_identity_only':'exact_job',association:await matchAsset(db,commandDetails(body.commandId),body.assetSha,'editor_confirmed')});
   }
   return reject('NOT_FOUND',404);
  }catch(e){
   // Do not log image bytes, bearer tokens, OAuth cookies, URLs with signatures.
   return reject('TT_FOTOS_BACKEND_ERROR',503);
  }
 };
}