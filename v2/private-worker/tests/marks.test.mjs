import test from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";

const origin="https://v2-private.example.workers.dev";
const pass="An-example-long-unique-password-12345";
const env={
 AUTH_PASSWORD:pass,
 SESSION_SECRET:"an-example-super-secret-longer-than-32-chars-for-tests-only",
 SESSION_HOURS:"720",
 ASSETS:{fetch:async()=>new Response("ok")}
};
function fakeDB(){
 const db=new Map();
 return {
  db,
  prepare(sql){
   let args=[];
   return {
    bind(...values){args=values;return this;},
    async all(){assert.match(sql,/SELECT trend_id/);return {results:[...db.entries()].map(([trend_id,entered_top30_at])=>({trend_id,entered_top30_at}))};},
    async run(){
     if(sql.startsWith("DELETE")) {const [id]=args;db.delete(id);}
     else if(sql.startsWith("INSERT")){const [id,stamp]=args;db.set(id,stamp);}
     else throw Error("Unexpected SQL: "+sql);
     return {success:true};
    }
   }
  }
 };
}
const id="trv2-e94b2984c087ac403753b8c1", stamp="2026-11-14T00:00:00Z";
let top30=[{trend_id:id,entered_top30_at:stamp}];
globalThis.fetch=async()=>new Response(JSON.stringify({project:"ttactualidad-v2",count:top30.length,items:top30}),{status:200});
async function loggedIn(){
 const response=await worker.fetch(new Request(origin+"/api/login",{method:"POST",headers:{origin,"x-ttv2-action":"1","content-type":"application/json"},body:JSON.stringify({password:pass})}),env);
 assert.equal(response.status,200);
 return response.headers.get("set-cookie").split(";")[0];
}
function req(path,cookie,body){
 return new Request(origin+path,{
  method:body?"POST":"GET",
  headers:{"cookie":cookie,...(body?{origin,"x-ttv2-action":"1","content-type":"application/json"}:{})},
  ...(body?{body:JSON.stringify(body)}:{})
 });
}
test("R mark is shared and survives source-date changes, a Top30 exit and reentry",async()=>{
 const storage=fakeDB(), bound={...env,MARKS_DB:storage};
 const a=await loggedIn(),b=await loggedIn();
 const marked={trend_id:id,entered_top30_at:stamp,marked:true};
 assert.equal((await worker.fetch(req("/api/marks",a,marked),bound)).status,200);
 let res=await worker.fetch(req("/api/marks",b),bound);
 assert.equal((await res.json()).marks[id],stamp);
 // A temporarily missing trend must not erase the user's stored red mark.
 top30=[{trend_id:"trv2-000000000000000000000001",entered_top30_at:"2026-11-14T01:00:00Z"}];
 res=await worker.fetch(req("/api/marks",a),bound);
 assert.equal((await res.json()).marks[id],stamp);
 assert.equal(storage.db.has(id),true);
 // La ficha pudo quedar abierta mientras Top30 se actualizaba.
 assert.equal((await worker.fetch(req("/api/marks",a,{...marked,marked:false}),bound)).status,200);
 assert.equal(storage.db.has(id),false);
 assert.equal((await worker.fetch(req("/api/marks",a,marked),bound)).status,200);
 assert.equal(storage.db.has(id),true);
 top30=[{trend_id:id,entered_top30_at:"2026-11-14T02:00:00Z"}];
 res=await worker.fetch(req("/api/marks",b),bound);
 assert.equal((await res.json()).marks[id],stamp);
 assert.equal((await worker.fetch(req("/api/marks",b,marked),bound)).status,200);
 const removed=await worker.fetch(req("/api/marks",b,{trend_id:id,entered_top30_at:stamp,marked:false}),bound);
 assert.equal(removed.status,200);
 assert.equal(storage.db.has(id),false);
});
test("R rejects anonymous, cross-origin, and unbound storage; fail closed",async()=>{
 const cookie=await loggedIn();
 const storage=fakeDB(),bound={...env,MARKS_DB:storage};
 assert.equal((await worker.fetch(req("/api/marks",""),bound)).status,401);
 assert.equal((await worker.fetch(req("/api/marks",cookie),env)).status,503);
 const bad=req("/api/marks",cookie,{trend_id:id,entered_top30_at:stamp,marked:true});
 bad.headers.set("origin","https://foreign.example");
 assert.equal((await worker.fetch(bad,bound)).status,405);
});
