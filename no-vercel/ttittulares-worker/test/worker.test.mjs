import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";
import worker,{handlerRequest,parseTtiCallback,linkedTtiTelegramMessages} from "../src/index.js";
import sharp from "../src/compat/sharp.js";
import {generateKeyPairSync,publicEncrypt,constants} from "node:crypto";

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),"..");

test("original TTiTTulares PWA and handlers staged (no replacement UI)",()=>{
  for(const file of [
    "generated/assets/ttittulares/index.html",
    "generated/assets/tt-shared/gag-actions.js",
    "generated/assets/tt-shared/gag-actions.css",
    "generated/assets/tt-shared/gag-copy.html",
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
  assert.match(html,/tt-shared\/gag-actions\.js/);
  const source=fs.readFileSync(path.join(root,"generated/assets/tt-shared/gag-actions.js"),"utf8");
  assert.match(source,/Copiar prompt GAG/);
  assert.match(source,/Chat Images/);
  assert.match(source,/Copiar en X/);
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

test("Telegram closure only touches message IDs from the verified event",()=>{
  const deliveries=[
    {event_id:"A12345",telegram_message_id:3075,archive_telegram_message_id:3074,cross_quote_message_id:3073},
    {event_id:"A12345",telegram_message_id:3079,archive_telegram_message_id:3078},
    {event_id:"B98765",telegram_message_id:3081,archive_telegram_message_id:3080}
  ];
  assert.deepEqual(linkedTtiTelegramMessages(deliveries,"A12345",3079),[3075,3074,3073,3079,3078]);
  assert.throws(()=>linkedTtiTelegramMessages(deliveries,"A12345",3081),/Unlinked/);
});

test("retired Telegram publication/dismissal callbacks never change state",async()=>{
  const botToken="123456789:"+("AbCd0123456789efGHijKLmnOPqrSTuvWxYz");
  const {publicKey,privateKey}=generateKeyPairSync("rsa",{modulusLength:2048});
  const ciphertext=publicEncrypt({key:publicKey,padding:constants.RSA_PKCS1_OAEP_PADDING,oaepHash:"sha256"},Buffer.from(botToken)).toString("base64");
  const key=privateKey.export({type:"pkcs8",format:"der"}).toString("base64");
  const eId="a1b2c3d4e5f6";
  const inbox={version:1,requests:[]};
  const deliveries={items:[
    {event_id:eId,status:"sent",telegram_message_id:3075,archive_telegram_message_id:3074},
    {event_id:eId,status:"sent",telegram_message_id:3079,archive_telegram_message_id:3078},
    {event_id:"not-this-one",status:"sent",telegram_message_id:3081}
  ]};
  let decisions={project:"TTiTTulares",items:[]};
  let savedInbox=null;
  const deleted=[];
  const encoded=doc=>Buffer.from(JSON.stringify(doc)).toString("base64");
  const originalFetch=globalThis.fetch;
  globalThis.fetch=async (url,opts={})=>{
    const u=String(url),method=String(opts.method||"GET");
    if(u.includes("/telegram-bot-token.enc.json"))
      return Response.json({content:encoded({algorithm:"RSA-OAEP-SHA256",ciphertext})});
    if(u.includes("/telegram/ttittulares-callback-inbox.json")){
      if(method==="PUT"){savedInbox=JSON.parse(Buffer.from(JSON.parse(opts.body).content,"base64").toString("utf8"));return Response.json({ok:true});}
      return Response.json({sha:"test-inbox-sha",content:encoded(inbox)});
    }
    if(u.includes("/telegram/ttittulares-deliveries.json"))
      return Response.json({content:encoded(deliveries)});
    if(u.includes("/ttittulares/decisions.json")){
      if(method==="PUT"){
        decisions=JSON.parse(Buffer.from(JSON.parse(opts.body).content,"base64").toString("utf8"));
        return Response.json({ok:true});
      }
      return Response.json({sha:"test-decisions-sha",content:encoded(decisions)});
    }
    if(u.includes("/answerCallbackQuery"))return Response.json({ok:true,result:true});
    if(u.includes("/deleteMessage")){
      deleted.push(JSON.parse(opts.body).message_id);
      return Response.json({ok:true,result:true});
    }
    throw Error("Unexpected mocked fetch "+u);
  };
  try{
    const update={update_id:218639001,callback_query:{
      id:"7650439579279999999",data:"tt:d:"+eId,
      message:{message_id:3075,chat:{id:-1002345678910}}
    }};
    const response=await worker.fetch(new Request("https://tt.example/api/ttittulares-telegram-callback",{
      method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify(update)
    }),{GITHUB_TOKEN:"test-github-token",TTITTULARES_CALLBACK_DECRYPT_KEY:key});
    const result=await response.json();
    assert.equal(response.status,410);
    assert.match(result.error,/retired/);
    assert.deepEqual(decisions.items,[]);
    assert.equal(savedInbox,null);
    assert.deepEqual(deleted,[]);
  }finally{globalThis.fetch=originalFetch;}
});


test("relay de propuesta Telegram no acepta peticiones sin bot verificado",async()=>{
  const response=await worker.fetch(new Request(
    "https://tt.example/api/ttittulares-telegram-user-proposal",{
      method:"POST",
      headers:{"content-type":"application/json"},
      body:JSON.stringify({update_id:111,text:"Investigar esta noticia"})
    }
  ),{});
  assert.notEqual(response.status,200);
});
