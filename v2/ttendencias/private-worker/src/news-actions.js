// Persistent news controls. Namespaced tables preserve all trend state.
import {readNews,readNewsRecord,decorateNews,pageNews,NEWS_SOURCE} from "./news.js";
const ID=/^ttn2-[a-f0-9]{24}$/;
const HEX=/^[a-f0-9]{64}$/;
const ACTIONS=new Set(["archive","rework","rework_x","mark","public_image","suppress_image","publication"]);
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
export async function newsView(env,params){
 const [base,controls]=await Promise.all([readNews({params:new URLSearchParams({state:"ready"}) ,all:true}),newsControls(env)]);
 return pageNews(decorateNews(base,controls),params);
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
  if((action==="archive"||action.startsWith("rework"))&&current.rework_requested)return json({error:"news_already_processing"},409);
  const row=controls.preferences.find(x=>x.event_id===event_id&&x.revision===revision)||{};
  const prefs={...row};delete prefs.event_id;delete prefs.revision;
  const now=new Date().toISOString();
  const entry={action_id:body.action_id,event_id,revision,action,created_at:now,
     ...(action==="rework_x"?{hints:body.hints.trim()}:{}),
     ...(typeof body.value==="boolean"?{value:body.value}:{})};
  if(action==="mark")prefs.marked=body.value;
  if(action==="public_image")prefs.public_image_visible=body.value;
  if(action==="suppress_image")prefs.image_suppressed=body.value;
  if(action==="archive")prefs.archived=true;
  if(action==="rework"||action==="rework_x")prefs.rework_requested=true;
  // A batch is atomic: action receipt and UI preference cannot disagree.
  await env.MARKS_DB.batch([
   env.MARKS_DB.prepare("INSERT INTO news_actions(action_id,event_id,revision,body,created_at) VALUES(?,?,?,?,?)")
    .bind(body.action_id,event_id,revision,JSON.stringify(entry),now),
   env.MARKS_DB.prepare("INSERT INTO news_preferences(event_id,revision,body) VALUES(?,?,?) ON CONFLICT(event_id,revision) DO UPDATE SET body=excluded.body")
    .bind(event_id,revision,JSON.stringify(prefs))]);
  return json({ok:true,event_id,revision,action,publication_sent:false});
 }catch{return json({error:"news_action_unavailable"},503);}
}
async function digest(bytes){return [...new Uint8Array(await crypto.subtle.digest("SHA-256",bytes))].map(x=>x.toString(16).padStart(2,"0")).join("");}
function raster(bytes,mime){
 const v=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
 if(mime==="image/png"&&[137,80,78,71,13,10,26,10].every((x,i)=>bytes[i]===x))
  return {width:v.getUint32(16),height:v.getUint32(20)};
 if(mime==="image/jpeg"&&bytes[0]===255&&bytes[1]===216){
  let p=2;
  while(p+9<bytes.length){if(bytes[p++]!==255)return null;const tag=bytes[p++];if(tag===216||tag===217)continue;
   const length=v.getUint16(p);if(length<2||p+length>bytes.length)return null;
   if([192,193,194].includes(tag))return {width:v.getUint16(p+5),height:v.getUint16(p+3)};p+=length;}
 }
 // PNG and JPEG original uploads; automatic WebP is checked by Pillow and hash at ingest.
 return null;
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
  const bytes=new Uint8Array(buffer),meta=raster(bytes,mime);
  if(!meta||meta.width<1024||meta.height<576||meta.width>8192||meta.height>8192)return json({error:"invalid_original_raster"},400);
  const hash=await digest(buffer),key=id+"-r"+rev+"-"+hash;
  let binary="";for(let p=0;p<bytes.length;p+=32768)binary+=String.fromCharCode(...bytes.subarray(p,p+32768));
  const encoded=btoa(binary);const writes=[];
  for(let p=0,n=0;p<encoded.length;p+=300000,n++)writes.push(env.MARKS_DB.prepare(
   "INSERT INTO news_manual_images(image_key,chunk_no,data) VALUES(?,?,?) ON CONFLICT(image_key,chunk_no) DO NOTHING").bind(key,n,encoded.slice(p,p+300000)));
  const old=controls.preferences.find(x=>x.event_id===id&&x.revision===rev)||{};
  const prefs={...old,manual_image:{key,sha256:hash,mime,bytes:bytes.length,width:meta.width,height:meta.height,editorial_sha256:record.editorial_sha256},
    image_suppressed:false};delete prefs.event_id;delete prefs.revision;
  writes.push(env.MARKS_DB.prepare("INSERT INTO news_preferences(event_id,revision,body) VALUES(?,?,?) ON CONFLICT(event_id,revision) DO UPDATE SET body=excluded.body").bind(id,rev,JSON.stringify(prefs)));
  await env.MARKS_DB.batch(writes);
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
    item.image_suppressed||(publicRead&&!item.public_image_visible))return json({error:"image_hidden"},404);
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
  return new Response(buffer,{headers:{...headers({"Content-Type":mime,"ETag":'"'+hash+'"'}),...(publicRead?{"Access-Control-Allow-Origin":"*"}:{})}});
 }catch{return json({error:"news_image_unavailable"},503);}
}
export async function publicNews(env){
 const raw=await readNews({all:true}),controls=await newsControls(env);
 const view=decorateNews(raw,controls),items=[];
 for(const item of view.items.filter(x=>["ready","archived"].includes(x.group)&&!x.rework_requested).slice(0,100)){
  const record=await readNewsRecord(item.event_id,item.revision);
  items.push({...item,...record,id:item.event_id,headline:record.title,explanation:record.tweet_text,
   image_url:item.image_available&&item.public_image_visible?
    "/api/public-news-image?id="+item.event_id+"&revision="+item.revision:null});
 }
 return {schema_version:1,source:"ttittulares-v2",observed_at:view.observed_at,items};
}
