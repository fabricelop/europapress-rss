// Manual image-only retry for an already explained V2 trend.
// Keep the editorial revision and captured explanation untouched.
import {readImageIncident} from "./image-incidents.js";

const ID=/^trv2-[a-f0-9]{24}$/;
const UNSAFE=/(AUTH|LOGIN|CREDENTIAL|DISK|CLEANUP|CAPTCHA|LEASE_EXPIRED)/;
const RETRY_WINDOW_MS=3*60*60*1000;
const MAX_LIVE_RECONCILIATIONS=10;
let recentReconciliation=null;

async function table(db){
 await db.prepare("CREATE TABLE IF NOT EXISTS trend_image_retry_requests (trend_id TEXT NOT NULL,revision INTEGER NOT NULL,incident_at TEXT NOT NULL,editorial_sha256 TEXT NOT NULL,request_id TEXT NOT NULL,requested_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),PRIMARY KEY(trend_id,revision,incident_at))").run();
}

export async function listTrendImageRetries(env){
 if(!env.MARKS_DB)throw Error("IMAGE_RETRY_STORAGE_UNAVAILABLE");
 await table(env.MARKS_DB);
 const data=await env.MARKS_DB.prepare("SELECT trend_id,revision,incident_at,editorial_sha256,request_id,requested_at FROM trend_image_retry_requests ORDER BY requested_at DESC LIMIT 200").all();
 return (data.results||[]).filter(row=>ID.test(row.trend_id)&&Number.isSafeInteger(row.revision)&&row.revision>0&&
  typeof row.incident_at==="string"&&Number.isFinite(Date.parse(row.incident_at))&&
  typeof row.requested_at==="string"&&Number.isFinite(Date.parse(row.requested_at))&&
  /^[a-f0-9]{64}$/.test(row.editorial_sha256)&&/^[a-f0-9]{32}$/.test(row.request_id));
}

// The image ledger may record a newer automatic failure after the owner asks
// for REI-IA. Keep the same one-shot request ID; move only its effective
// incident timestamp forward after verifying the SAME text and safe failure.
// The Windows worker still rechecks everything before opening a chat.
async function effectiveImageRetries(rows,readIncident,now){
 const output=[],seen=new Set();
 let ledgerDownload=null;
 const oncePerPoll=async(url,options)=>{
  if(!ledgerDownload)ledgerDownload=fetch(url,options).then(async response=>({
   status:response.status,ok:response.ok,body:await response.text()}));
  const result=await ledgerDownload;
  return {status:result.status,ok:result.ok,text:async()=>result.body};
 };
 for(const row of rows){
  const key=row.trend_id+":"+row.revision;
  if(seen.has(key))continue;
  seen.add(key); // Only the newest owner request per immutable revision.
  const age=now-Date.parse(row.requested_at);
  if(age<0||age>RETRY_WINDOW_MS||output.length>=MAX_LIVE_RECONCILIATIONS)continue;
  let effective=row;
  try{
   const detail=await readIncident({project:"ttendencias-v2",id:row.trend_id,revision:row.revision,
    includeIdentity:true,fetcher:oncePerPoll});
   if(detail.editorial_sha256!==row.editorial_sha256||!detail.available||
      !detail.incident||detail.incident.retry_mode==="none"||UNSAFE.test(detail.incident.code))continue;
   const currentAt=Date.parse(detail.incident.at);
   if(!Number.isFinite(currentAt)||currentAt<Date.parse(row.incident_at))continue;
   effective={...row,incident_at:detail.incident.at};
  }catch{
   // A transient GitHub read error does not stall unrelated image workers.
   // An obsolete timestamp is independently rejected by the Windows worker.
  }
  output.push(effective);
 }
 return output;
}

