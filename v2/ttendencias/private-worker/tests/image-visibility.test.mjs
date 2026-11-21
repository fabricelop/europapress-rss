import test from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";

const origin="https://v2-private.example.workers.dev";
const id="trv2-1234567890abcdef12345678";
const password="an-example-password-123456789";
const editorial={project:"ttactualidad-v2",country:"ES",count:1,items:[{
  trend_id:id,name:"Concierto",rank:1,revision:1,status:"explicada",
  explanation:"El concierto del grupo se celebra esta noche en Madrid.",image_available:true,
  entered_top30_at:"2026-11-15T16:00:00Z"
}]};

function db(){
 const hidden=[],prefs=[];
 const counters={preferenceScans:0};
 const snapshot={row:null};
 return {hidden,prefs,counters,snapshot,prepare(sql){
  let args=[];
  return {bind(...params){args=params;return this;},
   async run(){
    if(sql.startsWith("INSERT INTO image_suppressions")){
     if(!hidden.some(x=>x.trend_id===args[0]&&x.revision===args[1]))hidden.push({trend_id:args[0],revision:args[1]});
    }else if(sql.startsWith("DELETE FROM image_suppressions"))hidden.splice(0,hidden.length);
    else if(sql.startsWith("INSERT INTO public_image_prefs")){
     prefs.splice(0,prefs.length,{trend_id:args[0],revision:args[1],visible:args[2]});
    }else if(sql.startsWith("INSERT INTO editorial_overrides_snapshot"))snapshot.row={payload:args[0],cached_at_ms:args[1]};
    else if(sql.startsWith("UPDATE editorial_overrides_snapshot")&&snapshot.row)snapshot.row.cached_at_ms=0;
    else assert.match(sql,/CREATE TABLE IF NOT EXISTS|UPDATE editorial_overrides_snapshot/);
    return {success:true};
   },
   async all(){
    if(sql.includes("FROM re_requests"))return {results:[]};
    if(sql.includes("FROM re_x_context"))return {results:[]};
    if(sql.includes("FROM incident_rex_requests"))return {results:[]};
    if(sql.includes("FROM incident_retry_requests"))return {results:[]};
    if(sql.includes("FROM image_suppressions"))return {results:hidden.slice()};
    if(sql.includes("FROM public_image_prefs")){counters.preferenceScans++;return {results:prefs.slice()};}
    throw Error("no radar in fake DB");
   },
   async first(){if(sql.includes("FROM editorial_overrides_snapshot"))return snapshot.row;throw Error("no radar in fake DB");}
  };
 }};
}
const secrets={AUTH_PASSWORD:password,SESSION_SECRET:"this-secret-is-longer-than-thirty-two-characters"};
async function cookie(env){
 const response=await worker.fetch(new Request(origin+"/api/login",{method:"POST",headers:{origin,"x-ttv2-action":"1","content-type":"application/json"},body:JSON.stringify({password})}),env);
 assert.equal(response.status,200);
 return response.headers.get("set-cookie").split(";")[0];
}
function action(session,payload){return new Request(origin+"/api/image-visibility",{method:"POST",headers:{origin,cookie:session,"x-ttv2-action":"1","content-type":"application/json"},body:JSON.stringify(payload)});}
globalThis.fetch=async url=>{
 if(String(url).includes("web-top30.json"))return new Response(JSON.stringify(editorial));
 throw Error("source unavailable in test");
};

test("two independent controls: public switch leaves V2 image intact, remove hides both",async()=>{
 const database=db(),env={...secrets,MARKS_DB:database,ASSETS:{fetch:async()=>new Response("ok")}};
 const session=await cookie(env);
 let response=await worker.fetch(action(session,{trend_id:id,revision:1,scope:"public",visible:false}),env);
 assert.equal(response.status,200);
 let flags=await (await worker.fetch(new Request(origin+"/api/public-editorial-overrides"),env)).json();
 assert.deepEqual(flags.visibility,[{trend_id:id,revision:1,visible:0}]);
 assert.deepEqual(flags.suppressed,[]);
 let feed=await (await worker.fetch(new Request(origin+"/api/state/web-top30.json",{headers:{cookie:session}}),env)).json();
 assert.equal(feed.items[0].image_available,true);
 assert.equal(feed.items[0].public_image_visible,false);

 response=await worker.fetch(action(session,{trend_id:id,revision:1,scope:"both",hidden:true}),env);
 assert.equal(response.status,200);
 flags=await (await worker.fetch(new Request(origin+"/api/public-editorial-overrides"),env)).json();
 assert.deepEqual(flags.suppressed,[{trend_id:id,revision:1}]);
 feed=await (await worker.fetch(new Request(origin+"/api/state/web-top30.json",{headers:{cookie:session}}),env)).json();
 assert.equal(feed.items[0].image_available,false);
 assert.equal(feed.items[0].image_suppressed,true);

 response=await worker.fetch(action(session,{trend_id:id,revision:1,scope:"both",hidden:false}),env);
 assert.equal(response.status,200);
 assert.equal(database.hidden.length,0);
});

test("frequent V2 and public polling shares a short D1 snapshot and writes invalidate it",async()=>{
 const database=db(),env={...secrets,MARKS_DB:database};
 const first=await (await worker.fetch(new Request(origin+"/api/public-editorial-overrides"),env)).json();
 const second=await (await worker.fetch(new Request(origin+"/api/public-editorial-overrides"),env)).json();
 assert.deepEqual(first,second);
 assert.equal(database.counters.preferenceScans,1);
 const session=await cookie(env);
 const response=await worker.fetch(action(session,{trend_id:id,revision:1,scope:"public",visible:true}),env);
 assert.equal(response.status,200);
 const after=await (await worker.fetch(new Request(origin+"/api/public-editorial-overrides"),env)).json();
 assert.deepEqual(after.visibility,[{trend_id:id,revision:1,visible:1}]);
 assert.equal(database.counters.preferenceScans,2);
});

