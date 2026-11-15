import test from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";

const origin="https://v2-private.example.workers.dev";
const id="trv2-1234567890abcdef12345678", stamp="2026-11-15T13:02:00Z";
const pass="An-example-long-unique-password-12345";
const env={AUTH_PASSWORD:pass,SESSION_SECRET:"an-example-super-secret-longer-than-32-chars-for-tests-only",SESSION_HOURS:"720",ASSETS:{fetch:async()=>new Response("ok")}};
let item={trend_id:id,revision:1,entered_top30_at:stamp,status:"explicada",re_in_progress:false};
globalThis.fetch=async()=>new Response(JSON.stringify({project:"ttactualidad-v2",count:1,items:[item]}));
function fakeDB(){
 const saved=[];
 return {saved,prepare(sql){let params=[];return {
  bind(...args){params=args;return this;},
  async all(){assert.match(sql,/SELECT trend_id, base_revision/);return {results:saved.map(x=>({trend_id:x[0],base_revision:x[1],status:"requested"}))};},
  async run(){assert.match(sql,/INSERT INTO re_requests/);if(!saved.some(x=>x[0]===params[0]&&x[1]===params[1]))saved.push(params);return {success:true};}
 };}};
}
async function login(){
 const r=await worker.fetch(new Request(origin+"/api/login",{method:"POST",headers:{origin,"x-ttv2-action":"1","content-type":"application/json"},body:JSON.stringify({password:pass})}),env);
 assert.equal(r.status,200);return r.headers.get("set-cookie").split(";")[0];
}
function req(cookie,body,headers={}){
 return new Request(origin+"/api/re-explain",{method:body?"POST":"GET",headers:{cookie,...(body?{origin,"x-ttv2-action":"1","content-type":"application/json"}:{}),...headers},...(body?{body:JSON.stringify(body)}:{})});
}
const payload={trend_id:id,revision:1,entered_top30_at:stamp};
test("RE requires signed session and same-origin POST",async()=>{
 const db=fakeDB(),bound={...env,MARKS_DB:db};
 assert.equal((await worker.fetch(req("",payload),bound)).status,401);
 const cookie=await login();
 assert.equal((await worker.fetch(req(cookie,payload,{origin:"https://evil.example"}),bound)).status,405);
 assert.equal(db.saved.length,0);
});
test("RE queues exactly one request, and rejects obsolete revision",async()=>{
 const db=fakeDB(),bound={...env,MARKS_DB:db},cookie=await login();
 assert.equal((await worker.fetch(req(cookie,payload),bound)).status,202);
 assert.equal((await worker.fetch(req(cookie,payload),bound)).status,202);
 assert.equal(db.saved.length,1);
 const rows=await (await worker.fetch(req(cookie),bound)).json();
 assert.equal(rows.requests[0].trend_id,id);
 assert.equal((await worker.fetch(req(cookie,{...payload,revision:4}),bound)).status,409);
 item={...item,re_in_progress:true};
 assert.equal((await worker.fetch(req(cookie,payload),bound)).status,409);
});
