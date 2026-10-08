import test from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";

test("Meta preflight endpoint denies unauthenticated requests",async()=>{
 const r=await worker.fetch(new Request("https://example.test/meta-preflight"),{});
 assert.equal(r.status,401);
});
test("Configured Page and linked Instagram verify with GET only, never publish",async()=>{
 const prev=globalThis.fetch;
 let calls=0;
 globalThis.fetch=async(url,options)=>{
  calls++;
  assert.equal(options.method,"GET");
  const path=new URL(url).pathname;
  if(path.endsWith("/me"))return Response.json({id:"1424696600717440"});
  return Response.json({id:"1424696600717440",instagram_business_account:{id:"17841414511690117",username:"ttactualidad"}});
 };
 const env={INSTAGRAM_INTERNAL_SECRET:"test-authorization-value-more-than-32-chars",INSTAGRAM_PAGE_ACCESS_TOKEN:"test-only",INSTAGRAM_USER_ID:"17841414511690117",IG_DB:{prepare(){return {first:async()=>({name:"instagram_posts"})}}}};
 try{
   const r=await worker.fetch(new Request("https://example.test/meta-preflight",{headers:{authorization:"Bearer "+env.INSTAGRAM_INTERNAL_SECRET}}),env);
   assert.equal(r.status,200);
   const body=await r.json();
   assert.equal(body.ok,true);
   assert.equal(body.read_only,true);
   assert.equal(body.active,false);
   assert.equal(calls,2);
 }finally{globalThis.fetch=prev}
});
