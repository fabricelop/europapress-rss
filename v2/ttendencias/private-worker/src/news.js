// Read-only V2 news projection. No V1 fallback, D1 writes or editorial execution.
const ID=/^ttn2-[a-f0-9]{24}$/;
import {projectImageIncident} from "./image-incidents.js";
const ACTIVE=new Set(["claimed","send_intent","awaiting_response","capture_recovery","captured","validating","persisting"]);
const GROUPS=new Set(["pending","detected","working","ready","incident","archived"]);
export const NEWS_SOURCE="https://raw.githubusercontent.com/fabricelop/europapress-rss/feature/ttactualidad-v2-clean/v2/ttittulares/state/";

function url(value){
 try{const parsed=new URL(value);return /^(https?:)$/.test(parsed.protocol)&&!parsed.username&&!parsed.password?parsed.href:null;}catch{return null;}
}
function stamp(value){return typeof value==="string"&&Number.isFinite(Date.parse(value))?value:null;}

export function projectNews(index,queue,clock=Date.now()){
 if(index?.project!=="ttittulares-v2"||index.schema_version!==1||!index.items||Array.isArray(index.items)||typeof index.items!=="object"||
    queue?.project!=="ttittulares-v2"||queue.schema_version!==1||queue.queue_type!=="editorial"||!Array.isArray(queue.items)||
    !stamp(index.updated_at)||index.updated_at!==queue.updated_at)throw Error("NEWS_SNAPSHOT_INCONSISTENT");
 const jobs=new Map();
 for(const job of queue.items){
  if(!ID.test(job.event_id)||!Number.isSafeInteger(job.revision)||job.revision<1||
     job.job_id!==job.event_id+"-r"+job.revision+"-editorial"||jobs.has(job.event_id))throw Error("NEWS_QUEUE_INVALID");
  jobs.set(job.event_id,job);
 }
 const counts={pending:0,detected:0,working:0,ready:0,incident:0,archived:0};
 const items=[];
 for(const [id,item] of Object.entries(index.items)){
  if(!ID.test(id)||item.event_id!==id||typeof item.canonical_title!=="string"||!item.canonical_title.trim()||
     !Number.isSafeInteger(item.current_revision)||item.current_revision<1)throw Error("NEWS_INDEX_INVALID");
  const job=jobs.get(id);
  if(job&&job.revision!==item.current_revision)throw Error("NEWS_QUEUE_REVISION_MISMATCH");
  let group="incident",label="Estado por revisar";
  const terminal=item.terminal_status||item.status;
  if(["published","dismissed","deleted","archived","treated"].includes(terminal)){
   group="archived";label=({published:"Publicada",dismissed:"Desestimada",deleted:"Retirada",archived:"Archivada",treated:"Tratada"})[terminal];
  }else if(item.status==="monitoring"){
   group="detected";label="Esperando fuentes";
  }else if(job?.status==="pending"){
   group="pending";label="Pendiente de elaboración";
  }else if(ACTIVE.has(job?.status)){
   group="working";label=job.status==="capture_recovery"?"Recuperando elaboración":"En elaboración";
  }else if(job?.status==="ready"&&item.status==="ready"){
   group="ready";label="Elaboración terminada";
  }else if(job?.status==="problematic"){
   label="Incidencia de elaboración";
  }
  const families=[...new Set((item.source_families||[]).filter(x=>typeof x==="string"&&x.trim()))];
  counts[group]++;
  items.push({event_id:id,revision:item.current_revision,title:item.canonical_title.slice(0,500),
   group,status_label:label,source_families:families,source_family_count:families.length,
   source_url:(item.canonical_urls||[]).map(url).find(Boolean)||null,
   first_seen_at:stamp(item.first_seen_at),last_seen_at:stamp(item.last_seen_at),
   explanation:null,publication_allowed:false,
   image_incident_available:/^[a-f0-9]{64}$/.test(item.editorial_sha256||"")&&projectImageIncident(item.image_incident,{project:"ttittulares-v2",id,revision:item.current_revision,editorialHash:item.editorial_sha256})!==null});
 }
 for(const id of jobs.keys())if(!index.items[id])throw Error("NEWS_ORPHAN_QUEUE_ENTRY");
 items.sort((a,b)=>(Date.parse(b.first_seen_at)||0)-(Date.parse(a.first_seen_at)||0)||a.event_id.localeCompare(b.event_id));
 const age=Math.max(0,Math.floor((clock-Date.parse(index.updated_at))/60000));
 return {schema_version:1,project:"ttittulares-v2",observed_at:index.updated_at,counts,items,
         refresh_mode:"scheduled_radar_15m",expected_interval_minutes:15,radar_age_minutes:age,radar_delayed:age>35,
         read_only:true,publication_allowed:false};
}

