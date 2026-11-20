// The single source of verified news for both V1 and V2.
// No editorial chats, revisions, pictures or per-frontend copies.
const MASTER_URL="https://raw.githubusercontent.com/fabricelop/europapress-rss/ttactualidad-v2-radar-live/v2/ttittulares/state/radar/master-news.json";
const ID=/^ttn2-[a-f0-9]{24}$/;
const DAY=86400000;
const PUBLICATION_LIMIT=51;
let masterTableReady=false;

export function validateMaster(raw){
 if(raw?.project!=="ttittulares-v2"||raw.schema_version!==1||raw.kind!=="master_news"||!Array.isArray(raw.items))
  throw Error("MASTER_NEWS_INVALID");
 const seen=new Set();
 const items=[];
 for(const row of raw.items){
  if(!ID.test(row?.id||"")||seen.has(row.id)||typeof row.title!=="string"||!row.title.trim()||row.title.length>500||
     typeof row.url!=="string"||!row.url.startsWith("https://")||
     !Array.isArray(row.sources)||row.sources.length<4||!Number.isFinite(Date.parse(row.verified_at)))
   throw Error("MASTER_NEWS_ROW_INVALID");
  const families=new Set();
  for(const source of row.sources){
   if(typeof source.family!=="string"||typeof source.url!=="string"||!source.url.startsWith("https://"))
    throw Error("MASTER_NEWS_SOURCE_INVALID");
   families.add(source.family);
  }
  if(families.size<4)throw Error("MASTER_NEWS_QUORUM_INVALID");
  seen.add(row.id);
  items.push({id:row.id,title:row.title,url:row.url,verified_at:row.verified_at,
   first_seen_at:row.first_seen_at||row.verified_at,last_seen_at:row.last_seen_at||row.verified_at,
   source_count:families.size,sources:row.sources});
 }
 return {project:"ttittulares-v2",schema_version:1,kind:"master_news",observed_at:raw.observed_at,items};
}

export async function fetchMaster(fetcher=fetch){
 const response=await fetcher(MASTER_URL,{headers:{Accept:"application/json"},cf:{cacheTtl:60,cacheEverything:true}});
 if(!response.ok)throw Error("MASTER_NEWS_SOURCE_UNAVAILABLE");
 const content=await response.text();
 if(content.length>8000000)throw Error("MASTER_NEWS_TOO_LARGE");
 return validateMaster(JSON.parse(content));
}

export async function newsMasterTable(db){
 if(!db)throw Error("MASTER_NEWS_STORAGE_UNAVAILABLE");
 if(masterTableReady)return;
 await db.prepare("CREATE TABLE IF NOT EXISTS news_master_flags (event_id TEXT PRIMARY KEY,suppressed_at TEXT,published_at TEXT,marked_red INTEGER NOT NULL DEFAULT 0)").run();
 masterTableReady=true;
}

export function projectMaster(master,flags,params=new URLSearchParams()){
 const states=new Map(flags.map(x=>[x.event_id,x]));
 const q=(params.get("q")||"").trim().toLocaleLowerCase("es").slice(0,120);
 const allItems=master.items.filter(row=>!states.get(row.id)?.suppressed_at).map(row=>({
  ...row,published_at:states.get(row.id)?.published_at||null,
  marked_red:states.get(row.id)?.marked_red===1
 }));
 // The badge spans the entire current master, never just the visible page or
 // a search result. Count stories newer than the most recently verified red R.
 const newestFirst=allItems.slice().sort((a,b)=>Date.parse(b.verified_at)-Date.parse(a.verified_at)||a.id.localeCompare(b.id));
 const latestRed=newestFirst.findIndex(item=>item.marked_red);
 const unmarked_since_last_red=latestRed<0?newestFirst.length:latestRed;
 const items=allItems.filter(row=>!q||`${row.title} ${row.sources.map(s=>s.source).join(" ")}`.toLocaleLowerCase("es").includes(q));
 const pageRaw=Number(params.get("page")||"1");
 const pages=Math.max(1,Math.ceil(items.length/40));
 const page=Math.min(pages,Number.isSafeInteger(pageRaw)&&pageRaw>0?pageRaw:1);
 return {...master,total:items.length,pages,page,unmarked_since_last_red,items:items.slice((page-1)*40,page*40)};
}

export async function readNewsMaster(env,params=new URLSearchParams(),{fetcher=fetch}={}){
 const [master]=await Promise.all([fetchMaster(fetcher),newsMasterTable(env.MARKS_DB)]);
 const state=await env.MARKS_DB.prepare("SELECT event_id,suppressed_at,published_at,marked_red FROM news_master_flags").all();
 return projectMaster(master,state.results||[],params);
}

