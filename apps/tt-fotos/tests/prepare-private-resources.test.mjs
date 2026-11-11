import test from 'node:test';
import assert from 'node:assert/strict';
import {inspectIdentity,preparePrivateResources,safePreparationReport} from '../scripts/prepare-private-resources.mjs';

const uuid='12345678-1234-4234-8234-123456789abc';
const env={CLOUDFLARE_ACCOUNT_ID:'a'.repeat(32),CLOUDFLARE_API_TOKEN:'PRIVATE_TOKEN'};
function fake(initial={}){
 const records=[],state={d1:initial.d1??null,bucket:initial.bucket??null,
  public:initial.public??false,custom:initial.custom??[]};
 const fetcher=async(url,options)=>{
  const pathname=new URL(url).pathname;
  const method=options.method;records.push({pathname,method});
  assert.equal(options.headers.Authorization,'Bearer PRIVATE_TOKEN');
  let result,code=200;
  if(method==='GET'&&pathname.endsWith('/d1/database'))result=state.d1?[state.d1]:[];
  else if(method==='GET'&&pathname.endsWith('/r2/buckets/tt-fotos-originals-private')){
   if(!state.bucket)code=404;else result=state.bucket;
  }else if(method==='GET'&&pathname.endsWith('/domains/managed'))result={enabled:state.public};
  else if(method==='GET'&&pathname.endsWith('/domains/custom'))result={domains:state.custom};
  else if(method==='POST'&&pathname.endsWith('/d1/database')){
   assert.equal(JSON.parse(options.body).name,'tt-fotos-private');
   assert.equal(state.d1,null);state.d1={name:'tt-fotos-private',uuid};result=state.d1;
  }else if(method==='POST'&&pathname.endsWith('/r2/buckets')){
   assert.equal(JSON.parse(options.body).name,'tt-fotos-originals-private');
   assert.equal(state.bucket,null);state.bucket={name:'tt-fotos-originals-private'};result=state.bucket;
  }else throw Error('unexpected operation '+method+' '+pathname);
  return new Response(JSON.stringify({success:code===200,result:result||null}),{status:code});
 };
 return {records,state,fetcher};
}
test('read-only inspection never creates resources',async()=>{
 const a=fake();
 const out=await preparePrivateResources({env,fetcher:a.fetcher});
 assert.equal(out.ready,false);
 assert.deepEqual(out.missing,['tt-fotos-private','tt-fotos-originals-private']);
 assert(a.records.every(r=>r.method==='GET'));
});
test('explicitly creating two missing dedicated resources is idempotent',async()=>{
 const a=fake();
 const first=await preparePrivateResources({env,fetcher:a.fetcher,createMissing:true});
 assert.equal(first.ready,true);
 assert.deepEqual(first.created,['tt-fotos-private','tt-fotos-originals-private']);
 assert.equal(first.d1Id,uuid);
 const second=await preparePrivateResources({env,fetcher:a.fetcher,createMissing:true});
 assert.deepEqual(second.created,[]);
 assert.equal(second.d1Id,uuid);
 assert.equal(a.records.filter(x=>x.method==='POST').length,2);
 assert(!safePreparationReport(first).includes('PRIVATE_TOKEN'));
});
test('existing private resources are reused without changes',async()=>{
 const a=fake({d1:{name:'tt-fotos-private',uuid},bucket:{name:'tt-fotos-originals-private'}});
 const out=await preparePrivateResources({env:{...env,TT_FOTOS_D1_DATABASE_ID:uuid},fetcher:a.fetcher,createMissing:true});
 assert.equal(out.ready,true);
 assert.deepEqual(out.created,[]);
 assert(a.records.every(x=>x.method==='GET'));
});
test('wrong preexisting D1 UUID, public R2, unexpected list and missing auth block all writes',async()=>{
 const wrong=fake({d1:{name:'tt-fotos-private',uuid}});
 await assert.rejects(()=>preparePrivateResources({env:{...env,TT_FOTOS_D1_DATABASE_ID:'99999999-9999-4999-8999-999999999999'},fetcher:wrong.fetcher,createMissing:true}),/D1_IDENTITY_MISMATCH/);
 assert(wrong.records.every(x=>x.method==='GET'));
 const publicR2=fake({bucket:{name:'tt-fotos-originals-private'},public:true});
 await assert.rejects(()=>preparePrivateResources({env,fetcher:publicR2.fetcher,createMissing:true}),/TT_FOTOS_R2_MANAGED_PUBLIC_OR_UNKNOWN/);
 assert(publicR2.records.every(x=>x.method==='GET'));
 const expectedMissing=fake();
 await assert.rejects(()=>preparePrivateResources({env:{...env,TT_FOTOS_D1_DATABASE_ID:uuid},fetcher:expectedMissing.fetcher,createMissing:true}),/EXPECTED_D1_NOT_PRESENT/);
 assert(expectedMissing.records.every(x=>x.method==='GET'));
 const noToken=fake();
 await assert.rejects(()=>preparePrivateResources({env:{...env,CLOUDFLARE_API_TOKEN:''},fetcher:noToken.fetcher,createMissing:true}));
 assert.equal(noToken.records.length,0);
 assert.throws(()=>inspectIdentity([{name:'tt-fotos-private',uuid},{name:'tt-fotos-private',uuid}],null),/D1_NAME_NOT_UNIQUE/);
});
test('a failed R2 API check blocks creating D1 and no existing public domains are changed',async()=>{
 const x=fake({bucket:{name:'tt-fotos-originals-private'},custom:[{enabled:true}]});
 await assert.rejects(()=>preparePrivateResources({env,fetcher:x.fetcher,createMissing:true}));
 assert.equal(x.state.d1,null);
 assert(x.records.every(r=>r.method==='GET'));
});
