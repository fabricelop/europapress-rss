import test from "node:test";
import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import worker from "../src/index.js";

const origin="https://v2-private.example.workers.dev";
const ID="trv2-e94b2984c087ac403753b8c1";
const REV=1;
const raw=Buffer.alloc(175000,93);
Buffer.from([137,80,78,71,13,10,26,10]).copy(raw,0);
const sha=createHash("sha256").update(raw).digest("hex");
const path="v2/ttendencias/generated-images/"+ID+"-r1-"+sha.slice(0,24)+".png";
const cmd="v2-img-"+ID+"-r1-a1-0123456789abcdef";
const AUTH_PASSWORD="sample-v2-password-long-enough";
const env={
 AUTH_PASSWORD,
 SESSION_SECRET:"v2-test-cookie-signing-secret-longer-than-32-chars",
 SESSION_HOURS:"720",ASSETS:{fetch:async()=>new Response("private v2")}
};
function ledger(override={}){
 return {step:"04_editorial_queue",effects_enabled:false,items:{
 [ID]:{trend_id:ID,revision:REV,status:"captured_review",capture:{
  revision:REV,answer:"Explicación validada sin publicación.",sha256:"f".repeat(64),
  image:{status:"saved",revision:REV,backend:"github_v1_style",command_id:cmd,
   sha256:sha,path,mime:"image/png",...override}}}}};
}
async function authorized(){
 const login=await worker.fetch(new Request(origin+"/api/login",{method:"POST",
   headers:{"origin":origin,"x-ttv2-action":"1","content-type":"application/json"},
   body:JSON.stringify({password:AUTH_PASSWORD})}),env);
 assert.equal(login.status,200);
 return login.headers.get("set-cookie").split(";")[0];
}
test("original image from GitHub is only served via authenticated V2 session",async()=>{
 const fetchBefore=globalThis.fetch, cookie=await authorized();
 let requests=[];
 try{
  globalThis.fetch=async url=>{
   requests.push(String(url));
   if(String(url).endsWith("editorial-queue.json"))return Response.json(ledger());
   if(String(url).endsWith(path))return new Response(raw,{status:200});
   return new Response("not found",{status:404});
  };
  const anon=await worker.fetch(new Request(origin+"/api/image/"+ID+"?revision=1"),env);
  assert.equal(anon.status,401);
  assert.equal(requests.length,0);
  const response=await worker.fetch(new Request(origin+"/api/image/"+ID+"?revision=1",
    {headers:{"cookie":cookie}}),env);
  assert.equal(response.status,200);
  assert.equal(response.headers.get("content-type"),"image/png");
  assert.equal(Buffer.compare(Buffer.from(await response.arrayBuffer()),raw),0);
  assert.ok(requests.some(x=>x.includes("/feature/ttactualidad-v2-clean/")&&x.endsWith(path)));
 }finally{globalThis.fetch=fetchBefore;}
});
test("V2 never serves image attached to wrong editorial revision or wrong SHA",async()=>{
 const fetchBefore=globalThis.fetch, cookie=await authorized();
 try{
  globalThis.fetch=async url=>String(url).endsWith("editorial-queue.json")?
   Response.json(ledger({revision:2})):new Response(raw);
  let response=await worker.fetch(new Request(origin+"/api/image/"+ID+"?revision=1",
   {headers:{"cookie":cookie}}),env);
  assert.equal(response.status,404);
  globalThis.fetch=async url=>String(url).endsWith("editorial-queue.json")?
   Response.json(ledger({sha256:"0".repeat(64)})):new Response(raw);
  response=await worker.fetch(new Request(origin+"/api/image/"+ID+"?revision=1",
   {headers:{"cookie":cookie}}),env);
  assert.equal(response.status,409);
 }finally{globalThis.fetch=fetchBefore;}
});
test("V2 image path from editorial ledger cannot point outside fixed generated-images folder",async()=>{
 const fetchBefore=globalThis.fetch, cookie=await authorized();
 try{
  globalThis.fetch=async url=>String(url).endsWith("editorial-queue.json")?
   Response.json(ledger({path:"https://evil.example/image.png"})):new Response(raw);
  const response=await worker.fetch(new Request(origin+"/api/image/"+ID+"?revision=1",
   {headers:{"cookie":cookie}}),env);
  assert.equal(response.status,409);
 }finally{globalThis.fetch=fetchBefore;}
});
