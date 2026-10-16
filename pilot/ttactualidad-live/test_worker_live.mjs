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
const request=(id,decision,request_id)=>new Request(root+'/api/decision',{method:'POST',
 headers:{'Authorization':'Bearer unit-test-secret','Origin':root,'Content-Type':'application/json'},
 body:JSON.stringify({project:'ttittulares',event_id:id,decision,revision:1,request_id})});
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
}finally{globalThis.fetch=original}
console.log('TTActualidad V8 Worker: live dispatch, no synthetic side effects, safe retry OK');
