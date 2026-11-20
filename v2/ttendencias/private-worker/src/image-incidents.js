// Private, read-only details from the exact persisted image attempt.
// A missing image is not evidence of a failed generation. No inferred failures.
const ROOT="https://raw.githubusercontent.com/fabricelop/europapress-rss/feature/ttactualidad-v2-clean/v2/";
const HASH=/^[a-f0-9]{64}$/;
const CODE=/^[A-Z][A-Z0-9_]{2,119}$/;
const RETRY=new Set(["safe_pre_submit","recover_same_chat","manual_only","none"]);
const ID={"ttendencias-v2":/^trv2-[a-f0-9]{24}$/, "ttittulares-v2":/^ttn2-[a-f0-9]{24}$/};

function detail(value){
 if(typeof value!=="string")return null;
 const text=value.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g,"").trim();
 // Never expose a raw exception containing session URLs, paths or credentials.
 if(!text||text.length>700||/https?:\/\/|[a-z]:\\|bearer\s|cookie|access[_ -]?token|authorization|session[_ -]?secret/i.test(text))return null;
 return text;
}

export function projectImageIncident(value,{project,id,revision,editorialHash}={}){
 if(!value||typeof value!=="object"||!ID[project]?.test(id)||!Number.isSafeInteger(revision)||revision<1||
    value.revision!==revision||!HASH.test(value.editorial_sha256||"")||
    (editorialHash!==undefined&&value.editorial_sha256!==editorialHash)||!CODE.test(value.code||"")||
    typeof value.at!=="string"||!Number.isFinite(Date.parse(value.at)))return null;
 if(value.project!==undefined&&value.project!==project)return null;
 const target=value.event_id??value.trend_id;
 if(target!==undefined&&target!==id)return null;
 const safe=detail(value.detail_safe??value.message);
 return {code:value.code,at:value.at,...(safe?{detail:safe}:{}),
         ...(RETRY.has(value.retry_mode)?{retry_mode:value.retry_mode}:{})};
}

async function document(path,fetcher,{optional=false}={}){
 const response=await fetcher(ROOT+path,{headers:{Accept:"application/json"},cf:{cacheTtl:0,cacheEverything:false}});
 if(response.status===404&&optional)return null;
 if(!response.ok)throw Error("IMAGE_INCIDENT_SOURCE_UNAVAILABLE");
 const text=await response.text();
 if(text.length>6000000)throw Error("IMAGE_INCIDENT_SOURCE_TOO_LARGE");
 try{return JSON.parse(text);}catch{throw Error("IMAGE_INCIDENT_SOURCE_INVALID");}
}

export async function readImageIncident({project,id,revision,fetcher=fetch,includeIdentity=false}={}){
 if(!ID[project]?.test(id)||!Number.isSafeInteger(revision)||revision<1||revision>100000)
  throw Error("IMAGE_INCIDENT_ID_INVALID");
 let incident=null,editorialSha256=null;
 if(project==="ttendencias-v2"){
  const ledger=await document("ttendencias/state/editorial-queue.json",fetcher);
  const row=ledger?.items?.[id],cap=row?.capture;
  if(ledger?.step!=="04_editorial_queue"||ledger.effects_enabled!==false)throw Error("IMAGE_INCIDENT_SOURCE_INVALID");
  if(!row||row.trend_id!==id||row.revision!==revision||cap?.revision!==revision||!HASH.test(cap?.sha256||""))
   throw Error("IMAGE_INCIDENT_REVISION_CHANGED");
  editorialSha256=cap.sha256;
  const progress=row.image_progress;
  const generating=progress?.revision===revision&&progress.editorial_sha256===cap.sha256&&
   progress.status==="in_progress"&&Date.parse(progress.expires_at)>Date.now();
  const saved=cap.image?.revision===revision&&cap.image.status==="saved";
  if(!saved&&!generating)incident=projectImageIncident(row.image_incident,{project,id,revision,editorialHash:cap.sha256});
 }else{
  const event=await document("ttittulares/news/"+id+".json",fetcher);
  if(event?.project!==project||event.schema_version!==1||event.event_id!==id||event.current_revision!==revision)
   throw Error("IMAGE_INCIDENT_REVISION_CHANGED");
  const job=await document("ttittulares/jobs/images/"+id+"-r"+revision+"-image.json",fetcher,{optional:true});
  if(job){
   const path="v2/ttittulares/records/"+id+"/r"+revision+".json";
   if(job.project!==project||job.schema_version!==1||job.event_id!==id||job.revision!==revision||
      job.job_id!==id+"-r"+revision+"-image"||job.source_record_path!==path)throw Error("IMAGE_INCIDENT_SOURCE_INVALID");
   const record=await document(path.replace(/^v2\//,""),fetcher);
   if(record.project!==project||record.event_id!==id||record.revision!==revision||record.record_status!=="ready"||
      !HASH.test(record.editorial_sha256||"")||job.editorial_sha256!==record.editorial_sha256)
    throw Error("IMAGE_INCIDENT_REVISION_CHANGED");
   if(job.status==="problematic"&&job.problem)incident=projectImageIncident(
    {...job.problem,project,event_id:id,revision,editorial_sha256:job.editorial_sha256},
    {project,id,revision,editorialHash:record.editorial_sha256});
  }
 }
 return {project,target_id:id,revision,available:incident!==null,incident,
  ...(includeIdentity&&editorialSha256?{editorial_sha256:editorialSha256}:{})};
}
