// Persistent news controls. Namespaced tables preserve all trend state.
import {readNews,readNewsRecord,decorateNews,pageNews,NEWS_SOURCE} from "./news.js";
import {readImageIncident} from "./image-incidents.js";
const ID=/^ttn2-[a-f0-9]{24}$/;
const HEX=/^[a-f0-9]{64}$/;
const ACTIONS=new Set(["archive","publish","rework","rework_x","mark","public_image","suppress_image","retry_image"]);
export async function newsTables(db){
 if(!db)throw Error("NEWS_STORAGE_UNAVAILABLE");
 await db.prepare("CREATE TABLE IF NOT EXISTS news_preferences(event_id TEXT NOT NULL,revision INTEGER NOT NULL,body TEXT NOT NULL,PRIMARY KEY(event_id,revision))").run();
 await db.prepare("CREATE TABLE IF NOT EXISTS news_actions(action_id TEXT PRIMARY KEY,event_id TEXT NOT NULL,revision INTEGER NOT NULL,body TEXT NOT NULL,created_at TEXT NOT NULL)").run();
 await db.prepare("CREATE TABLE IF NOT EXISTS news_manual_images(image_key TEXT NOT NULL,chunk_no INTEGER NOT NULL,data TEXT NOT NULL,PRIMARY KEY(image_key,chunk_no))").run();
}
export async function newsControls(env){
 await newsTables(env.MARKS_DB);
 const [prefs,actions]=await Promise.all([
  env.MARKS_DB.prepare("SELECT event_id,revision,body FROM news_preferences").all(),
  env.MARKS_DB.prepare("SELECT body FROM news_actions ORDER BY created_at,action_id LIMIT 5000").all()]);
 return {schema_version:1,project:"ttittulares-v2",
  preferences:(prefs.results||[]).map(x=>({event_id:x.event_id,revision:x.revision,...JSON.parse(x.body)})),
  actions:(actions.results||[]).map(x=>JSON.parse(x.body))};
}
// Independent of Tendencias. PUB confirms a manual publication and archives
// atomically; Quitar only archives. Historical PU events remain in the rolling
// window during the migration; the obsolete PU action accepts no new writes.
export async function newsPublicationCount(request,env,{json}){
 if(request.method!=="GET")return json({error:"method_not_allowed"},405);
 try{
  await newsTables(env.MARKS_DB);
  const now=Date.now(),start=new Date(now-86400000).toISOString(),end=new Date(now).toISOString();
  const where="FROM news_actions WHERE created_at > ? AND created_at <= ? AND json_extract(body,'$.action') IN ('publish','publication')";
  const [total,history]=await Promise.all([
   env.MARKS_DB.prepare("SELECT COUNT(*) AS total "+where).bind(start,end).first(),
   env.MARKS_DB.prepare("SELECT body "+where+" ORDER BY created_at ASC,action_id ASC LIMIT 500").bind(start,end).all()
  ]);
  const events=(history.results||[]).map(x=>JSON.parse(x.body)).filter(x=>
   ID.test(x.event_id||"")&&Number.isSafeInteger(x.revision)&&
   Number.isFinite(Date.parse(x.created_at))).map(x=>({
    event_id:x.event_id,revision:x.revision,pressed_at_ms:Date.parse(x.created_at),
    news_title:typeof x.news_title==="string"?x.news_title.slice(0,180):"Noticia registrada"
   }));
  return json({count:Number(total?.total||0),window_hours:24,events});
 }catch{return json({error:"news_publication_counter_unavailable"},503);}
}
export async function newsView(env,params){
 if(!env.MARKS_DB)return readNews({params});
 const [base,controls]=await Promise.all([readNews({params:new URLSearchParams({state:"ready"}) ,all:true}),newsControls(env)]);
 return pageNews(decorateNews(base,controls),params);
}

async function savePreference(db,id,revision,expected,next,entry){
 await db.prepare("INSERT INTO news_preferences(event_id,revision,body) VALUES(?,?,'{}') ON CONFLICT(event_id,revision) DO NOTHING").bind(id,revision).run();
 const current=await db.prepare("SELECT body FROM news_preferences WHERE event_id=? AND revision=?").bind(id,revision).first();
 if(current.body!==JSON.stringify(expected))return false;
 const statements=[db.prepare("UPDATE news_preferences SET body=? WHERE event_id=? AND revision=? AND body=?")
  .bind(JSON.stringify(next),id,revision,current.body)];
 if(entry)statements.push(db.prepare("INSERT INTO news_actions(action_id,event_id,revision,body,created_at) SELECT ?,?,?,?,? WHERE changes()=1")
  .bind(entry.action_id,id,revision,JSON.stringify(entry),entry.created_at));
 const result=await db.batch(statements);
 return (result[0]?.meta?.changes??0)===1;
}

