import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";
import worker,{handlerRequest} from "../src/index.js";
import imageMeta from "../src/compat/sharp.js";

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),"..");

test("complete TTendencias PWA and all 3 original handlers were staged",()=>{
  for(const p of [
    "generated/assets/ttendencias/index.html",
    "generated/assets/tt-shared/gag-actions.js",
    "generated/assets/tt-shared/gag-actions.css",
    "generated/assets/tt-shared/gag-copy.html",
    "generated/assets/ttendencias/explicadas/index.html",
    "generated/assets/ttendencias/preparados/index.html",
    "generated/assets/ttendencias/sw.js",
    "generated/lib/ttendencias-control-handler.js",
    "generated/lib/ttendencias-run-handler.js",
    "generated/lib/ttendencias-run-status-handler.js"
  ]) assert.ok(fs.statSync(path.join(root,p)).isFile(),p);
  const shared=fs.readFileSync(path.join(root,"generated/assets/tt-shared/gag-actions.js"),"utf8");
  assert.match(shared,/Copiar prompt GAG/);
  for(const page of ["explicadas","historico"]){
    const html=fs.readFileSync(path.join(root,"generated/assets/ttendencias",page,"index.html"),"utf8");
    assert.match(html,/canvas\.toBlob/,page);
    assert.doesNotMatch(html,/format=png/,page);
  }
});

test("Cloudflare health stays available if PC and Vercel are unavailable",async()=>{
  const r=await worker.fetch(new Request("https://tt.example/health"),{});
  assert.equal(r.status,200);
  assert.equal((await r.json()).ok,true);
});

test("TTendencias original controls require authentication",async()=>{
  const r=await worker.fetch(new Request("https://tt.example/api/ttendencias-control",{
    method:"POST",
    headers:{"content-type":"application/json","authorization":"Bearer invalid-token"},
    body:JSON.stringify({action:"queue",names:["Ejemplo"]})
  }),{});
  assert.equal(r.status,401);
});

test("TTendencias run cannot be invoked by an unauthorized browser",async()=>{
  const r=await worker.fetch(new Request("https://tt.example/api/ttendencias-run",{
    method:"POST",headers:{"content-type":"application/json"},body:'{"task":"editorial"}'
  }),{});
  assert.equal(r.status,401);
});

test("malformed input and oversize body fail without invoking legacy controllers",async()=>{
  const bad=await worker.fetch(new Request("https://tt.example/api/ttendencias-run",{
    method:"POST",body:"broken"
  }),{});
  assert.equal(bad.status,400);
  const huge=await worker.fetch(new Request("https://tt.example/api/ttendencias-control",{
    method:"POST",headers:{"content-length":"6000000"},body:"{}"
  }),{});
  assert.equal(huge.status,413);
});

test("Node response adapter preserves original endpoint shape and status",async()=>{
  const url=new URL("https://tt.example/api/ttendencias-run-status?view=image-job&id=abc");
  const response=await handlerRequest(
    new Request(url),
    {},
    url,
    (req,res)=>res.setHeader("cache-control","no-store").status(409).json({ok:false,view:req.query.view,id:req.query.id})
  );
  assert.equal(response.status,409);
  assert.deepEqual(await response.json(),{ok:false,view:"image-job",id:"abc"});
});

test("Worker serves original static asset tree, not a read-only replacement",async()=>{
  let opened=null;
  const response=await worker.fetch(new Request("https://tt.example/ttendencias/explicadas/"),{
    ASSETS:{fetch:async req=>{opened=req.url;return new Response("<html/>",{status:200})}}
  });
  assert.equal(response.status,200);
  assert.ok(opened.endsWith("/ttendencias/explicadas/"));
});

test("PNG and JPEG dimensions checked without unsupported sharp native module",async()=>{
  const png=Buffer.alloc(30);Buffer.from([137,80,78,71,13,10,26,10]).copy(png,0);
  png.write("IHDR",12,"ascii");png.writeUInt32BE(1536,16);png.writeUInt32BE(1024,20);
  assert.equal((await imageMeta(png).metadata()).width,1536);
  assert.equal((await imageMeta(png).png().toBuffer()).length,30);
  // JPEG SOF0 marker with 1200 x 800 dimensions.
  const jpg=Buffer.from([0xff,0xd8,0xff,0xc0,0x00,0x0b,0x08,0x03,0x20,0x04,0xb0,0x03,0x01,0x11,0,0xff,0xd9]);
  const m=await imageMeta(jpg).metadata();
  assert.equal(m.width,1200);
  assert.equal(m.height,800);
  await assert.rejects(()=>imageMeta(jpg).png().toBuffer(),/navegador/);
});
