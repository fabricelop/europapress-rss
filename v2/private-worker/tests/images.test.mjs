import test from "node:test";
import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import worker from "../src/index.js";

const origin="https://v2-private.example.workers.dev";
const id="trv2-e94b2984c087ac403753b8c1",revision=1;
const explanation="Explicación completa y aprobada: Jordi Wild y una silla vacía.";
const sha=b=>createHash("sha256").update(b).digest("hex");
const command="v2-img-"+id+"-r1-a1-0123456789abcdef";
const raster=Buffer.alloc(150000,18);
Buffer.from([137,80,78,71,13,10,26,10]).copy(raster,0);
const rasterHash=sha(raster);
const row={trend_id:id,revision,status:"explicada",explanation,entered_top30_at:"2026-11-14T00:00:00Z"};
const nativeFetch=globalThis.fetch;
function mockEnv(){
 const images=new Map(), keys=new Map();
 return {AUTH_PASSWORD:"long-enough-private-test-password",SESSION_SECRET:"unit-test-session-secret-is-at-least-32-chars-long",
  IMAGE_INGEST_SECRET:"unit-test-image-ingest-secret-32-bytes-long",SESSION_HOURS:"720",
  ASSETS:{fetch:async()=>new Response("ok")},
  V2_IMAGES:{
   async put(key,bytes){images.set(key,bytes);return {}},
   async get(key){return images.has(key)?{body:images.get(key),etag:"etag"}:null}
  },
  MARKS_DB:{
   prepare(query){
    let values=[];return {
     bind(...v){values=v;return this;},
     async first(){
      if(query.startsWith("SELECT command_id"))return keys.get(values.join(":"))||null;
      if(query.startsWith("SELECT r2_key"))return keys.get(values.join(":"))||null;
      throw Error("UNEXPECTED SELECT");
     },
     async run(){
      if(!query.startsWith("INSERT INTO v2_images"))throw Error("UNEXPECTED QUERY");
      const [trendId,rev,cmd,editorial,hash,key,mime,bytes,width,height]=values;
      keys.set([trendId,rev].join(":"),{command_id:cmd,raster_sha256:hash,r2_key:key,content_type:mime});
      return {success:true};
     }
    };
   }
  },stored:{images,keys}};
}
function req(body,overrides={}){
 const headers={"x-ttv2-image-ingest":"unit-test-image-ingest-secret-32-bytes-long",
 "x-ttv2-trend-id":id,"x-ttv2-revision":"1","x-ttv2-command-id":command,
 "x-ttv2-editorial-sha256":sha(explanation),"x-ttv2-raster-sha256":rasterHash,
 "x-ttv2-width":"1254","x-ttv2-height":"1254","content-type":"image/png",...overrides};
 return new Request(origin+"/api/image-ingest",{method:"POST",headers,body});
}
test("ImageGen original stored once by immutable trend, revision, command and editorial SHA",async()=>{
 const env=mockEnv();
 try{
 globalThis.fetch=async()=>Response.json({step:"04_editorial_queue",effects_enabled:false,items:{[id]:{trend_id:id,revision:1,status:"captured_review",capture:{revision:1,answer:explanation}}}});
 let res=await worker.fetch(req(raster),env);assert.equal(res.status,200);assert.equal((await res.json()).status,"saved");
 assert.equal(env.stored.images.size,1);
 res=await worker.fetch(req(raster),env);assert.equal(res.status,200);assert.equal((await res.json()).status,"already_saved");
 res=await worker.fetch(req(raster,{"x-ttv2-command-id":"v2-img-"+id+"-r1-a2-0123456789abcdef"}),env);
 assert.equal(res.status,409);
 }finally{globalThis.fetch=nativeFetch;}
});
test("ImageGen original rejects wrong secret, wrong editorial fingerprint and tiny thumbnail",async()=>{
 const env=mockEnv();
 try{
 globalThis.fetch=async()=>Response.json({step:"04_editorial_queue",effects_enabled:false,items:{[id]:{trend_id:id,revision:1,status:"captured_review",capture:{revision:1,answer:explanation}}}});
 assert.equal((await worker.fetch(req(raster,{"x-ttv2-image-ingest":"wrong"}),env)).status,403);
 assert.equal((await worker.fetch(req(raster,{"x-ttv2-editorial-sha256":"a".repeat(64)}),env)).status,409);
 assert.equal((await worker.fetch(req(raster.subarray(0,3316),{"x-ttv2-raster-sha256":sha(raster.subarray(0,3316))}),env)).status,413);
 assert.equal(env.stored.images.size,0);
 }finally{globalThis.fetch=nativeFetch;}
});

test("same-chat preflight is secret-scoped and refuses missing R2",async()=>{
 const env=mockEnv();
 const request=secret=>new Request(origin+"/api/image-ingest-ready",{
   headers:{"x-ttv2-image-ingest":secret}});
 let response=await worker.fetch(request("wrong"),env);
 assert.equal(response.status,403);
 response=await worker.fetch(request(env.IMAGE_INGEST_SECRET),env);
 assert.equal(response.status,200);
 assert.equal((await response.json()).storage,"ready");
 delete env.V2_IMAGES;
 response=await worker.fetch(request(env.IMAGE_INGEST_SECRET),env);
 assert.equal(response.status,503);
});
