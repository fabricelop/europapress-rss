import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import worker from "../src/index.js";
import {DatabaseSync} from "node:sqlite";
import {deflateSync} from "node:zlib";
import {newsAction,newsControls,newsView,newsPublicationCount,newsManualImage,newsImage,newsWorkerControls,publicNews,publicNewsImageVisibility,publicNewsArchivedIndex} from "../src/news-actions.js";
import {decorateNews,projectNews} from "../src/news.js";
const id="ttn2-"+"a".repeat(24),time="2026-11-18T08:13:24Z",hash="c".repeat(64);
function fixture(){return [
 {schema_version:1,project:"ttittulares-v2",updated_at:time,items:{[id]:{event_id:id,current_revision:1,status:"ready",
 canonical_title:"Un hecho contrastado entre fuentes diferentes",source_families:["RTVE","EFE"],canonical_urls:["https://example.com/news"],first_seen_at:time,last_seen_at:time}}},
 {schema_version:1,project:"ttittulares-v2",queue_type:"editorial",updated_at:time,items:[{event_id:id,revision:1,job_id:id+"-r1-editorial",status:"ready"}]},
 {schema_version:1,project:"ttittulares-v2",event_id:id,revision:1,record_status:"ready",editorial_job_id:id+"-r1-editorial",
 editorial_sha256:hash,verification:{essential_fact_verified:true},title:"Hecho contrastado",factual_summary:"Un hecho documentado.",
 tweet:{text:"Una noticia contrastada y concisa. #Noticias #Actualidad"}}];}
function db(){
 const sql=new DatabaseSync(":memory:");
 return {sql,prepare(query){
  const statement=sql.prepare(query);let args=[];
  const result={bind(...values){args=values;return result;},
   async run(){const info=statement.run(...args);return {meta:{changes:Number(info.changes)}};},
   async all(){return {results:statement.all(...args)};},async first(){return statement.get(...args)||null;}};
  return result;
 },async batch(statements){sql.exec("BEGIN");try{const out=[];for(const s of statements)out.push(await s.run());sql.exec("COMMIT");return out;}catch(e){sql.exec("ROLLBACK");throw e;}}};
}
const helpers={json:(body,status=200)=>new Response(JSON.stringify(body),{status}),sameOrigin:()=>true,headers:extra=>extra};
async function scoped(fn){const old=globalThis.fetch,docs=fixture();globalThis.fetch=async url=>new Response(JSON.stringify(String(url).includes("/records/")?docs[2]:String(url).endsWith("news-index.json")?docs[0]:docs[1]));
 try{await fn({MARKS_DB:db()},docs);}finally{globalThis.fetch=old;}}
function request(action,extra={}){return new Request("https://private.example/api/news-actions",{method:"POST",headers:{"content-type":"application/json"},
 body:JSON.stringify({event_id:id,revision:1,action,action_id:"1".repeat(32),...extra})});}