export async function publicTrendImageRetries(request,env,{json,readIncident=readImageIncident,now=Date.now()}){
 if(request.method!=="GET")return json({error:"method_not_allowed"},405);
 try{
  const rows=await listTrendImageRetries(env);
  const key=rows.map(row=>row.request_id).join(":");
  // One shared refresh per isolate, so repeated public polls cannot download
  // the full GitHub ledger for every request to this metadata-only endpoint.
  if(!recentReconciliation||recentReconciliation.expiresAt<=now||recentReconciliation.key!==key||recentReconciliation.readIncident!==readIncident){
   recentReconciliation={key,readIncident,expiresAt:now+60000,promise:effectiveImageRetries(rows,readIncident,now)};
  }
  return json({schema_version:1,requests:await recentReconciliation.promise},200,{"Cache-Control":"no-store"});
 }
 catch{return json({error:"image_retry_unavailable"},503);}
}

export async function trendImageRetry(request,env,{json,sameOrigin,currentRanking,readIncident=readImageIncident}){
 if(!env.MARKS_DB)return json({error:"image_retry_storage_not_configured"},503);
 if(request.method==="GET"){
  try{return json({requests:await listTrendImageRetries(env)},200,{"Cache-Control":"no-store"});}
  catch{return json({error:"image_retry_unavailable"},503);}
 }
 if(request.method!=="POST"||!sameOrigin(request))return json({error:"method_not_allowed"},405);
 if(Number(request.headers.get("content-length")||0)>1024)return json({error:"invalid_payload"},413);
 let body;
 try{body=await request.json();}catch{return json({error:"invalid_payload"},400);}
 const {trend_id,revision}=body||{};
 if(!ID.test(trend_id)||!Number.isSafeInteger(revision)||revision<1||revision>100000)
  return json({error:"invalid_payload"},400);
 try{
  const ranking=await currentRanking(env);
  const current=ranking.find(x=>x.trend_id===trend_id);
  if(!current||current.revision!==revision||current.status!=="explicada"||
     current.re_in_progress===true||current.image_available===true||
     current.image_in_progress===true||current.image_incident_available!==true)
   return json({error:"image_retry_not_current"},409);
  const detail=await readIncident({project:"ttendencias-v2",id:trend_id,revision,includeIdentity:true});
  const incident=detail.incident;
  if(!detail.available||!incident||incident.retry_mode==="none"||UNSAFE.test(incident.code))
   return json({error:"image_retry_not_safe"},409);
  // Verify the immutable editorial fingerprint against GitHub's current
  // incident rather than trusting the browser's image/revision metadata.
  const hash=detail.editorial_sha256;
  if(!/^[a-f0-9]{64}$/.test(hash))return json({error:"image_retry_unverified"},503);
  await table(env.MARKS_DB);
  // A newly generated raster must remain V2-only until the owner explicitly
  // switches on "Mostrar Imagen", even if an older photo had been opted in.
  // Fail closed before recording the new image job: never leak a replacement.
  await env.MARKS_DB.prepare("CREATE TABLE IF NOT EXISTS public_image_prefs (trend_id TEXT NOT NULL,revision INTEGER NOT NULL,visible INTEGER NOT NULL CHECK(visible IN (0,1)),updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),PRIMARY KEY(trend_id,revision))").run();
  await env.MARKS_DB.prepare("INSERT INTO public_image_prefs(trend_id,revision,visible) VALUES(?,?,0) ON CONFLICT(trend_id,revision) DO UPDATE SET visible=0,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')")
   .bind(trend_id,revision).run();
  const requestId=crypto.randomUUID().replaceAll("-","");
  await env.MARKS_DB.prepare("INSERT INTO trend_image_retry_requests(trend_id,revision,incident_at,editorial_sha256,request_id) VALUES(?,?,?,?,?) ON CONFLICT(trend_id,revision,incident_at) DO NOTHING")
   .bind(trend_id,revision,incident.at,hash,requestId).run();
  const stored=await env.MARKS_DB.prepare("SELECT request_id FROM trend_image_retry_requests WHERE trend_id=? AND revision=? AND incident_at=?")
   .bind(trend_id,revision,incident.at).first();
  if(!/^[a-f0-9]{32}$/.test(stored?.request_id||""))throw Error("IMAGE_RETRY_NOT_PERSISTED");
  return json({ok:true,queued:true,trend_id,revision,incident_at:incident.at},202);
 }catch(error){
  if(error.message==="IMAGE_INCIDENT_REVISION_CHANGED")return json({error:"image_retry_not_current"},409);
  return json({error:"image_retry_unavailable"},503);
 }
}
