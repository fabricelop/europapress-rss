import test from 'node:test';
import assert from 'node:assert/strict';
import {editorEmails,chooseWorker,chooseAccessApp,validateEditorPolicies,prepareWorkerAccess} from '../scripts/prepare-worker-access.mjs';
const aud='c'.repeat(64);
const env={CLOUDFLARE_ACCOUNT_ID:'a'.repeat(32),CLOUDFLARE_API_TOKEN:'secret-token',TT_FOTOS_ALLOWED_EMAIL:'one@example.org, two@example.org'};
const worker={name:'tt-fotos-independent',id:'12341234123412341234123412341234'};
const policy={decision:'allow',include:[{email:{email:'one@example.org'}},{email:{email:'two@example.org'}}]};
const app={type:'self_hosted',id:'abcabcab-1234-1234-1234-123412341234',aud,destinations:[{type:'worker',worker_id:worker.id}]};
function fake({existing=false,policies=[policy],badWorker=false}={}){
 const calls=[],state={app:existing?app:null};
 const fetcher=async(url,options)=>{
  calls.push({url,method:options.method,body:options.body?JSON.parse(options.body):null,token:options.headers.Authorization});
  const p=new URL(url).pathname;
  let result;
  if(options.method==='GET'&&p.endsWith('/workers/workers'))result=badWorker?[]:[worker];
  else if(options.method==='GET'&&p.endsWith('/access/apps'))result=state.app?[state.app]:[];
  else if(options.method==='POST'&&p.endsWith('/access/apps')){
   assert.equal(state.app,null);
   assert.equal(options.headers.Authorization,'Bearer secret-token');
   const body=JSON.parse(options.body);
   assert.equal(body.type,'self_hosted');
   assert.deepEqual(body.destinations,[{type:'worker',worker_id:worker.id}]);
   assert.deepEqual(body.policies,[policy]);
   state.app=app;result=app;
  }else if(options.method==='GET'&&p.endsWith('/policies'))result=policies;
  else throw Error('Unexpected '+options.method+' '+p);
  return new Response(JSON.stringify({success:true,result}),{status:200});
 };
 return {calls,state,fetcher};
}
test('editor email allowlist and exact worker selection are strict',()=>{
 assert.deepEqual(editorEmails(' ONE@example.org, two@example.org '),['one@example.org','two@example.org']);
 for(const input of ['', '*','bad', 'one@example.org,one@example.org'])assert.throws(()=>editorEmails(input));
 assert.deepEqual(chooseWorker([{name:'other-worker',id:'not-it'},worker]),worker);
 assert.throws(()=>chooseWorker([]));
 assert.throws(()=>chooseWorker([worker,worker]));
});
test('existing app must serve the exact isolated worker with no public overrides',()=>{
 assert.deepEqual(chooseAccessApp([app],worker.id,aud),app);
 assert.equal(chooseAccessApp([],worker.id),null);
 assert.throws(()=>chooseAccessApp([app],worker.id,'d'.repeat(64)));
 assert.throws(()=>chooseAccessApp([{...app,destinations:[{type:'worker',worker_id:worker.id,overrides:[{behavior:'public',path_pattern:'/*'}]}]}],worker.id));
 assert.throws(()=>chooseAccessApp([app,app],worker.id));
});
test('editor policies must not include everyone, domains or bypass decisions',()=>{
 assert(validateEditorPolicies([policy],['one@example.org','two@example.org']));
 for(const p of [
   {decision:'bypass',include:[{everyone:{}}]},
   {decision:'allow',include:[{email_domain:{domain:'example.org'}}]},
   {decision:'allow',include:[{email:{email:'unexpected@example.org'}}]},
   {decision:'allow',include:[{email:{email:'one@example.org'}}]}
 ]){
  assert.throws(()=>validateEditorPolicies([p],['one@example.org','two@example.org']));
 }
});
test('read-only inspection of missing app does not create anything',async()=>{
 const m=fake();
 const r=await prepareWorkerAccess({env,fetcher:m.fetcher});
 assert.equal(r.ready,false);
 assert.equal(r.reason,'ACCESS_APP_MISSING');
 assert(m.calls.every(x=>x.method==='GET'));
});
test('explicit new Access app limits to editor emails and is idempotent',async()=>{
 const m=fake();
 const first=await prepareWorkerAccess({env,fetcher:m.fetcher,createMissing:true});
 assert.equal(first.ready,true);
 assert.equal(first.aud,aud);
 assert.equal(first.created,true);
 const second=await prepareWorkerAccess({env,fetcher:m.fetcher,createMissing:true});
 assert.equal(second.ready,true);
 assert.equal(second.created,false);
 assert.equal(m.calls.filter(x=>x.method==='POST').length,1);
});
test('expected but absent Access app, missing Worker and overly broad policy fail closed',async()=>{
 const missing=fake();
 await assert.rejects(()=>prepareWorkerAccess({env:{...env,TT_FOTOS_ACCESS_AUD:aud},fetcher:missing.fetcher,createMissing:true}),/EXPECTED_ACCESS_APP_NOT_FOUND/);
 assert(missing.calls.every(x=>x.method==='GET'));
 const noWorker=fake({badWorker:true});
 await assert.rejects(()=>prepareWorkerAccess({env,fetcher:noWorker.fetcher,createMissing:true}),/TT_FOTOS_WORKER_NOT_FOUND_OR_AMBIGUOUS/);
 assert(noWorker.calls.every(x=>x.method==='GET'));
 const broad=fake({existing:true,policies:[{decision:'allow',include:[{everyone:{}}]}]});
 await assert.rejects(()=>prepareWorkerAccess({env,fetcher:broad.fetcher}),/ACCESS_POLICY_TOO_BROAD/);
 assert(broad.calls.every(x=>x.method==='GET'));
});