export async function actOnMaster(request,env,{json,sameOrigin}){
 if(request.method!=="POST"||!sameOrigin(request))return json({error:"method_not_allowed"},405);
 if(Number(request.headers.get("content-length")||0)>2000)return json({error:"invalid_payload"},413);
 let body;try{body=await request.json();}catch{return json({error:"invalid_payload"},400);}
 const id=body?.id,action=body?.action;
 if(!ID.test(id||"")||!["suppress","published","red"].includes(action)||
    (action==="red"&&typeof body.value!=="boolean"))return json({error:"invalid_payload"},400);
 try{
  const master=await fetchMaster();
  if(!master.items.some(item=>item.id===id))return json({error:"news_not_current"},409);
  await newsMasterTable(env.MARKS_DB);
  const previous=await env.MARKS_DB.prepare("SELECT suppressed_at,published_at,marked_red FROM news_master_flags WHERE event_id=?").bind(id).first();
  if(previous?.suppressed_at)return json({error:"news_suppressed"},409);
  if(action==="red"){
   const chosen=body.value?1:0;
   const changed=await env.MARKS_DB.prepare(
    "INSERT INTO news_master_flags(event_id,marked_red) VALUES(?,?) ON CONFLICT(event_id) DO UPDATE SET marked_red=excluded.marked_red WHERE news_master_flags.suppressed_at IS NULL RETURNING marked_red"
   ).bind(id,chosen).first();
   if(!changed)return json({error:"news_changed"},409);
   return json({ok:true,id,action,marked_red:changed.marked_red===1});
  }
  if(action==="published"&&previous?.published_at){
   // A previously registered publication must also be visibly red.
   await env.MARKS_DB.prepare("UPDATE news_master_flags SET marked_red=1 WHERE event_id=? AND suppressed_at IS NULL").bind(id).run();
   return json({ok:true,replay:true,id,published_at:previous.published_at,marked_red:true});
  }
  if(action==="suppress"&&previous?.published_at)return json({error:"news_already_published"},409);
  const stamp=new Date().toISOString();
  // One atomic conditional upsert; concurrent tabs cannot erase each other's state.
  const column=action==="suppress"?"suppressed_at":"published_at";
  const redInsert=action==="published"?",marked_red":"";
  const redValue=action==="published"?",1":"";
  const redUpdate=action==="published"?",marked_red=1":"";
  const row=await env.MARKS_DB.prepare(
   `INSERT INTO news_master_flags(event_id,${column}${redInsert}) VALUES(?,?${redValue}) ON CONFLICT(event_id) DO UPDATE SET ${column}=excluded.${column}${redUpdate} WHERE news_master_flags.suppressed_at IS NULL AND news_master_flags.published_at IS NULL RETURNING event_id,${column} AS action_at`
  ).bind(id,stamp).first();
  if(!row)return json({error:"news_changed"},409);
  return json({ok:true,id,action,at:row.action_at,marked_red:action==="published",publication_sent:false});
 }catch{return json({error:"news_master_action_unavailable"},503);}
}

export async function newsMasterPublicationCount(env,{json}){
 try{
  await newsMasterTable(env.MARKS_DB);
  const since=new Date(Date.now()-DAY).toISOString(),until=new Date().toISOString();
  const master=await env.MARKS_DB.prepare("SELECT event_id,published_at FROM news_master_flags WHERE published_at>? AND published_at<=? ORDER BY published_at DESC").bind(since,until).all();
  const events=(master.results||[]).map(r=>({event_id:r.event_id,pressed_at_ms:Date.parse(r.published_at)}));
  // Include publications recorded in the outgoing pre-migration workflow.
  const hasOld=await env.MARKS_DB.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='news_actions'").first();
  if(hasOld){
   const old=await env.MARKS_DB.prepare("SELECT event_id,created_at FROM news_actions WHERE created_at>? AND created_at<=? AND json_extract(body,'$.action') IN ('publish','publication') ORDER BY created_at DESC LIMIT 200").bind(since,until).all();
   const seen=new Set(events.map(x=>x.event_id));
   for(const r of old.results||[]){if(!seen.has(r.event_id)&&ID.test(r.event_id)){events.push({event_id:r.event_id,pressed_at_ms:Date.parse(r.created_at)});seen.add(r.event_id);}}
  }
  events.sort((a,b)=>b.pressed_at_ms-a.pressed_at_ms);
  return json({count:events.length,limit:PUBLICATION_LIMIT,window_hours:24,events});
 }catch{return json({error:"news_publication_counter_unavailable"},503);}
}
