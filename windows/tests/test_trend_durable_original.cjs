"use strict";
const assert=require("node:assert/strict");
const {test}=require("node:test");
const fs=require("node:fs"),path=require("node:path"),os=require("node:os"),crypto=require("node:crypto");
const consumer=require("../TTendenciasWebImages.cjs");
const task={target_id:"trendABC",command_id:"tr-img-test-r0",revision:0,
 explanation_sha256:crypto.createHash("sha256").update("Texto editorial vigente").digest("hex")};
test("Trend ImageGen original saved once with exact editorial identity",()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),"tt-trend-image-"));
 try{
  const raw=Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),Buffer.alloc(14000,55)]);
  const dataUrl="data:image/png;base64,"+raw.toString("base64");
  const stored=consumer.cacheRaster(task,{ready:true,dataUrl,width:1536,height:864},dir);
  assert.equal(stored.dataUrl,dataUrl);
  assert.equal(stored.sha256,crypto.createHash("sha256").update(raw).digest("hex"));
  assert.equal(consumer.loadCachedOriginal(task,dir).source,"durable_local");
  assert.throws(()=>consumer.loadCachedOriginal({...task,revision:1},dir),/original_context_mismatch/);
  assert.throws(()=>consumer.loadCachedOriginal({...task,target_id:"other"},dir),/original_context_mismatch/);
  assert.throws(()=>consumer.loadCachedOriginal({...task,explanation_sha256:"a".repeat(64)},dir),/original_context_mismatch/);
  const file=path.join(dir,task.command_id+"-"+stored.sha256+".png");
  fs.appendFileSync(file,"mutated");
  assert.throws(()=>consumer.loadCachedOriginal(task,dir),/original_bytes_integrity_failed/);
 }finally{fs.rmSync(dir,{recursive:true,force:true});}
});
test("Trend receiver captures locally before Cloudflare and preserves Site hook",()=>{
 const src=fs.readFileSync(path.join(__dirname,"..","TTendenciasWebImages.cjs"),"utf8");
 const capture=src.slice(src.indexOf("async function consume(task){"),src.indexOf("async function telemetry(task,result){"));
 assert(capture.indexOf("raster=cacheRaster(task,raster)")<capture.lastIndexOf("view=web-image-contract"));
 assert(capture.includes("if(saved)return deliverSavedTrendOriginal(task,saved)"));
 assert(capture.includes("sendSiteReturnFromPublisher(cdp,task,fresh)"));
 assert(src.includes("recoverSiteAfterUpload(task,job)"));
 assert(src.includes("needs_review_preserved_original"));
 assert(!src.includes("status:'expired',reason:'image_not_confirmed_within_72h',secret_dpapi:undefined"));
 assert(!src.includes("Input.insertText"));
});
