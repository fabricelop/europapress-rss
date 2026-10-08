import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";
import worker,{handlerRequest,parseTtiCallback} from "../src/index.js";
import sharp from "../src/compat/sharp.js";

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),"..");

test("original TTiTTulares PWA and handlers staged (no replacement UI)",()=>{
  for(const file of [
    "generated/assets/ttittulares/index.html",
    "generated/assets/ttittulares/sw.js",
    "generated/assets/ttittulares/manifest.webmanifest",
    "generated/lib/ttittulares-control-handler.js",
    "generated/lib/ttittulares-run-handler.js",
    "generated/lib/ttittulares-run-status-handler.js",
    "generated/lib/ttittulares-remate-ratings.js"
  ]) assert.ok(fs.statSync(path.join(root,file)).isFile(),file);
  const html=fs.readFileSync(path.join(root,"generated/assets/ttittulares/index.html"),"utf8");
  assert.match(html,/ttittulares-control-token/);
  assert.match(html,/canvas\.toBlob/);
  assert.match(html,/api\/ttittulares-run/);
});

test("Cloudflare health independent from Vercel and PC",async()=>{
  const r=await worker.fetch(new Request("https://tt.example/health"),{});
  assert.equal(r.status,200);
  assert.equal((await r.json()).ok,true);
});

test("unauthorized publication/dismissal rejected",async()=>{
  for(const action of ["published","dismiss","submit"]){
    const r=await worker.fetch(new Request("https://tt.example/api/ttittulares-control",{
      method:"POST",
      headers:{"content-type":"application/json","authorization":"Bearer invalid-token"},
      body:JSON.stringify({action,event_id:"test",title:"test"})
    }),{});
    assert.equal(r.status,401,action);
  }
});
test("no unauthenticated editorial or image operation",async()=>{
  const r=await worker.fetch(new Request("https://tt.example/api/ttittulares-run",{
    method:"POST",headers:{"content-type":"application/json"},body:'{"task":"editorial"}'
  }),{});
  assert.equal(r.status,401);
});

test("reject invalid JSON and oversized requests",async()=>{
  const invalid=await worker.fetch(new Request("https://tt.example/api/ttittulares-run",{
    method:"POST",body:"not-json"
  }),{});
  assert.equal(invalid.status,400);
  const tooBig=await worker.fetch(new Request("https://tt.example/api/ttittulares-control",{
    method:"POST",headers:{"content-length":"7000000"},body:"{}"
  }),{});
  assert.equal(tooBig.status,413);
});

test("status adapter preserves query/status and response",async()=>{
  const url=new URL("https://tt.example/api/ttittulares-run-status?view=image-job&id=abc");
  const r=await handlerRequest(new Request(url),{},url,(req,res)=>
    res.status(409).json({ok:false,view:req.query.view,id:req.query.id})
  );
  assert.equal(r.status,409);
  assert.deepEqual(await r.json(),{ok:false,view:"image-job",id:"abc"});
});

test("assets route serves the original PWA",async()=>{
  let opened="";
  const r=await worker.fetch(new Request("https://tt.example/ttittulares/"),{
    ASSETS:{fetch:async req=>{opened=req.url;return new Response("<html/>",{status:200})}}
  });
  assert.equal(r.status,200);
  assert.ok(opened.endsWith("/ttittulares/"));
});

test("ImageGen PNG and JPEG metadata are checked without native sharp",async()=>{
  const png=Buffer.alloc(30);
  Buffer.from([137,80,78,71,13,10,26,10]).copy(png);
  png.write("IHDR",12,"ascii");
  png.writeUInt32BE(1280,16);
  png.writeUInt32BE(720,20);
  assert.deepEqual((await sharp(png).metadata()).width,1280);
  const jpeg=Buffer.from([0xff,0xd8,0xff,0xc0,0,0x0b,0x08,0x02,0xd0,0x05,0,0x03,0x01,0x11,0,0xff,0xd9]);
  assert.equal((await sharp(jpeg).metadata()).height,720);
});

test("TTendencias and webhook are never routed through this Worker",async()=>{
  for(const url of ["/api/ttendencias-run","/api/telegram-webhook"]){
    const r=await worker.fetch(new Request("https://tt.example"+url),{});
    assert.equal(r.status,404,url);
  }
});


test("parse legitimate Telegram buttons without persisting private chat identifiers",()=>{
 const original={update_id:218637913,callback_query:{
   id:"19298918471234567",data:"tt:p:47e946414bab",
   message:{message_id:3031,chat:{id:-1002345678910}}
 }};
 const row=parseTtiCallback(original);
 assert.equal(row.text,"ttp|47e946414bab");
 assert.equal(row.message_id,3031);
 assert.equal(row.source,"ttittulares_cloudflare_callback_v1");
 assert.equal(Object.hasOwn(row,"chat_id"),false);
 original.callback_query.data="tt:d:47e946414bab";
 assert.equal(parseTtiCallback(original).text,"ttd|47e946414bab");
 original.callback_query.data="tt:x:47e946414bab";
 assert.equal(parseTtiCallback(original),null);
 original.callback_query.data="tt:p:../../not-allowed";
 assert.equal(parseTtiCallback(original),null);
});
test("only real callback-shaped updates enter the queue; no token never accepts them",async()=>{
 const payload={update_id:218637913,callback_query:{
  id:"19298918471234567",data:"tt:p:47e946414bab",
  message:{message_id:3031,chat:{id:-1002345678910}}
 }};
 const r=await worker.fetch(new Request("https://tt.example/api/ttittulares-telegram-callback",{
  method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify(payload)
 }),{});
 assert.equal(r.status,503);
 const missing=await worker.fetch(new Request("https://tt.example/api/ttittulares-telegram-callback",{
  method:"POST",body:JSON.stringify({update_id:123})
 }),{});
 assert.equal(missing.status,200);
 assert.equal((await missing.json()).ignored,true);
});