export function pageNews(view,params){
 const group=params.get("state")||"ready";
 if(!GROUPS.has(group))throw Error("NEWS_FILTER_INVALID");
 const query=(params.get("q")||"").trim().toLocaleLowerCase("es").slice(0,120);
 const matching=view.items.filter(x=>x.group===group&&(!query||(x.title+" "+x.source_families.join(" ")).toLocaleLowerCase("es").includes(query)));
 const pages=Math.max(1,Math.ceil(matching.length/40));
 const requested=Number(params.get("page")||1);
 const page=Math.min(pages,Number.isSafeInteger(requested)&&requested>0?requested:1);
 return {...view,items:matching.slice((page-1)*40,page*40),total:matching.length,page,pages,filter:group};
}

async function sourceDocuments(fetcher){
 return Promise.all(["news-index.json","editorial-queue.json"].map(async name=>{
  const response=await fetcher(NEWS_SOURCE+name,{headers:{Accept:"application/json"},cf:{cacheTtl:30,cacheEverything:true}});
  if(!response.ok)throw Error("NEWS_SOURCE_UNAVAILABLE");
  const text=await response.text();
  if(text.length>6000000)throw Error("NEWS_SOURCE_TOO_LARGE");
  return JSON.parse(text);
 }));
}

export async function readNews({fetcher=fetch,params=new URLSearchParams()}={}){
 return pageNews(projectNews(...await sourceDocuments(fetcher)),params);
}

export function validateNewsRecord(record,id,revision){
 const text=typeof record?.tweet?.text==="string"?record.tweet.text.trim():"";
 const count=text.replace(/https?:\/\/\S+/gu,"X".repeat(23)).length;
 if(record?.schema_version!==1||record.project!=="ttittulares-v2"||record.event_id!==id||record.revision!==revision||
    record.record_status!=="ready"||record.editorial_job_id!==id+"-r"+revision+"-editorial"||
    record.verification?.essential_fact_verified!==true||!text||Array.from(text).length>256||count>280||
    !/^[a-f0-9]{64}$/.test(record.editorial_sha256||""))throw Error("NEWS_RECORD_INVALID");
 return {project:"ttittulares-v2",event_id:id,revision,tweet_text:text,x_character_count:count,
         editorial_sha256:record.editorial_sha256,publication_allowed:false};
}

export async function readNewsRecord(id,revision,{fetcher=fetch}={}){
 if(!ID.test(id)||!Number.isSafeInteger(revision)||revision<1||revision>100000)throw Error("NEWS_RECORD_ID_INVALID");
 const view=projectNews(...await sourceDocuments(fetcher));
 const item=view.items.find(x=>x.event_id===id);
 if(!item||item.revision!==revision||item.group!=="ready")throw Error("NEWS_RECORD_NOT_READY");
 const root=NEWS_SOURCE.replace(/state\/$/,"");
 const response=await fetcher(root+"records/"+id+"/r"+revision+".json",{headers:{Accept:"application/json"},cf:{cacheTtl:30,cacheEverything:true}});
 if(!response.ok)throw Error("NEWS_RECORD_UNAVAILABLE");
 const text=await response.text();if(text.length>100000)throw Error("NEWS_RECORD_TOO_LARGE");
 return validateNewsRecord(JSON.parse(text),id,revision);
}


