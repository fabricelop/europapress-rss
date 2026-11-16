import test from "node:test";
import assert from "node:assert/strict";
import {DatabaseSync} from "node:sqlite";
import {deflateSync} from "node:zlib";
import {newsAction,newsControls,newsView,newsManualImage,newsImage} from "../src/news-actions.js";
import {decorateNews,projectNews} from "../src/news.js";
const id="ttn2-"+"a".repeat(24),time="2026-11-16T18:13:24Z",hash="c".repeat(64);
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
test("PUB persistently moves READY to Archive without changing the stored record or publishing",()=>scoped(async(env,docs)=>{
 const original=JSON.stringify(docs[2]);const result=await newsAction(request("archive"),env,helpers);
 assert.equal(result.status,200);assert.equal((await result.json()).publication_sent,false);
 const controls=await newsControls(env);assert.equal(controls.actions[0].action,"archive");
 const view=await newsView(env,new URLSearchParams({state:"archived"}));assert.equal(view.total,1);assert.equal(view.counts.ready,0);
 assert.equal(JSON.stringify(docs[2]),original);
 const replay=await newsAction(request("archive"),env,helpers);assert.equal((await replay.json()).replay,true);
}));
test("RE-X requires useful hints, persists them, hides READY and rejects another current mutation",()=>scoped(async env=>{
 assert.equal((await newsAction(request("rework_x",{hints:"corto"}),env,helpers)).status,400);
 assert.equal((await newsAction(request("rework_x",{hints:"Contrastar el comunicado original en X."}),env,helpers)).status,200);
 const view=await newsView(env,new URLSearchParams({state:"working"}));assert.equal(view.total,1);
 const controls=await newsControls(env);assert.match(controls.actions[0].hints,/comunicado/);
 assert.equal((await newsAction(request("archive",{action_id:"2".repeat(32)}),env,helpers)).status,409);
}));
test("R, image preferences and PU have distinct semantics and never archive or publish",()=>scoped(async env=>{
 for(const [n,action,value] of [[1,"mark",true],[2,"public_image",false],[3,"suppress_image",true],[4,"publication",undefined]]){
  assert.equal((await newsAction(request(action,{action_id:String(n).repeat(32),value}),env,helpers)).status,200);
 }
 const view=await newsView(env,new URLSearchParams({state:"ready"}));assert.equal(view.total,1);
 assert.equal(view.items[0].marked,true);assert.equal(view.items[0].image_suppressed,true);
 assert.equal(view.items[0].public_image_visible,false);
 assert.equal((await newsControls(env)).actions.filter(x=>x.action==="publication").length,1);
}));
test("actions enforce same origin, revision and idempotency identity",()=>scoped(async env=>{
 assert.equal((await newsAction(request("mark",{value:true}),env,{...helpers,sameOrigin:()=>false})).status,405);
 assert.equal((await newsAction(request("archive",{revision:2}),env,helpers)).status,409);
 await newsAction(request("mark",{value:true}),env,helpers);
 assert.equal((await newsAction(request("publication"),env,helpers)).status,409);
}));
test("stale revision preferences never archive or suppress a new record",()=>{
 const [index,queue]=fixture();index.items[id].current_revision=2;queue.items[0].revision=2;queue.items[0].job_id=id+"-r2-editorial";
 const view=decorateNews(projectNews(index,queue),{preferences:[{event_id:id,revision:1,archived:true,image_suppressed:true,marked:true}]});
 assert.equal(view.items[0].group,"ready");assert.equal(view.items[0].image_suppressed,false);assert.equal(view.items[0].marked,true);
});
test("manual image rejects thumbnails and never creates a successful association",()=>scoped(async env=>{
 const req=new Request("https://private.example/api/news-manual-image?id="+id+"&revision=1",{method:"POST",headers:{"content-type":"image/png"},body:new Uint8Array(1024)});
 assert.equal((await newsManualImage(req,env,helpers)).status,413);
 assert.equal((await newsControls(env)).preferences.length,0);
}));
test("manual original association is exact and hidden public image cannot be fetched",()=>scoped(async env=>{
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
 await newsAction(request("public_image",{value:false}),env,helpers);
 assert.equal((await newsImage(imageReq,env,helpers,true)).status,404);
}));
