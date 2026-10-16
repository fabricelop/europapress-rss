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
r=await request('/api/decisions',{headers:{Authorization:'Bearer wrong'}});
assert.equal(r.status,401);
assert.equal(kv.getCalls+kv.writeCalls+kv.listCalls,0,'unauthorized must not touch KV');
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
console.log('OK: auth, KV-free health, one write per action, immutable decision, pilot isolation, synthetic safety');
