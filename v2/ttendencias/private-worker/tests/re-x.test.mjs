import test from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";

const origin="https://v2-private.example.workers.dev";
const id="trv2-1234567890abcdef12345678",stamp="2026-11-15T13:02:00Z";
const password="An-example-long-unique-password-12345";
const env={AUTH_PASSWORD:password,SESSION_SECRET:"an-example-super-secret-longer-than-32-chars-for-tests-only",
  SESSION_HOURS:"720",ASSETS:{fetch:async()=>new Response("ok")}};
globalThis.fetch=async()=>new Response(JSON.stringify({
  project:"ttactualidad-v2",count:1,items:[{trend_id:id,revision:1,entered_top30_at:stamp,status:"explicada",re_in_progress:false}]}));

function database(){
 const requests=[],hints=[];
 return {requests,hints,prepare(sql){
   let args=[];
   return {bind(...p){args=p;return this;},
     async run(){
       if(sql.includes("INSERT INTO re_x_context")){hints.push({trend_id:args[0],base_revision:args[1],hints:args[2]});return {success:true}}
       if(sql.includes("INSERT INTO re_requests")){requests.push({trend_id:args[0],base_revision:args[1],status:"requested"});return {success:true}}
       if(sql.includes("CREATE TABLE IF NOT EXISTS"))return {success:true};
       throw Error("Unexpected SQL: "+sql);
     },
     async all(){
       if(sql.includes("FROM re_requests"))return {results:requests};
       if(sql.includes("FROM re_x_context"))return {results:hints};
       if(sql.includes("FROM image_suppressions")||sql.includes("FROM public_image_prefs"))return {results:[]};
       throw Error("Unexpected select: "+sql);
     }
   };
 }};
}
async function login(){
 const response=await worker.fetch(new Request(origin+"/api/login",{method:"POST",
   headers:{origin,"x-ttv2-action":"1","content-type":"application/json"},
   body:JSON.stringify({password})}),env);
 assert.equal(response.status,200);return response.headers.get("set-cookie").split(";")[0];
}
function req(cookie,body){
 return new Request(origin+"/api/re-explain",{method:"POST",
  headers:{cookie,origin,"x-ttv2-action":"1","content-type":"application/json"},
  body:JSON.stringify(body)});
}
test("RE-X demands substantial user hints and preserves mode",async()=>{
 const db=database(),cookie=await login(),bound={...env,MARKS_DB:db};
 const payload={trend_id:id,revision:1,entered_top30_at:stamp,mode:"x",hints:"Vídeo comentado hoy: buscar las respuestas y el hashtag relevante"};
 assert.equal((await worker.fetch(req(cookie,{...payload,hints:"corto"}),bound)).status,400);
 const applied=await worker.fetch(req(cookie,payload),bound);
 assert.equal(applied.status,202);
 assert.equal((await applied.json()).mode,"x");
 assert.equal(db.requests.length,1);assert.equal(db.hints.length,1);
 const publicView=await (await worker.fetch(new Request(origin+"/api/public-editorial-overrides"),bound)).json();
 assert.equal(publicView.re.length,1);
 assert.equal(publicView.re[0].mode,"x");
 assert.equal(publicView.re[0].hints,payload.hints);
});
