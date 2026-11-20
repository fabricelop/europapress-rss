import test from "node:test";
import assert from "node:assert/strict";
import {publicTrendImageRetries,trendImageRetry} from "../src/trend-image-retry.js";
import worker from "../src/index.js";

const trend_id="trv2-"+"a".repeat(24),revision=3,hash="b".repeat(64);
const at="2026-11-20T21:21:30Z";
const item={trend_id,revision,status:"explicada",image_available:false,image_in_progress:false,image_incident_available:true,
 explanation:"Explicación original contrastada que debe conservarse íntegra."};
const json=(body,status=200)=>({body,status});
const safe={project:"ttendencias-v2",target_id:trend_id,revision,available:true,editorial_sha256:hash,
 incident:{code:"V2_IMAGE_NOT_READY",retry_mode:"manual_only",at}};
const request=body=>new Request("https://example.test/api/trend-image-retry",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify(body)});
function db(){
 const rows=[],publicPrefs=[];
 return {rows,publicPrefs,prepare(sql){let args=[];return {
  bind(...values){args=values;return this;},
  async run(){
   if(sql.startsWith("INSERT INTO")){
    if(sql.includes("public_image_prefs")){
     const prior=publicPrefs.find(x=>x.trend_id===args[0]&&x.revision===args[1]);
     if(prior)prior.visible=0;
     else publicPrefs.push({trend_id:args[0],revision:args[1],visible:0});
     return {success:true};
    }
    if(!rows.some(x=>x.trend_id===args[0]&&x.revision===args[1]&&x.incident_at===args[2]))
     rows.push({trend_id:args[0],revision:args[1],incident_at:args[2],editorial_sha256:args[3],request_id:args[4],requested_at:new Date().toISOString()});
   }
   return {success:true};
  },
  async all(){return {results:rows.slice()};},
  async first(){return rows.find(x=>x.trend_id===args[0]&&x.revision===args[1]&&x.incident_at===args[2])||null;}
 };}};
}
const context=(storage,ranking=[item],incident=safe)=>({json,sameOrigin:()=>true,currentRanking:async()=>ranking,readIncident:async()=>incident});

test("REI-IA stores one idempotent exact-incident request and leaves explanation unchanged",async()=>{
 const store=db(),env={MARKS_DB:store};
 // An opted-in older photo must not opt the replacement into V1/RSS.
 store.publicPrefs.push({trend_id,revision,visible:1});
 const before=structuredClone(item);
 const first=await trendImageRetry(request({trend_id,revision}),env,context(store));
 const repeat=await trendImageRetry(request({trend_id,revision}),env,context(store));
 assert.equal(first.status,202);assert.equal(repeat.status,202);assert.equal(store.rows.length,1);
 assert.deepEqual(store.publicPrefs,[{trend_id,revision,visible:0}]);
 assert.deepEqual(item,before);
 assert.equal(store.rows[0].editorial_sha256,hash);
 assert.match(store.rows[0].request_id,/^[a-f0-9]{32}$/);
 const publicData=await publicTrendImageRetries(new Request("https://example.test/api/public-trend-image-retries"),env,{json,readIncident:async()=>safe});
 assert.equal(publicData.status,200);assert.deepEqual(publicData.body.requests,store.rows);
 const ownerData=await trendImageRetry(new Request("https://example.test/api/trend-image-retry"),env,context(store));
 assert.deepEqual(ownerData.body.requests,store.rows);
});

test("a newer safe failure of the SAME explanation cannot lose an already queued REI-IA",async()=>{
 const storage=db(),env={MARKS_DB:storage};
 await trendImageRetry(request({trend_id,revision}),env,context(storage));
 const original=structuredClone(storage.rows[0]);
 const newer={...safe,incident:{...safe.incident,at:"2026-11-20T22:18:59Z"}};
 const current=await publicTrendImageRetries(new Request("https://example.test/api/public-trend-image-retries"),env,
  {json,readIncident:async()=>newer,now:Date.now()+61000});
 assert.equal(current.status,200);
 assert.equal(current.body.requests.length,1);
 assert.equal(current.body.requests[0].incident_at,newer.incident.at);
 assert.equal(current.body.requests[0].request_id,original.request_id);
 assert.deepEqual(storage.rows,[original]); // Reconciliation does not rewrite an owner's request.
 const unsafe=await publicTrendImageRetries(new Request("https://example.test/api/public-trend-image-retries"),env,
  {json,readIncident:async()=>({...newer,incident:{...newer.incident,code:"V2_IMAGE_PROFILE_LOGIN_REQUIRED"}}),now:Date.now()+61000});
 assert.deepEqual(unsafe.body.requests,[]);
 const wrongText=await publicTrendImageRetries(new Request("https://example.test/api/public-trend-image-retries"),env,
  {json,readIncident:async()=>({...newer,editorial_sha256:"c".repeat(64)}),now:Date.now()+61000});
 assert.deepEqual(wrongText.body.requests,[]);
});

test("REI-IA rejects obsolete revision, image already present, generation in progress and unsafe incidents",async()=>{
 for(const ranking of [[],[{...item,revision:4}],[{...item,image_available:true}],
  [{...item,image_in_progress:true}],[{...item,status:"en_elaboracion"}],[{...item,image_incident_available:false}]]){
  const storage=db();const result=await trendImageRetry(request({trend_id,revision}),{MARKS_DB:storage},context(storage,ranking));
  assert.equal(result.status,409);assert.equal(storage.rows.length,0);
 }
 for(const incident of [{...safe,available:false},{...safe,incident:{...safe.incident,retry_mode:"none"}},
  {...safe,incident:{...safe.incident,code:"V2_IMAGE_PROFILE_LOGIN_REQUIRED"}}]){
  const storage=db();const result=await trendImageRetry(request({trend_id,revision}),{MARKS_DB:storage},context(storage,[item],incident));
  assert.equal(result.status,409);assert.equal(storage.rows.length,0);
 }
});

test("REI-IA requires same-origin action, valid identity and a proven capture hash",async()=>{
 const storage=db(),env={MARKS_DB:storage};
 assert.equal((await trendImageRetry(request({trend_id,revision}),env,{...context(storage),sameOrigin:()=>false})).status,405);
 assert.equal((await trendImageRetry(request({trend_id:"../other",revision}),env,context(storage))).status,400);
 assert.equal((await trendImageRetry(request({trend_id,revision}),env,context(storage,[item],{...safe,editorial_sha256:null}))).status,503);
 assert.equal(storage.rows.length,0);
 assert.equal((await publicTrendImageRetries(new Request("https://example.test/api/public-trend-image-retries",{method:"POST"}),env,{json})).status,405);
});

test("REI-IA write endpoint is private while the image daemon sees only bounded control metadata",async()=>{
 const env={MARKS_DB:db(),AUTH_PASSWORD:"private-password-longer-than-16",SESSION_SECRET:"private-session-secret-with-more-than-32-characters"};
 const original=globalThis.fetch;
 try{
  let upstream=0;
  globalThis.fetch=async()=>{upstream++;return Response.json({project:"ttactualidad-v2",count:0,items:[]});};
  const anonymous=await worker.fetch(request({trend_id,revision}),env);
  assert.equal(anonymous.status,401);assert.equal(upstream,0);
  const publicData=await worker.fetch(new Request("https://example.test/api/public-trend-image-retries"),env);
  assert.equal(publicData.status,200);
  assert.deepEqual((await publicData.json()).requests,[]);
 }finally{globalThis.fetch=original;}
});
