import test from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";

const origin="https://v2-private.example.workers.dev";
const id="trv2-1234567890abcdef12345678";
const password="a-long-test-only-secret-password";
const env={AUTH_PASSWORD:password,SESSION_SECRET:"long-test-session-secret-for-authentication-1234",
  ASSETS:{fetch:async()=>new Response("ok")}};
let current={project:"ttactualidad-v2",count:1,items:[{trend_id:id,revision:2,
  name:"Aday Mara",status:"incidencia",editorial_status:"capture_recovery"}]};
globalThis.fetch=async()=>Response.json(current);
function storage(){
 const incidents=[],retries=[];
 return {incidents,retries,prepare(sql){let args=[];return {bind(...p){args=p;return this;},
  async run(){
   if(sql.includes("INSERT INTO incident_rex_requests")&&!incidents.some(x=>x.trend_id===args[0]&&x.base_revision===args[1]))
    incidents.push({trend_id:args[0],base_revision:args[1],hints:args[2]});
   else if(sql.includes("INSERT INTO incident_retry_requests")&&!retries.some(x=>x.trend_id===args[0]&&x.base_revision===args[1]))
    retries.push({trend_id:args[0],base_revision:args[1],instructions:args[2]});
   else if(!sql.includes("INSERT INTO incident_rex_requests")&&!sql.includes("INSERT INTO incident_retry_requests"))assert.match(sql,/CREATE TABLE/);
   return {success:true};
  },
  async all(){
   if(sql.includes("FROM incident_rex_requests"))return {results:incidents};
   if(sql.includes("FROM incident_retry_requests"))return {results:retries};
   if(sql.includes("FROM "))return {results:[]};
   throw Error("Unexpected SQL");
  }
 };}};
}
async function session(){
 const response=await worker.fetch(new Request(origin+"/api/login",{method:"POST",headers:{origin,"x-ttv2-action":"1"},body:JSON.stringify({password})}),env);
 assert.equal(response.status,200);return response.headers.get("set-cookie").split(";")[0];
}
const post=(cookie,hints="Se comenta un vídeo reciente, contrastar en X y prensa",rev=2,site=origin)=>
 new Request(origin+"/api/incident-rex",{method:"POST",headers:{cookie,origin:site,"x-ttv2-action":"1","content-type":"application/json"},
  body:JSON.stringify({trend_id:id,revision:rev,hints})});

test("incident RE-X records user hints without resetting or sending any editorial job",async()=>{
 const db=storage(),cookie=await session(),bound={...env,MARKS_DB:db};
 assert.equal((await worker.fetch(post(cookie,"corto"),bound)).status,400);
 assert.equal((await worker.fetch(post(""),bound)).status,401);
 assert.equal((await worker.fetch(post(cookie,undefined,2,"https://evil.example"),bound)).status,405);
 assert.equal((await worker.fetch(post(cookie),bound)).status,202);
 assert.equal((await worker.fetch(post(cookie),bound)).status,202);
 assert.equal(db.incidents.length,1);
 assert.deepEqual(db.retries,[{trend_id:id,base_revision:2,instructions:""}]);
 const publicData=await (await worker.fetch(new Request(origin+"/api/public-editorial-overrides"),bound)).json();
 assert.deepEqual(publicData.incident_rex,db.incidents);
 assert.deepEqual(publicData.re,[]);
 const privateData=await (await worker.fetch(new Request(origin+"/api/incident-rex",{headers:{cookie}}),bound)).json();
 assert.equal(privateData.requests.length,1);
 current={...current,items:[{...current.items[0],status:"explicada",editorial_status:"captured_review"}]};
 assert.equal((await worker.fetch(post(cookie,"Otra pista válida para investigar",3),bound)).status,409);
 assert.equal(db.incidents.length,1);
});

test("manual incident retry is idempotent and never sends or modifies the old chat",async()=>{
 current={...current,items:[{...current.items[0],status:"incidencia",editorial_status:"in_progress"}]};
 const db=storage(),cookie=await session(),bound={...env,MARKS_DB:db};
 const request=(revision=2,site=origin,token=cookie)=>new Request(origin+"/api/incident-retry",
  {method:"POST",headers:{cookie:token,origin:site,"x-ttv2-action":"1","content-type":"application/json"},
   body:JSON.stringify({trend_id:id,revision})});
 assert.equal((await worker.fetch(request(2,origin,""),bound)).status,401);
 assert.equal((await worker.fetch(request(2,"https://evil.example"),bound)).status,405);
 assert.equal((await worker.fetch(request(3),bound)).status,409);
 assert.equal((await worker.fetch(request(),bound)).status,202);
 assert.equal((await worker.fetch(request(),bound)).status,202);
 assert.deepEqual(db.retries,[{trend_id:id,base_revision:2,instructions:""}]);
 const publicData=await (await worker.fetch(new Request(origin+"/api/public-editorial-overrides"),bound)).json();
 assert.deepEqual(publicData.incident_retry,db.retries);
 const privateData=await (await worker.fetch(new Request(origin+"/api/incident-retry",{headers:{cookie}}),bound)).json();
 assert.deepEqual(privateData.requests,[{trend_id:id,base_revision:2,instructions:""}]);
});