export async function newsAction(request,env,{json,sameOrigin}){
 if(request.method!=="POST"||!sameOrigin(request))return json({error:"method_not_allowed"},405);
 if(Number(request.headers.get("content-length")||0)>6000)return json({error:"invalid_payload"},413);
 let body;try{body=await request.json();}catch{return json({error:"invalid_payload"},400);}
 const {event_id,revision,action}=body||{};
 if(!ID.test(event_id)||!Number.isSafeInteger(revision)||revision<1||!ACTIONS.has(action)||
    !/^[a-f0-9]{32}$/.test(body.action_id||""))return json({error:"invalid_payload"},400);
 if(action==="rework_x"&&(typeof body.hints!=="string"||body.hints.trim().length<10||body.hints.length>1200))
  return json({error:"invalid_hints"},400);
 if(["mark","public_image","suppress_image"].includes(action)&&typeof body.value!=="boolean")
  return json({error:"invalid_payload"},400);
 try{
  // all rows are needed for actions outside the first page.
  const raw=await readNews({all:true});const controls=await newsControls(env);
  const current=decorateNews(raw,controls).items.find(x=>x.event_id===event_id);
  const old=await env.MARKS_DB.prepare("SELECT body FROM news_actions WHERE action_id=?").bind(body.action_id).first();
  if(old){
   const previous=JSON.parse(old.body);
   if(previous.event_id!==event_id||previous.revision!==revision||previous.action!==action)return json({error:"idempotency_conflict"},409);
   return json({ok:true,replay:true,event_id,revision});
  }
  if(!current||current.revision!==revision||current.group!=="ready")return json({error:"news_not_current"},409);
  if((action==="archive"||action==="publish"||action.startsWith("rework"))&&current.rework_requested)return json({error:"news_already_processing"},409);
  const row=controls.preferences.find(x=>x.event_id===event_id&&x.revision===revision)||{};
  const prefs={...row};delete prefs.event_id;delete prefs.revision;
  const now=new Date().toISOString();
  let incident;
  if(action==="retry_image"){
   if(current.image_available||current.image_in_progress||!current.image_incident_available||
      current.image_suppressed||current.rework_requested||prefs.manual_image)
    return json({error:"image_retry_not_available"},409);
   const result=await readImageIncident({project:"ttittulares-v2",id:event_id,revision});
   incident=result.incident;
   if(!result.available||!incident||incident.at!==current.image_incident_at||incident.retry_mode==="none"||
      /(AUTH|LOGIN|CREDENTIAL|DISK|CLEANUP|CAPTCHA|LEASE_EXPIRED)/.test(incident.code))
    return json({error:"image_retry_unsafe_or_stale"},409);
   if(prefs.image_retry_incident_at===incident.at)
    return json({error:"image_retry_already_requested"},409);
  }
  const entry={action_id:body.action_id,event_id,revision,action,created_at:now,
     ...(action==="publish"?{news_title:String(current.title||"Noticia").slice(0,180)}:{}),
     ...(action==="rework_x"?{hints:body.hints.trim()}:{}),
     ...(action==="retry_image"?{incident_at:incident.at}:{}),
     ...(typeof body.value==="boolean"?{value:body.value}:{})};
  if(action==="mark")prefs.marked=body.value;
  if(action==="public_image")prefs.public_image_visible=body.value;
  if(action==="suppress_image")prefs.image_suppressed=body.value;
  if(action==="archive")prefs.archived=true;
  if(action==="publish"){prefs.archived=true;prefs.published=true;}
  if(action==="rework"||action==="rework_x")prefs.rework_requested=true;
  if(action==="retry_image"){
   prefs.image_retry_incident_at=incident.at;
   prefs.image_retry_request_id=body.action_id;
  }
  const expected={...row};delete expected.event_id;delete expected.revision;
  if(!await savePreference(env.MARKS_DB,event_id,revision,expected,prefs,entry))
   return json({error:"news_preferences_changed"},409);
  const count=action==="publish"?(controls.actions.filter(x=>["publish","publication"].includes(x.action)&&Date.parse(x.created_at)>Date.now()-86400000).length+1):undefined;
  return json({ok:true,event_id,revision,action,count,publication_sent:false});
 }catch{return json({error:"news_action_unavailable"},503);}
}
async function digest(bytes){return [...new Uint8Array(await crypto.subtle.digest("SHA-256",bytes))].map(x=>x.toString(16).padStart(2,"0")).join("");}
function crc32(bytes){
 let crc=0xffffffff;
 for(const byte of bytes){crc^=byte;for(let bit=0;bit<8;bit++)crc=(crc>>>1)^((crc&1)?0xedb88320:0);}
 return (crc^0xffffffff)>>>0;
}
async function raster(bytes,mime){
 if(mime!=="image/png"||![137,80,78,71,13,10,26,10].every((x,i)=>bytes[i]===x))return null;
 const view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
 let p=8,meta=null,ended=false;const idat=[];
 while(p+12<=bytes.length){
  const length=view.getUint32(p);if(length>8388608||p+12+length>bytes.length)return null;
  const type=String.fromCharCode(...bytes.subarray(p+4,p+8)),data=bytes.subarray(p+8,p+8+length);
  if(crc32(bytes.subarray(p+4,p+8+length))!==view.getUint32(p+8+length))return null;
  if(type==="IHDR"){
   if(p!==8||length!==13)return null;
   const width=view.getUint32(p+8),height=view.getUint32(p+12),depth=data[8],color=data[9];
   const channels={0:1,2:3,3:1,4:2,6:4}[color];
   if((color===3&&depth===16)||([2,4,6].includes(color)&&![8,16].includes(depth)))return null;
   if(width<1024||height<576||width>8192||height>8192||![1,2,4,8,16].includes(depth)||!channels||data[10]||data[11]||data[12])return null;
   meta={width,height,stride:Math.ceil(width*channels*depth/8)+1};
   if(meta.stride*height>67108864)return null;
  }else if(!meta)return null;
  if(type==="IDAT")idat.push(data);
  p+=length+12;
  if(type==="IEND"){if(length||p!==bytes.length)return null;ended=true;break;}
 }
 if(!meta||!ended||!idat.length)return null;
 try{
  const stream=new Blob(idat).stream().pipeThrough(new DecompressionStream("deflate"));
  const reader=stream.getReader();let total=0;
  while(true){const {done,value}=await reader.read();if(done)break;
   for(let i=0;i<value.length;i++)if((total+i)%meta.stride===0&&value[i]>4){await reader.cancel();return null;}
   total+=value.length;if(total>meta.stride*meta.height){await reader.cancel();return null;}
  }
  return total===meta.stride*meta.height?{width:meta.width,height:meta.height}:null;
 }catch{return null;}
}
export async function newsManualImage(request,env,{json,sameOrigin}){
 if(request.method!=="POST"||!sameOrigin(request))return json({error:"method_not_allowed"},405);
 const u=new URL(request.url),id=u.searchParams.get("id"),rev=Number(u.searchParams.get("revision"));
 if(!ID.test(id)||!Number.isSafeInteger(rev)||rev<1)return json({error:"invalid_identity"},400);
 try{
  const raw=await readNews({all:true});const controls=await newsControls(env);
  const item=decorateNews(raw,controls).items.find(x=>x.event_id===id);
  if(!item||item.revision!==rev||item.group!=="ready")return json({error:"news_not_current"},409);
  const record=await readNewsRecord(id,rev);
  const buffer=await request.arrayBuffer();if(buffer.byteLength<100000||buffer.byteLength>8388608)return json({error:"invalid_image_size"},413);
  const mime=(request.headers.get("content-type")||"").split(";")[0];
  const bytes=new Uint8Array(buffer),meta=await raster(bytes,mime);
  if(!meta||meta.width<1024||meta.height<576||meta.width>8192||meta.height>8192)return json({error:"invalid_original_raster"},400);
  const hash=await digest(buffer),key=id+"-r"+rev+"-"+hash;
  let binary="";for(let p=0;p<bytes.length;p+=32768)binary+=String.fromCharCode(...bytes.subarray(p,p+32768));
  const encoded=btoa(binary);const writes=[];
  for(let p=0,n=0;p<encoded.length;p+=300000,n++)writes.push(env.MARKS_DB.prepare(
   "INSERT INTO news_manual_images(image_key,chunk_no,data) VALUES(?,?,?) ON CONFLICT(image_key,chunk_no) DO NOTHING").bind(key,n,encoded.slice(p,p+300000)));
  const old=controls.preferences.find(x=>x.event_id===id&&x.revision===rev)||{};
  const prefs={...old,manual_image:{key,sha256:hash,mime,bytes:bytes.length,width:meta.width,height:meta.height,editorial_sha256:record.editorial_sha256},
    image_suppressed:false};delete prefs.event_id;delete prefs.revision;
  await env.MARKS_DB.batch(writes);
  const expected={...old};delete expected.event_id;delete expected.revision;
  if(!await savePreference(env.MARKS_DB,id,rev,expected,prefs))return json({error:"news_preferences_changed"},409);
  const saved=(await env.MARKS_DB.prepare("SELECT body FROM news_preferences WHERE event_id=? AND revision=?").bind(id,rev).first());
  if(JSON.parse(saved.body).manual_image.sha256!==hash)throw Error("IMAGE_READBACK_FAILED");
  return json({ok:true,event_id:id,revision:rev,sha256:hash,association_verified:true,publication_sent:false});
 }catch{return json({error:"news_image_association_unavailable"},503);}
}
export async function newsImage(request,env,{json,headers},publicRead=false){
 const u=new URL(request.url),id=u.searchParams.get("id"),revision=Number(u.searchParams.get("revision"));
 if(request.method!=="GET"||!ID.test(id)||!Number.isSafeInteger(revision)||revision<1)return json({error:"invalid_identity"},400);
 try{
  const raw=await readNews({all:true});const controls=await newsControls(env);
  const item=decorateNews(raw,controls).items.find(x=>x.event_id===id);
  if(!item||item.revision!==revision||!["ready","archived"].includes(item.group)||item.rework_requested||
    item.image_suppressed)return json({error:"image_hidden"},404);
  const record=await readNewsRecord(id,revision);
  const pref=controls.preferences.find(x=>x.event_id===id&&x.revision===revision);
  let buffer,mime,hash;
  if(pref?.manual_image){
   const img=pref.manual_image;if(img.editorial_sha256!==record.editorial_sha256)throw Error("IMAGE_REVISION_CHANGED");
   const parts=(await env.MARKS_DB.prepare("SELECT chunk_no,data FROM news_manual_images WHERE image_key=? ORDER BY chunk_no").bind(img.key).all()).results||[];
   if(parts.some((x,i)=>x.chunk_no!==i))throw Error("IMAGE_CHUNKS_MISSING");
   const binary=atob(parts.map(x=>x.data).join(""));buffer=Uint8Array.from(binary,x=>x.charCodeAt(0)).buffer;
   mime=img.mime;hash=img.sha256;
  }else{
   const img=item.image;
   if(!img||img.editorial_sha256!==record.editorial_sha256||!HEX.test(img.sha256||""))return json({error:"image_not_ready"},404);
   const ext={"image/png":"png","image/jpeg":"jpg","image/webp":"webp"}[img.mime];
   const expected="v2/ttittulares/images/"+id+"-r"+revision+"-"+img.sha256.slice(0,24)+"."+ext;
   if(!ext||img.asset_path!==expected||img.verified!==true)throw Error("IMAGE_IDENTITY_INVALID");
   const res=await fetch(NEWS_SOURCE.replace(/state\/$/,"")+expected.replace(/^v2\/ttittulares\//,""),{cf:{cacheTtl:30}});
   if(!res.ok)throw Error("IMAGE_MISSING");buffer=await res.arrayBuffer();mime=img.mime;hash=img.sha256;
  }
  if(buffer.byteLength<100000||buffer.byteLength>8388608||await digest(buffer)!==hash)throw Error("IMAGE_INTEGRITY_INVALID");
  return new Response(buffer,{headers:{...headers({"Content-Type":mime,"ETag":'"'+hash+'"'}),...(publicRead?{"Access-Control-Allow-Origin":"*","Cross-Origin-Resource-Policy":"cross-origin"}:{})}});
 }catch{return json({error:"news_image_unavailable"},503);}
}
export async function publicNews(env){
 const raw=await readNews({all:true}),controls=await newsControls(env);
 const view=decorateNews(raw,controls),items=[];
 for(const item of view.items.filter(x=>["ready","archived"].includes(x.group)&&!x.rework_requested).slice(0,30)){
  const record=await readNewsRecord(item.event_id,item.revision,{view:raw});
  items.push({...item,...record,id:item.event_id,headline:record.title,explanation:record.tweet_text,
   image_url:item.image_available?
    "/api/public-news-image?id="+item.event_id+"&revision="+item.revision:null});
 }
 return {schema_version:1,source:"ttittulares-v2",observed_at:view.observed_at,items};
}

const machineAuthCache=new Map();
export async function newsWorkerControls(request,env,{json}){
 if(request.method!=="GET")return json({error:"method_not_allowed"},405);
 const auth=request.headers.get("authorization")||"";
 if(!/^Bearer [A-Za-z0-9_.-]{20,512}$/.test(auth))return json({error:"unauthorized"},401);
 try{
  const key=await digest(new TextEncoder().encode(auth));let cached=machineAuthCache.get(key);
  if(!cached||cached<Date.now()){
   const response=await fetch("https://api.github.com/user",{headers:{Authorization:auth,Accept:"application/vnd.github+json","User-Agent":"TTNoticiasV2-WorkerAuth"}});
   if(!response.ok)return json({error:"unauthorized"},401);
   const user=await response.json();if(user.id!==7257052||user.login!=="fabricelop")return json({error:"forbidden"},403);
   if(machineAuthCache.size>20)machineAuthCache.clear();
   machineAuthCache.set(key,Date.now()+300000);
  }
  return json(await newsControls(env));
 }catch{return json({error:"news_controls_unavailable"},503);}
}
