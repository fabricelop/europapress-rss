import test from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";

const origin="https://v2-private.example.workers.dev";
const id="trv2-fedcba9876543210fedcba98";
const password="a-long-test-only-secret-password";
const env={AUTH_PASSWORD:password,SESSION_SECRET:"long-test-session-secret-for-authentication-1234",
  ASSETS:{fetch:async()=>new Response("ok")}};
let status="explicada";
globalThis.fetch=async()=>Response.json({project:"ttactualidad-v2",count:1,
  items:[{trend_id:id,revision:2,name:"Lc 18",status}]});
function storage(){
 const events=[],marks=new Map();
 return {events,marks,async batch(statements){for(const stmt of statements)await stmt.run();return [{success:true},{success:true}];},
  prepare(sql){let args=[];return {bind(...values){args=values;return this;},
  async run(){
   if(sql.includes("INSERT INTO publication_clicks")&&!events.some(x=>x.event_id===args[0]))
    events.push({event_id:args[0],trend_id:args[1],revision:args[2],trend_name:args[3],pressed_at_ms:args[4]});
   else if(sql.includes("INSERT INTO red_marks"))marks.set(args[0],args[1]);
   else if(!sql.includes("INSERT INTO publication_clicks"))assert.match(sql,/CREATE TABLE/);
   return {success:true};
  },
  async all(){assert.match(sql,/FROM publication_clicks/);return {results:events
   .filter(x=>x.pressed_at_ms>args[0]&&x.pressed_at_ms<=args[1])
   .sort((a,b)=>a.pressed_at_ms-b.pressed_at_ms).slice(0,500)};}
 };}};
}
async function session(){
 const response=await worker.fetch(new Request(origin+"/api/login",{method:"POST",headers:{origin,"x-ttv2-action":"1"},body:JSON.stringify({password})}),env);
 assert.equal(response.status,200);return response.headers.get("set-cookie").split(";")[0];
}
const post=(cookie,event_id,trend_id=id)=>new Request(origin+"/api/publication-count",{method:"POST",
 headers:{cookie,origin,"x-ttv2-action":"1","content-type":"application/json"},
 body:JSON.stringify({event_id,trend_id,revision:2})});

test("PU counts manual presses across sessions in an exact rolling 24-hour window",async()=>{
 const db=storage(),bound={...env,MARKS_DB:db},a=await session(),b=await session();
 const old=Date.now()-25*3600000;
 db.events.push({event_id:"old",trend_id:id,revision:2,trend_name:"Lc 18",pressed_at_ms:old});
 assert.equal((await worker.fetch(post("",crypto.randomUUID()),bound)).status,401);
 const uuid=crypto.randomUUID();
 const first=await worker.fetch(post(a,uuid),bound);
 assert.equal(first.status,200);
 assert.equal((await first.json()).marked_red,true);
 assert.ok(db.marks.has(id));
 assert.equal((await worker.fetch(post(a,uuid),bound)).status,200);
 let second=await worker.fetch(post(b,crypto.randomUUID()),bound);
 assert.equal(second.status,200);
 assert.equal((await second.json()).count,2);
 const list=await (await worker.fetch(new Request(origin+"/api/publication-count",{headers:{cookie:a}}),bound)).json();
 assert.equal(list.count,2);
 assert.equal(list.events.length,2);
 assert.equal(list.events[0].trend_name,"Lc 18");
 assert.equal(list.events.some(x=>x.event_id==="old"),false);
 status="incidencia";
 assert.equal((await worker.fetch(post(a,crypto.randomUUID()),bound)).status,409);
 assert.equal(db.events.length,3);
});