test("Quitar persistently moves READY to Archive without incrementing publications",()=>scoped(async(env,docs)=>{
 const original=JSON.stringify(docs[2]);const result=await newsAction(request("archive"),env,helpers);
 assert.equal(result.status,200);assert.equal((await result.json()).publication_sent,false);
 const controls=await newsControls(env);assert.equal(controls.actions[0].action,"archive");
 const view=await newsView(env,new URLSearchParams({state:"archived"}));assert.equal(view.total,1);assert.equal(view.counts.ready,0);
 assert.equal(view.items[0].status_label,"Archivada");
 assert.equal((await(await newsPublicationCount(new Request("https://private.example/api/news-publication-count"),env,helpers)).json()).count,0);
 assert.equal(JSON.stringify(docs[2]),original);
 const replay=await newsAction(request("archive"),env,helpers);assert.equal((await replay.json()).replay,true);
}));
test("PUB confirms a manual publication, archives, counts once and cannot be repeated",()=>scoped(async(env,docs)=>{
 const original=JSON.stringify(docs[2]);
 const receipt=await newsAction(request("publish"),env,helpers);
 assert.equal(receipt.status,200);assert.equal((await receipt.json()).publication_sent,false);
 const archived=await newsView(env,new URLSearchParams({state:"archived"}));
 assert.equal(archived.total,1);assert.equal(archived.items[0].status_label,"Publicada");
 const count=async()=> (await(await newsPublicationCount(new Request("https://private.example/api/news-publication-count"),env,helpers)).json()).count;
 assert.equal(await count(),1);
 assert.equal((await(await newsAction(request("publish"),env,helpers)).json()).replay,true);
 assert.equal(await count(),1);
 assert.equal((await newsAction(request("publish",{action_id:"2".repeat(32)}),env,helpers)).status,409);
 assert.equal(JSON.stringify(docs[2]),original);
}));
test("RE-X requires useful hints, persists them, hides READY and rejects another current mutation",()=>scoped(async env=>{
 assert.equal((await newsAction(request("rework_x",{hints:"corto"}),env,helpers)).status,400);
 assert.equal((await newsAction(request("rework_x",{hints:"Contrastar el comunicado original en X."}),env,helpers)).status,200);
 const view=await newsView(env,new URLSearchParams({state:"working"}));assert.equal(view.total,1);
 const controls=await newsControls(env);assert.match(controls.actions[0].hints,/comunicado/);
 assert.equal((await newsAction(request("archive",{action_id:"2".repeat(32)}),env,helpers)).status,409);
}));
test("R and image preferences are distinct from PUB and Quitar; old PU is closed",()=>scoped(async env=>{
 for(const [n,action,value] of [[1,"mark",true],[2,"public_image",false],[3,"suppress_image",true]]){
  assert.equal((await newsAction(request(action,{action_id:String(n).repeat(32),value}),env,helpers)).status,200);
 }
 const view=await newsView(env,new URLSearchParams({state:"ready"}));assert.equal(view.total,1);
 assert.equal(view.items[0].marked,true);assert.equal(view.items[0].image_suppressed,true);
 assert.equal(view.items[0].public_image_visible,false);
 assert.equal((await newsControls(env)).actions.filter(x=>x.action==="publication").length,0);
 assert.equal((await newsAction(request("publication",{action_id:"4".repeat(32)}),env,helpers)).status,400);
}));
test("public V1 visibility reads one exact revision and follows both sides of the switch",()=>scoped(async env=>{
 await newsControls(env);
 const url="https://private.example/api/public-news-image-visibility?id="+id+"&revision=1";
 const visible=async()=>publicNewsImageVisibility(new Request(url),env,helpers);
 assert.equal((await(await visible()).json()).public_image_visible,null);
 assert.equal((await newsAction(request("public_image",{value:true}),env,helpers)).status,200);
 let result=await visible();assert.equal(result.status,200);
 assert.deepEqual(await result.json(),{schema_version:1,project:"ttittulares-v2",event_id:id,revision:1,
  public_image_visible:true,image_suppressed:false,rework_requested:false,archived:false,dismissed:false});
 assert.equal((await(await publicNewsImageVisibility(new Request(url.replace("revision=1","revision=2")),env,helpers)).json()).public_image_visible,null);
 assert.equal((await publicNewsImageVisibility(new Request(url.replace(id,"bad")),env,helpers)).status,400);
 assert.equal((await publicNewsImageVisibility(new Request(url,{method:"POST"}),env,helpers)).status,405);
}));
test("ARCH retains the per-revision image switch without unarchiving or touching the V2 original",()=>scoped(async(env,docs)=>{
 docs[0].items[id].image={revision:1,verified:true,editorial_sha256:hash};
 await newsControls(env);
 assert.equal((await newsAction(request("archive"),env,helpers)).status,200);
 let archived=await newsView(env,new URLSearchParams({state:"archived"}));
 assert.equal(archived.total,1);assert.equal(archived.items[0].has_image,true);
 assert.equal((await newsAction(request("public_image",{action_id:"2".repeat(32),value:false}),env,helpers)).status,200);
 let visibility=await(await publicNewsImageVisibility(new Request("https://private.example/api/public-news-image-visibility?id="+id+"&revision=1"),env,helpers)).json();
 assert.equal(visibility.public_image_visible,false);assert.equal(visibility.archived,true);
 assert.equal((await newsAction(request("public_image",{action_id:"3".repeat(32),value:true}),env,helpers)).status,200);
 visibility=await(await publicNewsImageVisibility(new Request("https://private.example/api/public-news-image-visibility?id="+id+"&revision=1"),env,helpers)).json();
 assert.equal(visibility.public_image_visible,true);assert.equal(visibility.archived,true);
 archived=await newsView(env,new URLSearchParams({state:"archived"}));
 assert.equal(archived.items[0].image_available,true);assert.equal(archived.items[0].public_image_visible,true);
 assert.equal((await newsControls(env)).actions.filter(x=>x.action==="publish").length,0);
 assert.equal((await newsAction(request("rework",{action_id:"4".repeat(32)}),env,helpers)).status,409);
}));
test("public ARCH index retains a queue-removed story but never discloses suppressed incidents",()=>scoped(async env=>{
 await newsControls(env);
 const url=new Request("https://private.example/api/public-news-archived-index");
 assert.deepEqual((await(await publicNewsArchivedIndex(url,env,helpers)).json()).items,[]);
 assert.equal((await newsAction(request("archive"),env,helpers)).status,200);
 assert.deepEqual((await(await publicNewsArchivedIndex(url,env,helpers)).json()).items,[{event_id:id,revision:1}]);
 const another="ttn2-"+"b".repeat(24);
 await env.MARKS_DB.prepare("INSERT INTO news_preferences(event_id,revision,body) VALUES(?,?,?)")
  .bind(another,1,JSON.stringify({archived:true,dismissed:true})).run();
 assert.deepEqual((await(await publicNewsArchivedIndex(url,env,helpers)).json()).items,[{event_id:id,revision:1}]);
 assert.equal((await publicNewsArchivedIndex(new Request(url.url,{method:"POST"}),env,helpers)).status,405);
}));
test("old PEND and INC leave the active lists but audit-ready stories remain",()=>scoped(async(env,docs)=>{
 docs[0].items[id].first_seen_at="2026-11-17T12:00:00Z";
 docs[1].items[0].requested_at="2026-11-17T12:00:00Z";
 docs[0].items[id].status="editorial_pending";docs[1].items[0].status="pending";
 let view=await newsView(env,new URLSearchParams({state:"pending"}));assert.equal(view.total,0);assert.equal(view.counts.pending,0);
 docs[1].items[0].status="problematic";
 view=await newsView(env,new URLSearchParams({state:"incident"}));assert.equal(view.total,0);assert.equal(view.counts.incident,0);
 docs[0].items[id].status="ready";docs[1].items[0].status="ready";
 view=await newsView(env,new URLSearchParams({state:"ready"}));assert.equal(view.total,1);
}));
test("news PUB counter is a separate exact rolling 24-hour register; legacy PU remains counted until expiry",()=>scoped(async env=>{
 const count=async()=>{
  const response=await newsPublicationCount(new Request("https://private.example/api/news-publication-count"),env,helpers);
  assert.equal(response.status,200);
  return response.json();
 };
 assert.equal((await count()).count,0);
 // Existing PU records are kept for their remaining 24-hour window, without accepting new PU clicks.
 await newsControls(env);
 const oldPU={action_id:"1".repeat(32),event_id:id,revision:1,action:"publication",created_at:new Date().toISOString(),news_title:"Noticia histórica"};
 await env.MARKS_DB.prepare("INSERT INTO news_actions(action_id,event_id,revision,body,created_at) VALUES(?,?,?,?,?)")
  .bind(oldPU.action_id,id,1,JSON.stringify(oldPU),oldPU.created_at).run();
 assert.equal((await newsAction(request("mark",{action_id:"2".repeat(32),value:true}),env,helpers)).status,200);
 const receipt=await newsAction(request("publish",{action_id:"3".repeat(32)}),env,helpers);
 assert.equal(receipt.status,200);
 let result=await count();assert.equal(result.count,2);
 assert.equal(result.events.length,2);
 assert.equal(result.events[0].news_title,"Noticia histórica");
 assert.ok(result.events.every(x=>x.event_id===id&&x.pressed_at_ms>0));
 // A 25-hour-old PU leaves the window; the current PUB remains counted.
 const old=new Date(Date.now()-25*3600000).toISOString();
 env.MARKS_DB.sql.prepare("UPDATE news_actions SET created_at=?,body=json_set(body,'$.created_at',?) WHERE action_id=?")
  .run(old,old,"1".repeat(32));
 result=await count();assert.equal(result.count,1);assert.equal(result.events.length,1);
 const replay=await newsAction(request("publish",{action_id:"3".repeat(32)}),env,helpers);
 assert.equal((await replay.json()).replay,true);assert.equal((await count()).count,1);
 const method=await newsPublicationCount(new Request("https://private.example/api/news-publication-count",{method:"POST"}),env,helpers);
 assert.equal(method.status,405);
}));
test("actions enforce same origin, revision and idempotency identity",()=>scoped(async env=>{
 assert.equal((await newsAction(request("mark",{value:true}),env,{...helpers,sameOrigin:()=>false})).status,405);
 assert.equal((await newsAction(request("archive",{revision:2}),env,helpers)).status,409);
 await newsAction(request("mark",{value:true}),env,helpers);
 assert.equal((await newsAction(request("publish"),env,helpers)).status,409);
}));
test("manual image retry is a private one-shot action bound to the exact failed image incident",()=>scoped(async(env,docs)=>{
 const incidentAt="2026-11-17T15:00:00Z";
 const event={project:"ttittulares-v2",schema_version:1,event_id:id,current_revision:1};
 const job={project:"ttittulares-v2",schema_version:1,event_id:id,revision:1,
  job_id:id+"-r1-image",source_record_path:"v2/ttittulares/records/"+id+"/r1.json",
  editorial_sha256:hash,status:"problematic",problem:{code:"NEWS_IMAGE_CAPTURE_TIMEOUT",at:incidentAt,retry_mode:"manual_only"}};
 docs[0].items[id].editorial_sha256=hash;
 docs[0].items[id].image_incident={...job.problem,event_id:id,revision:1,editorial_sha256:hash};
 globalThis.fetch=async url=>{
  const target=String(url);
  return Response.json(target.includes("/jobs/images/")?job:target.includes("/news/"+id)?event:
   target.includes("/records/")?docs[2]:target.endsWith("news-index.json")?docs[0]:docs[1]);
 };
 const actionId="f".repeat(32);
 const send=(key=actionId)=>newsAction(request("retry_image",{action_id:key}),env,helpers);
 const result=await send();assert.equal(result.status,200);
 const controls=await newsControls(env);
 assert.equal(controls.actions[0].action,"retry_image");
 assert.equal(controls.actions[0].incident_at,incidentAt);
 assert.equal(controls.preferences[0].image_retry_request_id,actionId);
 assert.equal((await send()).status,200); // exact replay, no second action
 assert.equal((await send("e".repeat(32))).status,409); // same incident, different click
 assert.equal((await newsControls(env)).actions.length,1);
 const displayed=await newsView(env,new URLSearchParams({state:"ready"}));
 assert.equal(displayed.items[0].image_retry_requested,true);
 assert.equal(displayed.items[0].image_incident_available,true);
 assert.equal(displayed.items[0].has_image,false);
 assert.equal(docs[2].editorial_sha256,hash);
 job.problem.at="2026-11-17T15:05:00Z";
 docs[0].items[id].image_incident.at=job.problem.at;
 assert.equal((await send("d".repeat(32))).status,200);
 assert.equal((await newsControls(env)).actions.length,2);
 assert.equal((await send("c".repeat(32))).status,409);
}));
test("manual image retry cannot override an unsafe incident or an active image",()=>scoped(async(env,docs)=>{
 const at="2026-11-17T15:00:00Z";
 docs[0].items[id].editorial_sha256=hash;
 docs[0].items[id].image_incident={event_id:id,revision:1,editorial_sha256:hash,code:"NEWS_IMAGE_CLEANUP_UNVERIFIED",at,retry_mode:"manual_only"};
 const job={project:"ttittulares-v2",schema_version:1,event_id:id,revision:1,
  job_id:id+"-r1-image",source_record_path:"v2/ttittulares/records/"+id+"/r1.json",
  editorial_sha256:hash,status:"problematic",problem:{code:"NEWS_IMAGE_CLEANUP_UNVERIFIED",at,retry_mode:"manual_only"}};
 globalThis.fetch=async url=>{
  const target=String(url);
  return Response.json(target.includes("/jobs/images/")?job:target.includes("/news/"+id)?
   {project:"ttittulares-v2",schema_version:1,event_id:id,current_revision:1}:
   target.includes("/records/")?docs[2]:target.endsWith("news-index.json")?docs[0]:docs[1]);
 };
 const rejected=await newsAction(request("retry_image"),env,helpers);
 assert.equal(rejected.status,409);assert.equal((await newsControls(env)).actions.length,0);
 docs[0].items[id].image_progress={revision:1,editorial_sha256:hash,expires_at:"2090-01-01T00:00:00Z"};
 assert.equal((await newsAction(request("retry_image"),env,helpers)).status,409);
}));
test("INC manual retry enters Pending until a fresh Windows editorial revision starts and cannot duplicate",()=>scoped(async(env,docs)=>{
 docs[0].items[id].status="editorial_in_progress";docs[1].items[0].status="problematic";
 const job={schema_version:1,project:"ttittulares-v2",event_id:id,revision:1,
  job_id:id+"-r1-editorial",status:"problematic",lease:null,
  problem:{code:"INVALID_EDITORIAL_JSON",at:time,retry_mode:"manual_only"}};
 const original=globalThis.fetch;globalThis.fetch=async url=>String(url).includes("/jobs/editorial/")?Response.json(job):original(url);
 const initial=await newsView(env,new URLSearchParams({state:"incident"}));
 assert.equal(initial.total,1);assert.equal(initial.items[0].status_label,"Incidencia de elaboración");
 const first=await newsAction(request("retry_editorial"),env,helpers);assert.equal(first.status,200);
 const controls=await newsControls(env);
 assert.equal(controls.actions[0].action,"retry_editorial");
 assert.equal(controls.preferences[0].rework_requested,true);
 assert.equal(controls.preferences[0].editorial_retry_requested,true);
 assert.equal((await newsView(env,new URLSearchParams({state:"incident"}))).total,0);
 assert.equal((await newsView(env,new URLSearchParams({state:"working"}))).total,0);
 const pending=await newsView(env,new URLSearchParams({state:"pending"}));
 assert.equal(pending.total,1);assert.equal(pending.items[0].status_label,"Reintento solicitado");
 assert.equal((await newsAction(request("retry_editorial",{action_id:"2".repeat(32)}),env,helpers)).status,409);
 assert.equal((await newsControls(env)).actions.length,1);
}));
test("an earlier INC retry already in controls stays visible in Pending before Windows consumes it",()=>{
 const [index,queue]=fixture();
 queue.items[0].status="problematic";
 const view=decorateNews(projectNews(index,queue),{preferences:[{
  event_id:id,revision:1,rework_requested:true}],actions:[{
  action:"retry_editorial",event_id:id,revision:1}]});
 assert.equal(view.counts.pending,1);
 assert.equal(view.counts.incident,0);
 assert.equal(view.items[0].status_label,"Reintento solicitado");
});
test("INC suppression hides the candidate from every list while retaining its private audit",()=>scoped(async(env,docs)=>{
 docs[0].items[id].status="editorial_in_progress";docs[1].items[0].status="problematic";
 const job={schema_version:1,project:"ttittulares-v2",event_id:id,revision:1,
  job_id:id+"-r1-editorial",status:"problematic",lease:null,
  problem:{code:"NEWS_OWN_CHROME_CLEANUP_UNVERIFIED",at:time,retry_mode:"manual_only"}};
 const original=globalThis.fetch;globalThis.fetch=async url=>String(url).includes("/jobs/editorial/")?Response.json(job):original(url);
 const unsafe=await newsAction(request("retry_editorial"),env,helpers);
 assert.equal(unsafe.status,409);assert.equal((await unsafe.json()).error,"news_retry_requires_environment_repair");
 const response=await newsAction(request("dismiss"),env,helpers);
 assert.equal(response.status,200);assert.equal((await response.json()).publication_sent,false);
 for(const state of ["incident","archived","pending","ready","working","detected"]){
  const view=await newsView(env,new URLSearchParams({state}));
  assert.equal(view.total,0,`INC suppression appeared in ${state}`);
  assert.equal(view.counts[state],0,`INC suppression count remained in ${state}`);
 }
 const controls=await newsControls(env);
 assert.equal(controls.actions[0].action,"dismiss");
 assert.equal(controls.preferences[0].incident_hidden,true);
 assert.equal(controls.preferences[0].dismissed,true);
 assert.equal(controls.preferences[0].archived,true);
 assert.equal((await newsAction(request("dismiss"),env,helpers)).status,200);
 assert.equal((await newsAction(request("dismiss",{action_id:"2".repeat(32)}),env,helpers)).status,409);
 assert.ok(docs[0].items[id],"Immutable news evidence must remain available");
 assert.equal((await(await newsPublicationCount(new Request("https://private.example/api/news-publication-count"),env,helpers)).json()).count,0);
}));
test("legacy INC dismissal is hidden without affecting Pending suppression",()=>{
 const [index,queue]=fixture();index.items[id].status="editorial_in_progress";queue.items[0].status="problematic";
 const view=decorateNews(projectNews(index,queue),{preferences:[{event_id:id,revision:1,dismissed:true,archived:true}]});
 assert.deepEqual(view.items,[]);assert.equal(view.counts.incident,0);assert.equal(view.counts.archived,0);
});
test("Pending exposes independent suppress and URGENTE actions with durable one-shot controls",()=>scoped(async(env,docs)=>{
 docs[0].items[id].status="editorial_pending";docs[1].items[0].status="pending";
 const receipt=await newsAction(request("urgent"),env,helpers);
 assert.equal(receipt.status,200);
 const view=await newsView(env,new URLSearchParams({state:"pending"}));
 assert.equal(view.total,1);assert.equal(view.items[0].urgent_requested,true);
 assert.match(view.items[0].status_label,/URGENTE/);
 assert.equal((await newsAction(request("urgent",{action_id:"2".repeat(32)}),env,helpers)).status,409);
 assert.equal((await newsAction(request("dismiss",{action_id:"3".repeat(32)}),env,helpers)).status,200);
 const archive=await newsView(env,new URLSearchParams({state:"archived"}));
 assert.equal(archive.items[0].status_label,"Suprimida");
 assert.equal((await newsView(env,new URLSearchParams({state:"pending"}))).total,0);
 const controls=await newsControls(env);assert.deepEqual(controls.actions.map(x=>x.action),["urgent","dismiss"]);
 assert.equal((await(await newsPublicationCount(new Request("https://private.example/api/news-publication-count"),env,helpers)).json()).count,0);
}));
test("stale revision preferences never archive or suppress a new record",()=>{
 const [index,queue]=fixture();index.items[id].current_revision=2;queue.items[0].revision=2;queue.items[0].job_id=id+"-r2-editorial";
 const view=decorateNews(projectNews(index,queue),{preferences:[{event_id:id,revision:1,archived:true,image_suppressed:true,marked:true}]});
 assert.equal(view.items[0].group,"ready");assert.equal(view.items[0].image_suppressed,false);assert.equal(view.items[0].marked,true);
});
test("image header presence survives intentional image suppression and manual association",()=>{
 const [index,queue]=fixture();index.items[id].image={revision:1,verified:true};
 const controls={preferences:[{event_id:id,revision:1,image_suppressed:true,manual_image:{sha256:hash}}]};
 const view=decorateNews(projectNews(index,queue),controls).items[0];
 assert.equal(view.has_image,true);assert.equal(view.image_available,false);assert.equal(view.image_suppressed,true);
 const clean=decorateNews(projectNews(...fixture()),{preferences:[]}).items[0];
 assert.equal(clean.has_image,false);
});
test("manual image rejects thumbnails and never creates a successful association",()=>scoped(async env=>{
 const req=new Request("https://private.example/api/news-manual-image?id="+id+"&revision=1",{method:"POST",headers:{"content-type":"image/png"},body:new Uint8Array(1024)});
 assert.equal((await newsManualImage(req,env,helpers)).status,413);
 assert.equal((await newsControls(env)).preferences.length,0);
}));
test("manual original association is exact and V1 switch never hides an authorized V2 image",()=>scoped(async env=>{
 const crc32=bytes=>{let crc=0xffffffff;for(const byte of bytes){crc^=byte;for(let bit=0;bit<8;bit++)crc=(crc>>>1)^((crc&1)?0xedb88320:0);}return (crc^0xffffffff)>>>0;};
 const chunk=(type,data)=>{const tag=Buffer.from(type),out=Buffer.alloc(12+data.length);out.writeUInt32BE(data.length);tag.copy(out,4);data.copy(out,8);out.writeUInt32BE(crc32(Buffer.concat([tag,data])),8+data.length);return out;};
 const ihdr=Buffer.alloc(13);ihdr.writeUInt32BE(1024);ihdr.writeUInt32BE(576,4);ihdr[8]=8;ihdr[9]=2;
 const pixels=Buffer.alloc((1024*3+1)*576);let noise=12345678;
 for(let i=0;i<pixels.length;i++){noise^=noise<<13;noise^=noise>>>17;noise^=noise<<5;pixels[i]=i%(1024*3+1)===0?0:noise&255;}
 const bytes=Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),chunk("IHDR",ihdr),chunk("IDAT",deflateSync(pixels)),chunk("IEND",Buffer.alloc(0))]);
 const req=new Request("https://private.example/api/news-manual-image?id="+id+"&revision=1",{method:"POST",headers:{"content-type":"image/png"},body:bytes});
 const saved=await newsManualImage(req,env,helpers);assert.equal(saved.status,200);assert.equal((await saved.json()).association_verified,true);
 const imageReq=new Request("https://private.example/api/news-image?id="+id+"&revision=1");
 const original=await newsImage(imageReq,env,helpers);assert.equal(original.status,200);assert.equal((await original.arrayBuffer()).byteLength,bytes.length);
 const publicImage=await newsImage(imageReq,env,helpers,true);assert.equal(publicImage.status,200);assert.equal(publicImage.headers.get("cross-origin-resource-policy"),"cross-origin");
 await newsAction(request("public_image",{value:false}),env,helpers);
 assert.equal((await newsImage(imageReq,env,helpers,true)).status,200);
 const publicFeed=(await publicNews(env)).items;
 assert.equal(publicFeed[0].public_image_visible,false);
 assert.match(publicFeed[0].image_url,/^\/api\/public-news-image\?/);
}));
test("sensitive news image starts hidden only in V1, can be shown manually",()=>{
 const [index,queue]=fixture();index.items[id].canonical_title="Hallan víctimas mortales tras un naufragio";
 index.items[id].image={revision:1,verified:true};
 let row=decorateNews(projectNews(index,queue),{preferences:[]}).items[0];
 assert.equal(row.image_sensitivity_default,true);
 assert.equal(row.image_available,true);
 assert.equal(row.public_image_visible,false);
 row=decorateNews(projectNews(index,queue),{preferences:[{event_id:id,revision:1,public_image_visible:true}]}).items[0];
 assert.equal(row.public_image_visible,true);
});
test("V1 image switch does not hide a verified original inside private V2",()=>{
 const source=fs.readFileSync(new URL('../web-source/news-actions.js',import.meta.url),'utf8');
 assert.match(source,/if\(item\.image_available\)\{\s*const image=el\("img","news-original"\)/);
 assert.match(source,/if\(item\.public_image_visible===false\)image\.after/);
 assert.match(source,/aria-label","Mostrar imagen en V1"/);
});

test("all news mutations and original-image reads retain the private session gate",async()=>{
 const env={AUTH_PASSWORD:"test-password-more-than-sixteen",SESSION_SECRET:"test-session-secret-more-than-thirty-two-characters"};
 for(const path of ["/api/news-actions","/api/news-manual-image","/api/news-image","/api/news-publication-count"]){
  assert.equal((await worker.fetch(new Request("https://private.example"+path),env)).status,401);
 }
});

test("worker controls reject missing credentials and another GitHub identity",()=>scoped(async env=>{
 const path="https://private.example/api/news-worker-controls";
 assert.equal((await newsWorkerControls(new Request(path),env,helpers)).status,401);
 const old=globalThis.fetch;try{
  globalThis.fetch=async()=>new Response(JSON.stringify({id:123,login:"other"}));
  const response=await newsWorkerControls(new Request(path,{headers:{authorization:"Bearer "+"x".repeat(40)}}),env,helpers);
  assert.equal(response.status,403);
 }finally{globalThis.fetch=old;}
}));
test("editorial hints are available only through owner-verified machine authentication",()=>scoped(async env=>{
 await newsAction(request("rework_x",{hints:"Buscar el comunicado original con estas pistas."}),env,helpers);
 const old=globalThis.fetch;try{
  globalThis.fetch=async()=>new Response(JSON.stringify({id:7257052,login:"fabricelop"}));
  const result=await newsWorkerControls(new Request("https://private.example/api/news-worker-controls",{headers:{authorization:"Bearer "+"y".repeat(40)}}),env,helpers);
  assert.equal(result.status,200);assert.match((await result.json()).actions[0].hints,/comunicado/);
 }finally{globalThis.fetch=old;}
}));
