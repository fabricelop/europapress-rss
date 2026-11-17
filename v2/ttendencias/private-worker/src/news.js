// Read-only V2 news projection. No V1 fallback, D1 writes or editorial execution.
const ID=/^ttn2-[a-f0-9]{24}$/;
import {projectImageIncident} from "./image-incidents.js";
const ACTIVE=new Set(["claimed","send_intent","awaiting_response","capture_recovery","captured","validating","persisting"]);
const GROUPS=new Set(["pending","detected","working","ready","incident","archived"]);
export const NEWS_SOURCE="https://raw.githubusercontent.com/fabricelop/europapress-rss/feature/ttactualidad-v2-clean/v2/ttittulares/state/";
export const NEWS_RADAR_SOURCE="https://raw.githubusercontent.com/fabricelop/europapress-rss/ttactualidad-v2-radar-live/v2/ttittulares/state/radar/live-summary.json";

function url(value){
 try{const parsed=new URL(value);return /^(https?:)$/.test(parsed.protocol)&&!parsed.username&&!parsed.password?parsed.href:null;}catch{return null;}
}
function stamp(value){return typeof value==="string"&&Number.isFinite(Date.parse(value))?value:null;}

export function projectNews(index,queue,clock=Date.now(),liveRadar=null){
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
  const incident=/^[a-f0-9]{64}$/.test(item.editorial_sha256||"")?
   projectImageIncident(item.image_incident,{project:"ttittulares-v2",id,revision:item.current_revision,editorialHash:item.editorial_sha256}):null;
  items.push({event_id:id,revision:item.current_revision,title:item.canonical_title.slice(0,500),
   group,status_label:label,source_families:families,source_family_count:families.length,
   source_url:(item.canonical_urls||[]).map(url).find(Boolean)||null,
   first_seen_at:stamp(item.first_seen_at),last_seen_at:stamp(item.last_seen_at),
   explanation:null,publication_allowed:false,
   image:item.image?.revision===item.current_revision?item.image:null,
   image_available:item.image?.revision===item.current_revision&&item.image.verified===true,
   image_in_progress:item.image_progress?.revision===item.current_revision&&Date.parse(item.image_progress.expires_at)>clock,
   image_incident_available:incident!==null,image_incident_at:incident?.at||null});
 }
 for(const id of jobs.keys())if(!index.items[id])throw Error("NEWS_ORPHAN_QUEUE_ENTRY");
 items.sort((a,b)=>(Date.parse(b.first_seen_at)||0)-(Date.parse(a.first_seen_at)||0)||a.event_id.localeCompare(b.event_id));
 // Radar scans are persisted on an isolated branch. A blocked editorial commit
 // must never make the front end report the older editorial index as a fresh scan.
 const liveStamp=liveRadar?.project==="ttittulares-v2"&&liveRadar?.schema_version===1&&
                 liveRadar?.kind==="independent_radar_summary"&&
                 /^[a-f0-9]{64}$/.test(liveRadar.radar_sha256||"")&&
                 stamp(liveRadar.observed_at)&&liveRadar.metrics&&typeof liveRadar.metrics==="object"
                 ?liveRadar.observed_at:null;
 const observedAt=liveStamp||index.updated_at;
 const age=Math.max(0,Math.floor((clock-Date.parse(observedAt))/60000));
 const editorialAge=Math.max(0,Math.floor((clock-Date.parse(index.updated_at))/60000));
 return {schema_version:1,project:"ttittulares-v2",observed_at:observedAt,editorial_updated_at:index.updated_at,counts,items,
         refresh_mode:liveStamp?"independent_radar_15m":"scheduled_radar_15m",expected_interval_minutes:15,
         radar_age_minutes:age,radar_delayed:age>35,editorial_age_minutes:editorialAge,
         editorial_delayed:editorialAge>35,radar_independent:Boolean(liveStamp),
         radar_metrics:liveStamp?liveRadar.metrics:null,
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
 const editorial=await Promise.all(["news-index.json","editorial-queue.json"].map(async name=>{
  const response=await fetcher(NEWS_SOURCE+name,{headers:{Accept:"application/json"},cf:{cacheTtl:30,cacheEverything:true}});
  if(!response.ok)throw Error("NEWS_SOURCE_UNAVAILABLE");
  const text=await response.text();
  if(text.length>6000000)throw Error("NEWS_SOURCE_TOO_LARGE");
  return JSON.parse(text);
 }));
 let live=null;
 try{
  const response=await fetcher(NEWS_RADAR_SOURCE,{headers:{Accept:"application/json"},cf:{cacheTtl:30,cacheEverything:true}});
  if(response.ok){const body=await response.text();if(body.length<=6000000)live=JSON.parse(body);}
 }catch{/* A missing independent scan cannot prevent viewing already prepared news. */}
 return [...editorial,live];
}

