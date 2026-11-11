import test from 'node:test';
import assert from 'node:assert/strict';
import {checkPrivateR2Responses,verifyPrivateR2Environment} from '../scripts/verify-private-r2.mjs';
const env={CLOUDFLARE_ACCOUNT_ID:'a'.repeat(32),CLOUDFLARE_API_TOKEN:'private-test-token'};
test('private bucket requires disabled r2.dev plus no enabled custom domains',()=>{
 assert.equal(checkPrivateR2Responses({enabled:false},{domains:[]}).private,true);
 assert.equal(checkPrivateR2Responses({enabled:false},{domains:[{domain:'archive.example.test',enabled:false}]}).private,true);
 for(const managed of [null,{}, {enabled:true},{enabled:null},{enabled:0}]){
  assert.throws(()=>checkPrivateR2Responses(managed,{domains:[]}));
 }
 for(const custom of [null,{}, {domains:null},{domains:[{enabled:true}]},{domains:[{enabled:null}]},{domains:[{}]}]){
  assert.throws(()=>checkPrivateR2Responses({enabled:false},custom));
 }
});
test('private API check uses only GET requests to the two TT Fotos bucket domain endpoints',async()=>{
 const urls=[];
 const response=await verifyPrivateR2Environment(env,async(url,options)=>{
  urls.push({url,options});
  const result=url.endsWith('/managed')?{enabled:false}:{domains:[]};
  return new Response(JSON.stringify({success:true,result}),{status:200});
 });
 assert.equal(response.private,true);
 assert.equal(urls.length,2);
 assert(urls.every(x=>x.options.method==='GET'&&x.url.includes('/r2/buckets/tt-fotos-originals-private/domains/')));
 assert(urls.every(x=>x.options.headers.Authorization==='Bearer private-test-token'));
 assert(!urls.some(x=>x.url.includes('ttactualidad')));
});
test('missing token, unexpected Cloudflare response, and public bucket fail closed',async()=>{
 await assert.rejects(()=>verifyPrivateR2Environment({...env,CLOUDFLARE_API_TOKEN:''},async()=>{throw Error('should not request')}));
 await assert.rejects(()=>verifyPrivateR2Environment(env,async()=>new Response('{}',{status:403})));
 await assert.rejects(()=>verifyPrivateR2Environment(env,async()=>new Response(JSON.stringify({success:false,result:{}}))));
 await assert.rejects(()=>verifyPrivateR2Environment(env,async(url)=>{
  return new Response(JSON.stringify({success:true,result:url.endsWith('/managed')?{enabled:true}:{domains:[]}}));
 }));
});