test("edge cache shares override reads between Worker instances and a switch evicts it",async()=>{
 const entries=new Map();
 const old=globalThis.caches;
 globalThis.caches={default:{
  async match(request){const entry=entries.get(request.url);return entry?new Response(entry.body,{headers:entry.headers}):undefined;},
  async put(request,response){entries.set(request.url,{body:await response.text(),headers:Object.fromEntries(response.headers)});},
  async delete(request){return entries.delete(request.url);}
 }};
 try{
  const a=db(),envA={...secrets,MARKS_DB:a};
  const b=db(),envB={...secrets,MARKS_DB:b};
  const endpoint=new Request(origin+"/api/public-editorial-overrides");
  assert.equal((await worker.fetch(endpoint,envA)).status,200);
  assert.equal(a.counters.preferenceScans,1);
  assert.equal((await worker.fetch(endpoint,envB)).status,200);
  assert.equal(b.counters.preferenceScans,0,"a different instance reuses the edge snapshot");
  const session=await cookie(envB);
  assert.equal((await worker.fetch(action(session,{trend_id:id,revision:1,scope:"public",visible:true}),envB)).status,200);
  const refreshed=await (await worker.fetch(endpoint,envA)).json();
  // A separate instance can retain its own 45-second memory snapshot. The
  // edge key is evicted immediately and a fresh instance sees the new value.
  assert.equal(entries.size,0);
  const c=db(),envC={...secrets,MARKS_DB:c};
  assert.equal((await worker.fetch(endpoint,envC)).status,200);
  assert.equal(c.counters.preferenceScans,1);
  assert.ok(Array.isArray(refreshed.visibility));
 }finally{globalThis.caches=old;}
});

test("shared D1 snapshot avoids historical scans even when edge caching is absent",async()=>{
 const a=db(),envA={...secrets,MARKS_DB:a};
 const endpoint=new Request(origin+"/api/public-editorial-overrides");
 assert.equal((await worker.fetch(endpoint,envA)).status,200);
 assert.equal(a.counters.preferenceScans,1);
 assert.equal(typeof a.snapshot.row?.payload,"string");
 const b=db();b.snapshot.row=a.snapshot.row;
 const envB={...secrets,MARKS_DB:b};
 assert.equal((await worker.fetch(endpoint,envB)).status,200);
 assert.equal(b.counters.preferenceScans,0,"the primary-key snapshot replaces six history scans");
 const session=await cookie(envB);
 assert.equal((await worker.fetch(action(session,{trend_id:id,revision:1,scope:"public",visible:true}),envB)).status,200);
 assert.equal(b.snapshot.row.cached_at_ms,0,"a user edit invalidates the shared D1 snapshot");
 const c=db();c.snapshot.row=b.snapshot.row;
 const envC={...secrets,MARKS_DB:c};
 const fresh=await (await worker.fetch(endpoint,envC)).json();
 assert.equal(c.counters.preferenceScans,1,"the next reader rebuilds an invalidated snapshot");
 assert.equal(fresh.visibility.length,0,"a new instance reads its own control tables after invalidation");
});

test("sensitive topics begin with public image off while private image stays on",async()=>{
 const database=db(),env={...secrets,MARKS_DB:database},session=await cookie(env);
 editorial.items[0].explanation="La tragedia dejó víctimas mortales tras un naufragio.";
 const feed=await (await worker.fetch(new Request(origin+"/api/state/web-top30.json",{headers:{cookie:session}}),env)).json();
 assert.equal(feed.items[0].image_sensitivity_default,true);
 assert.equal(feed.items[0].public_image_visible,false);
 assert.equal(feed.items[0].image_available,true);
});

test("all new images start V2-only, even in non-sensitive topics",async()=>{
 editorial.items[0].explanation="El concierto del grupo se celebra esta noche en Madrid.";
 const database=db(),env={...secrets,MARKS_DB:database},session=await cookie(env);
 let feed=await (await worker.fetch(new Request(origin+"/api/state/web-top30.json",{headers:{cookie:session}}),env)).json();
 assert.equal(feed.items[0].image_sensitivity_default,false);
 assert.equal(feed.items[0].public_image_visible,false);
 assert.equal(feed.items[0].image_available,true);
 assert.equal(database.prefs.length,0);
 const response=await worker.fetch(action(session,{trend_id:id,revision:1,scope:"public",visible:true}),env);
 assert.equal(response.status,200);
 feed=await (await worker.fetch(new Request(origin+"/api/state/web-top30.json",{headers:{cookie:session}}),env)).json();
 assert.equal(feed.items[0].public_image_visible,true);
});

test("image controls require a signed session and same-origin action",async()=>{
 const database=db(),env={...secrets,MARKS_DB:database};
 const payload={trend_id:id,revision:1,scope:"both",hidden:true};
 assert.equal((await worker.fetch(action("",payload),env)).status,401);
 const session=await cookie(env);
 const forged=new Request(origin+"/api/image-visibility",{method:"POST",headers:{cookie:session,origin:"https://evil.example","x-ttv2-action":"1"},body:JSON.stringify(payload)});
 assert.equal((await worker.fetch(forged,env)).status,405);
 assert.equal(database.hidden.length,0);
});
