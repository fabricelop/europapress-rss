import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const source=readFileSync('pilot/ttactualidad-live/worker.js','utf8');
const {default:app}=await import('data:text/javascript;base64,'+Buffer.from(source).toString('base64'));
const memory=new Map(),calls=[];
const env={
 PILOT_TOKEN:'unit-test-secret',
 GH_DISPATCH_TOKEN:'test-github-token',
 ACTION_MODE:'github_dispatch',
 PILOT_DECISIONS:{
  async get(key,type){const v=memory.get(key);return type==='json'?(v?JSON.parse(v):null):(v||null)},
  async put(key,value){memory.set(key,value)},
  async list(){return {keys:[],list_complete:true}}
 }
};
const root='https://ttactualidad-decisions-pilot.fabricelop.workers.dev';
const request=(id,decision,request_id,revision=1)=>new Request(root+'/api/decision',{method:'POST',
 headers:{'Authorization':'Bearer unit-test-secret','Origin':root,'Content-Type':'application/json'},
 body:JSON.stringify({project:'ttittulares',event_id:id,decision,revision,request_id})});
const original=globalThis.fetch;
globalThis.fetch=async(url,opts)=>{
 calls.push(JSON.parse(opts.body));
 return new Response(null,{status:204});
};
try{
 const first=await app.fetch(request('abc123','discard','11111111-1111-1111-1111-111111111111'),env);
 assert.equal(first.status,201);
 assert.equal((await first.json()).routed,true);
 assert.equal(calls[0].client_payload.decision,'discard');
 const second=await app.fetch(request('def456','prepare','22222222-2222-2222-2222-222222222222'),env);
 assert.equal(second.status,201);
 assert.equal(calls[1].client_payload.decision,'prepare');
 const duplicate=await app.fetch(request('abc123','discard','11111111-1111-1111-1111-111111111111'),env);
 assert.equal((await duplicate.json()).duplicate,true);
 assert.equal(calls.length,2);
 const record=JSON.parse(memory.get('action:ttittulares:abc123'));
 record.received_at=new Date(Date.now()-240000).toISOString();
 memory.set('action:ttittulares:abc123',JSON.stringify(record));
 const retry=await app.fetch(request('abc123','discard','11111111-1111-1111-1111-111111111111'),env);
 assert.equal((await retry.json()).routed,true);
 assert.equal(calls.length,3);
 const blocked=await app.fetch(request('pilot-mobile-test1234','discard','33333333-3333-3333-3333-333333333333'),env);
 assert.equal((await blocked.json()).routed,false);
 assert.equal(calls.length,3);
 // Arde Bogota was still in GitHub prepared.json but KV held an older,
 // incompatible action; a new explicit live removal must reach GitHub.
 memory.set('action:ttittulares:fe4651ef7e8a',JSON.stringify({
   project:'ttittulares',event_id:'fe4651ef7e8a',decision:'discard',
   mode:'pilot_only',state:'pilot_only',routed:false,revision:1
 }));
 const arde=await app.fetch(request('fe4651ef7e8a','deleted',
   '44444444-4444-4444-4444-444444444444'),env);
 assert.equal(arde.status,201,'Old KV state must not block a real removal');
 assert.equal((await arde.json()).routed,true);
 assert.equal(calls.at(-1).client_payload.event_id,'fe4651ef7e8a');
 assert.equal(calls.at(-1).client_payload.decision,'deleted');
 assert.equal(JSON.parse(memory.get('action:ttittulares:fe4651ef7e8a')).decision,'deleted');
 // An earlier live request may also be obsolete: GitHub, not KV, makes
 // the final decision. Explicit new user intent must be sent.
 const override=await app.fetch(request('abc123','deleted',
   '55555555-5555-5555-5555-555555555555'),env);
 assert.equal(override.status,201);
 assert.equal((await override.json()).routed,true);
 assert.equal(calls.at(-1).client_payload.decision,'deleted');
 // A new editorial revision must not be treated as a duplicate submission.
 const updatedRevision=await app.fetch(request('fe4651ef7e8a','deleted',
   '66666666-6666-6666-6666-666666666666',2),env);
 assert.equal(updatedRevision.status,201);
 assert.equal((await updatedRevision.json()).routed,true);
 assert.equal(calls.at(-1).client_payload.revision,2);
 // Synthetic trial records remain isolated, even with a conflicting intent.
 const blockedConflict=await app.fetch(request('pilot-mobile-test1234','deleted',
   '77777777-7777-7777-7777-777777777777'),env);
 assert.equal(blockedConflict.status,409);
 assert.equal((await blockedConflict.json()).error,'already_decided');
 // New manual submission is isolated from /api/decision and its KV records.
 const manualPayload={title:'Titular proporcionado',url:'https://example.org/news#section',
  instructions:'Verificar fuentes',request_id:'01234567-89ab-4cde-8fab-0123456789ab'};
 const manualReq=(payload,auth=true,origin=root)=>new Request(root+'/api/manual-news',{
  method:'POST',headers:{...(auth?{'Authorization':'Bearer unit-test-secret'}:{}),
   Origin:origin,'Content-Type':'application/json'},body:JSON.stringify(payload)});
 const newNews=await app.fetch(manualReq(manualPayload),env);
 assert.equal(newNews.status,202);
 const manualData=await newNews.json();
 assert.equal(manualData.state,'submitted');
 assert.equal(manualData.event_id,'manual-'+manualPayload.request_id);
 assert.equal(calls.at(-1).event_type,'ttactualidad_manual_news_v1');
 assert.equal(calls.at(-1).client_payload.url,'https://example.org/news');
 assert.equal(calls.at(-1).client_payload.instructions,'Verificar fuentes');
 const posted=calls.length;
 assert.equal((await app.fetch(manualReq({...manualPayload,url:'http://example.org'}),env)).status,400);
 assert.equal((await app.fetch(manualReq({...manualPayload,title:'',url:''}),env)).status,400);
 assert.equal((await app.fetch(manualReq(manualPayload,false),env)).status,401);
 assert.equal(calls.length,posted);
 assert.equal(memory.has('action:ttittulares:'+manualData.event_id),false);
 const health=await app.fetch(new Request(root+'/health'),env);
 assert.equal((await health.json()).version,'v8.1-kv-conflict-fix');
}finally{globalThis.fetch=original}
console.log('TTActualidad V8.1 Worker: old KV conflicts do not block GitHub, revisions and synthetic safety OK');