export async function readNews({fetcher=fetch,params=new URLSearchParams(),all=false}={}){
 const [index,queue,live]=await sourceDocuments(fetcher);
 const view=projectNews(index,queue,Date.now(),live);
 return all?view:pageNews(view,params);
}

export function validateNewsRecord(record,id,revision){
 const text=typeof record?.tweet?.text==="string"?record.tweet.text.trim():"";
 const count=text.replace(/https?:\/\/\S+/gu,"X".repeat(23)).length;
 if(record?.schema_version!==1||record.project!=="ttittulares-v2"||record.event_id!==id||record.revision!==revision||
    record.record_status!=="ready"||record.editorial_job_id!==id+"-r"+revision+"-editorial"||
    record.verification?.essential_fact_verified!==true||!text||Array.from(text).length>256||count>280||
    !/^[a-f0-9]{64}$/.test(record.editorial_sha256||""))throw Error("NEWS_RECORD_INVALID");
 return {project:"ttittulares-v2",event_id:id,revision,tweet_text:text,x_character_count:count,
         editorial_sha256:record.editorial_sha256,title:record.title,factual_summary:record.factual_summary,source_evidence:record.source_evidence,prepared_at:record.prepared_at,publication_allowed:false};
}

export async function readNewsRecord(id,revision,{fetcher=fetch,view=null}={}){
 if(!ID.test(id)||!Number.isSafeInteger(revision)||revision<1||revision>100000)throw Error("NEWS_RECORD_ID_INVALID");
 if(!view){const [index,queue,live]=await sourceDocuments(fetcher);view=projectNews(index,queue,Date.now(),live);}
 const item=view.items.find(x=>x.event_id===id);
 if(!item||item.revision!==revision||!["ready","archived"].includes(item.group))throw Error("NEWS_RECORD_NOT_READY");
 const root=NEWS_SOURCE.replace(/state\/$/,"");
 const response=await fetcher(root+"records/"+id+"/r"+revision+".json",{headers:{Accept:"application/json"},cf:{cacheTtl:30,cacheEverything:true}});
 if(!response.ok)throw Error("NEWS_RECORD_UNAVAILABLE");
 const text=await response.text();if(text.length>100000)throw Error("NEWS_RECORD_TOO_LARGE");
 return validateNewsRecord(JSON.parse(text),id,revision);
}



export function decorateNews(view,controls={}){
 const prefs=new Map((controls.preferences||[]).map(x=>[x.event_id+":"+x.revision,x]));
 const counts={pending:0,detected:0,working:0,ready:0,incident:0,archived:0};
 const items=view.items.map(item=>{
  const pref=prefs.get(item.event_id+":"+item.revision)||{};
  const marked=(controls.preferences||[]).filter(x=>x.event_id===item.event_id&&typeof x.marked==="boolean").sort((a,b)=>b.revision-a.revision)[0]?.marked===true;
  // Same conservative default as trends, scoped to the private V1 card only.
  const words=String(item.title||"").normalize("NFD").replace(/[\u0300-\u036f]/g,"").toLowerCase();
  const sensitive=/\b(?:asesinat\w*|fallec\w*|muert\w*|suicid\w*|violacion\w*|abuso\s+sexual|agresion\s+sexual|menores?\s+de\s+edad|ninos?\s+(?:herid\w*|fallecid\w*|victim\w*)|atentad\w*|bombarde\w*|secuestro\w*|tortur\w*|cadaver\w*|victimas?\s+mortal\w*|catastrofe\w*|tragedia\w*|naufragio\w*|sangre|herid\w*\s+grave\w*)\b/u.test(words);
  const row={...item,marked,image_suppressed:pref.image_suppressed===true,
   has_image:item.image_available===true||Boolean(pref.manual_image),
   public_image_visible:pref.public_image_visible??!sensitive, // V1-only switch; independent of V2.
   image_sensitivity_default:sensitive,
   rework_requested:pref.rework_requested===true,
   image_retry_requested:item.image_incident_available===true&&Boolean(item.image_incident_at)&&
      pref.image_retry_incident_at===item.image_incident_at};
  if(pref.archived){row.group="archived";row.status_label=pref.published===true?"Publicada":"Archivada";}
  else if(pref.rework_requested){row.group="working";row.status_label="Reelaboración solicitada";}
  if(pref.manual_image){row.image_available=true;row.image_incident_available=false;}
  if(row.image_suppressed)row.image_available=false;
  counts[row.group]++;return row;
 });
 return {...view,items,counts};
}
