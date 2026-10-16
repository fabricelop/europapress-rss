import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
const script = './pilot/ttactualidad-worker.js';
const s=readFileSync(script,'utf8');
const codeUrl='data:text/javascript;base64,'+Buffer.from(s,'utf8').toString('base64');
const {default:handler}=await import(codeUrl);
class KV{
 constructor(){this.map=new Map();this.listCalls=0;this.getCalls=0;this.writeCalls=0}
 async get(key,type){this.getCalls++;let x=this.map.get(key);return type==='json'?x&&JSON.parse(x):x||null}
 async put(key,value){this.writeCalls++;this.map.set(key,value)}
 async list({prefix='',limit=100}={}){this.listCalls++;const keys=[...this.map.keys()].filter(k=>k.startsWith(prefix)).slice(0,limit);return {keys:keys.map(name=>({name})),list_complete:keys.length===this.map.size}}
}
const kv=new KV();
const env={PILOT_TOKEN:'test-private-token',PILOT_DECISIONS:kv};
function req(path,opts={}){
 const headers={Authorization:'Bearer test-private-token',...opts.headers};
 return new Request('https://ttactualidad-decisions-pilot.fabricelop.workers.dev'+path,{...opts,headers});
}
async function request(path,opts){let r=await handler.fetch(req(path,opts),env);return {status:r.status,json:await r.json()}}
let r=await request('/health');
assert.equal(r.json.production_connected,false);
assert.equal(kv.getCalls+kv.writeCalls+kv.listCalls,0,'health must not touch KV');
let assetReads=0;
env.ASSETS={fetch:async (_req)=>{assetReads++;return new Response('<html>TTActualidad piloto</html>',{status:200,headers:{'Content-Type':'text/html'}})}};
const publicHome=await handler.fetch(new Request('https://ttactualidad-decisions-pilot.fabricelop.workers.dev/'),env);
assert.equal(publicHome.status,200,'static pilot home must work without auth');
assert.match(await publicHome.text(),/TTActualidad/);
assert.equal(assetReads,1,'static homepage should be served from ASSETS');
const publicDenied=await handler.fetch(new Request('https://ttactualidad-decisions-pilot.fabricelop.workers.dev/api/decisions'),env);
assert.equal(publicDenied.status,401,'private API cannot be served as a public asset');
assert.equal(assetReads,1,'private API must not touch static asset handler');
assert.equal(kv.getCalls+kv.writeCalls+kv.listCalls,0,'static public routes must not touch KV');
r=await request('/api/decisions',{headers:{Authorization:'Bearer wrong'}});
assert.equal(r.status,401);
assert.equal(kv.getCalls+kv.writeCalls+kv.listCalls,0,'unauthorized must not touch KV');
const authBefore=kv.getCalls+kv.writeCalls+kv.listCalls;
const authCheck=await request('/api/auth');
assert.equal(authCheck.status,200);
assert.equal(authCheck.json.ok,true);
assert.equal(authCheck.json.production_connected,false);
assert.equal(kv.getCalls+kv.writeCalls+kv.listCalls,authBefore,'auth checks cannot spend KV quota');
let body={project:'ttittulares',event_id:'abcdef123456',decision:'deleted',request_id:'11111111-2222-3333-4444-555555555555'};
r=await request('/api/decision',{method:'POST',body:JSON.stringify(body)});
assert.equal(r.status,201);assert.equal(r.json.routed,false);assert.equal(r.json.state,'pilot_only');
assert.equal(kv.writeCalls,1);
r=await request('/api/decision',{method:'POST',body:JSON.stringify(body)});
assert.equal(r.status,200);assert.equal(r.json.duplicate,true);assert.equal(kv.writeCalls,1);
r=await request('/api/decision',{method:'POST',body:JSON.stringify({...body,decision:'published'})});
assert.equal(r.status,409);assert.equal(kv.writeCalls,1);
r=await request('/api/decision?project=ttittulares&event_id=abcdef123456');
assert.equal(r.json.found,true);assert.equal(r.json.item.decision,'deleted');
r=await request('/api/decisions');
assert.equal(r.json.items.length,1);
assert.equal(r.json.items[0].mode,'pilot_only');
r=await request('/api/decision',{method:'POST',body:JSON.stringify({...body,event_id:'abc',decision:'discard',project:'unknown'})});
assert.equal(r.status,400);
r=await request('/api/decision',{method:'POST',body:JSON.stringify({...body,event_id:'pilot-mobile-0123456789abcdef0123456789abcdef',decision:'prepare'})});
assert.equal(r.json.routed,false);
assert.equal(kv.writeCalls,2);
// Live state only submits `deleted`, never manufactures a completed deletion.
env.ACTION_MODE='github_dispatch';env.GH_DISPATCH_TOKEN='fake-test-token';
const originalFetch=globalThis.fetch;
const messages=[];
globalThis.fetch=async(url,options)=>{
 messages.push({url,body:JSON.parse(options.body)});
 return new Response('',{status:204});
};
try{
 let live=await request('/api/decision',{method:'POST',body:JSON.stringify({
   project:'ttendencias',event_id:'def123456abc',decision:'deleted',revision:2,
   request_id:'cccccccc-2222-3333-4444-555555555555'})});
 assert.equal(live.status,201);assert.equal(live.json.state,'submitted');
 assert.equal(live.json.routed,true);
 assert.equal(messages.length,1);
 assert.equal(messages[0].body.client_payload.revision,2);
 live=await request('/api/decision',{method:'POST',body:JSON.stringify({
   project:'ttendencias',event_id:'def123456abc',decision:'deleted',revision:2,
   request_id:'dddddddd-2222-3333-4444-555555555555'})});
 assert.equal(live.json.duplicate,true);
 assert.equal(messages.length,1,'repeat decision must not trigger second GitHub action');
 let test=await request('/api/decision',{method:'POST',body:JSON.stringify({
   project:'ttendencias',event_id:'f8aabbccddee',decision:'discard',revision:1,
   request_id:'cccccccc-3333-3333-4444-555555555555'})});
 assert.equal(test.json.state,'pilot_only');
 assert.equal(messages.length,1,'discard stays in pilot until separately validated');
 // Previously simulated deletion must be eligible for real dispatch later.
 let staged=await request('/api/decision',{method:'POST',body:JSON.stringify({
   project:'ttittulares',event_id:'abcdef123456',decision:'deleted',revision:1,
   request_id:'cccccccc-4444-3333-4444-555555555555'})});
 assert.equal(staged.json.state,'submitted');
 assert.equal(messages.length,2);
 // Refuse an absent revision without calling GitHub.
 const missing=await request('/api/decision',{method:'POST',body:JSON.stringify({
   project:'ttittulares',event_id:'fedcba654321',decision:'deleted',
   request_id:'cccccccc-5555-3333-4444-555555555555'})});
 assert.equal(missing.status,400);
 assert.equal(messages.length,2);
 globalThis.fetch=async()=>new Response('',{status:403});
 const bad=await request('/api/decision',{method:'POST',body:JSON.stringify({
   project:'ttittulares',event_id:'aabbccddeeff',decision:'deleted',revision:1,
   request_id:'cccccccc-6666-3333-4444-555555555555'})});
 assert.equal(bad.status,502);
 assert.equal(bad.json.ok,false);
 assert.equal(kv.map.has('action:ttittulares:aabbccddeeff'),false);
}finally{globalThis.fetch=originalFetch}
console.log('OK: isolated/live action gating, replay safety, revisions, GitHub refusal, no polling');
