import test from 'node:test';
import assert from 'node:assert/strict';
import {auditCloudflare,settingsCheck,findAccessApplication,verifyInventory,safeReport} from '../scripts/check-cloudflare-readiness.mjs';

const env={
 CLOUDFLARE_API_TOKEN:'SECRET_PRIVATE_TOKEN',
 CLOUDFLARE_ACCOUNT_ID:'a'.repeat(32),
 TT_FOTOS_D1_DATABASE_ID:'11111111-2222-3333-4444-555555555555',
 TT_FOTOS_ACCESS_ISSUER:'https://example.cloudflareaccess.com',
 TT_FOTOS_ACCESS_AUD:'b'.repeat(64),
 TT_FOTOS_ALLOWED_EMAIL:'editor@example.org'
};
const worker={id:'abcdabcdabcdabcdabcdabcdabcdabcd',name:'tt-fotos-independent'};
const access=[{aud:env.TT_FOTOS_ACCESS_AUD,id:'test-access-app',type:'self_hosted',destinations:[{type:'worker',worker_id:worker.id}]}];
function fakeFetcher({mutate,failedPath}={}){
 const calls=[];
 const request=async(url,options)=>{
  calls.push({url,method:options.method,authorization:options.headers.Authorization});
  const path=new URL(url).pathname;
  if(path===failedPath)return new Response('{}',{status:403});
  let result;
  if(path.endsWith('/d1/database/'+env.TT_FOTOS_D1_DATABASE_ID))result={name:'tt-fotos-private',uuid:env.TT_FOTOS_D1_DATABASE_ID};
  else if(path.endsWith('/r2/buckets/tt-fotos-originals-private'))result={name:'tt-fotos-originals-private'};
  else if(path.endsWith('/domains/managed'))result={enabled:false};
  else if(path.endsWith('/domains/custom'))result={domains:[]};
  else if(path.endsWith('/workers/workers'))result=[{id:'another-worker',name:'ttendencias-no-vercel-test'},worker];
  else if(path.endsWith('/access/apps'))result=access;
  if(typeof mutate==='function')result=mutate(path,result);
  return new Response(JSON.stringify({success:true,result}),{status:200});
 };
 return {calls,request};
}
test('missing Cloudflare credentials are reported without probing or exposing secrets',async()=>{
 const f=fakeFetcher(),res=await auditCloudflare({},f.request);
 assert.equal(res.ready,false);assert.equal(f.calls.length,0);
 assert(res.blockers.some(x=>x.includes('MISSING_CLOUDFLARE_API_TOKEN')));
 assert.equal(safeReport(res).includes('SECRET_PRIVATE_TOKEN'),false);
 assert(settingsCheck(env).length===0);
});
test('only read-only API GETs to the selected account establish a preliminary ready state',async()=>{
 const f=fakeFetcher(),r=await auditCloudflare(env,f.request);
 assert.equal(r.ready,true,JSON.stringify(r.blockers));
 assert.equal(r.blockers.length,0);
 assert.equal(f.calls.length,6);
 assert(f.calls.every(x=>x.method==='GET'&&x.url.includes('/accounts/'+env.CLOUDFLARE_ACCOUNT_ID+'/')));
 assert(f.calls.every(x=>x.authorization==='Bearer SECRET_PRIVATE_TOKEN'));
 assert.equal(safeReport(r).includes('SECRET_PRIVATE_TOKEN'),false);
 assert(safeReport(r).includes('REQUIRES_LIVE_VERIFICATION'));
});
test('wrong Worker and non-worker Access destinations cannot pass',async()=>{
 const wrong=fakeFetcher({mutate:(path,r)=>path.endsWith('/access/apps')?
  [{...access[0],destinations:[{type:'all_workers'}]}]:r});
 const s=await auditCloudflare(env,wrong.request);assert.equal(s.ready,false);
 assert(s.blockers.some(x=>x.includes('ACCESS_AUDIENCE')));
 assert.throws(()=>findAccessApplication(access,env.TT_FOTOS_ACCESS_AUD,'wrong-worker-id'));
});
test('public R2, wrong D1, or missing API permissions cannot pass',async()=>{
 const publicR2=fakeFetcher({mutate:(path,r)=>path.endsWith('/domains/managed')?{enabled:true}:r});
 assert.equal((await auditCloudflare(env,publicR2.request)).ready,false);
 const wrongD1=fakeFetcher({mutate:(path,r)=>path.includes('/d1/database/')?{...r,name:'production-db'}:r});
 assert.equal((await auditCloudflare(env,wrongD1.request)).ready,false);
 const denied=fakeFetcher({failedPath:'/accounts/'+env.CLOUDFLARE_ACCOUNT_ID+'/r2/buckets/tt-fotos-originals-private'});
 assert.equal((await auditCloudflare(env,denied.request)).ready,false);
 assert.throws(()=>verifyInventory({name:'tt-fotos-private'},{name:'tt-fotos-originals-private'},{enabled:true},{domains:[]}));
});

test('worker Access public-path overrides are rejected even when AUD and worker ID match',async()=>{
 const f=fakeFetcher({mutate:(path,value)=>path.endsWith('/access/apps')?
  [{...access[0],destinations:[{type:'worker',worker_id:worker.id,overrides:[{behavior:'public',path_pattern:'/*'}]}]}]:value});
 const result=await auditCloudflare(env,f.request);
 assert.equal(result.ready,false);
 assert(result.blockers.some(x=>x.includes('PUBLIC_ACCESS_DESTINATION_OVERRIDE')));
 assert.throws(()=>findAccessApplication(
  [{...access[0],destinations:[{type:'worker',worker_id:worker.id,overrides:[{behavior:'public',path_pattern:'/fotos'}]}]}],
  env.TT_FOTOS_ACCESS_AUD,worker.id));
});

test('readiness fails when Worker name cannot be uniquely resolved',async()=>{
 const absent=fakeFetcher({mutate:(path,value)=>path.endsWith('/workers/workers')?
   [{id:'not-tf',name:'unrelated-worker'}]:value});
 const missing=await auditCloudflare(env,absent.request);
 assert.equal(missing.ready,false);
 assert(missing.blockers.some(x=>x.includes('STANDALONE_WORKER')));
 const duplicates=fakeFetcher({mutate:(path,value)=>path.endsWith('/workers/workers')?
   [worker,{...worker,id:'other-worker-identifier'}]:value});
 const duplicate=await auditCloudflare(env,duplicates.request);
 assert.equal(duplicate.ready,false);
 assert(duplicate.blockers.some(x=>x.includes('STANDALONE_WORKER')));
});
