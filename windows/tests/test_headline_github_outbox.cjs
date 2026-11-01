'use strict';
// No network, no browser, no prompt or publication. GitHub Data API is mocked.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const crypto=require('node:crypto');
const github=require('../TTiTTularesGithubOutbox.cjs');
const task={command_id:'tt-img-example-r2-a1-123',target_id:'newsExact',
  revision:2,editorial_sha256:'e'.repeat(64)};
const row={event_id:'newsExact',revision:2,ai_image_attempt:1};
const raw=Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),Buffer.alloc(15000,95)]);
const original={dataUrl:'data:image/png;base64,'+raw.toString('base64'),
  width:1536,height:864,sha256:crypto.createHash('sha256').update(raw).digest('hex')};
test('Receipt contains one exact command, one raster, revision and editorial SHA',()=>{
 const r=github.buildReceipt(task,row,original);
 assert.equal(r.sha256,original.sha256);
 assert.equal(r.receipt.event_id,task.target_id);
 assert.equal(r.receipt.revision,2);
 assert.equal(r.receipt.ai_image.chunk_files[0],task.command_id+'.b64');
 assert.equal(r.receipt.ai_image.chunk_sha256,original.sha256);
 assert.equal(r.receipt.ai_image.context_guard.command_id,task.command_id);
 assert.equal(r.receipt.ai_image.context_guard.editorial_sha256,task.editorial_sha256);
 assert(!JSON.stringify(r.receipt).includes(original.dataUrl));
 assert.equal(Buffer.from(r.originalBase64,'base64').equals(raw),true);
});
test('Never permit another news item, revision or modified cached raster',()=>{
 assert.throws(()=>github.buildReceipt(task,{...row,event_id:'newsOther'},original),/context_mismatch/);
 assert.throws(()=>github.buildReceipt(task,{...row,revision:3},original),/context_mismatch/);
 assert.throws(()=>github.buildReceipt(task,row,{...original,sha256:'0'.repeat(64)}),/sha256_mismatch/);
});
test('One atomic GitHub commit holds original and receipt; no Cloudflare/ImageGen',async()=>{
 const calls=[];
 let blob=0;
 const request=async(method,endpoint,body,token)=>{
   calls.push({method,endpoint,body,token});
   assert.equal(token,'fake-test-token');
   if(endpoint.endsWith('/blobs'))return {sha:String(++blob).repeat(40)};
   if(endpoint.endsWith('ref/heads/main'))return {object:{sha:'3'.repeat(40)}};
   if(endpoint.endsWith('/commits/'+'3'.repeat(40)))return {tree:{sha:'4'.repeat(40)}};
   if(endpoint.endsWith('/trees'))return {sha:'5'.repeat(40)};
   if(endpoint.endsWith('/commits'))return {sha:'6'.repeat(40)};
   if(endpoint.endsWith('/refs/heads/main'))return {};
   throw Error('unexpected mocked API '+endpoint);
 };
 const result=await github.pushReceipt(task,row,original,{token:'fake-test-token',request});
 assert.equal(result.status,'committed');
 assert.equal(result.sha256,original.sha256);
 assert.equal(calls.filter(x=>x.method==='PATCH').length,1);
 const tree=calls.find(x=>x.endpoint.endsWith('/trees')).body;
 assert.equal(tree.tree.length,2);
 assert.deepEqual(tree.tree.map(x=>x.path).sort(),[
   'ttittulares/image-outbox/'+task.command_id+'.b64',
   'ttittulares/image-outbox/'+task.command_id+'.json']);
 assert.equal(tree.base_tree,'4'.repeat(40));
 const meta=JSON.parse(calls.filter(x=>x.endpoint.endsWith('/blobs'))[1].body.content);
 assert.equal(meta.command_id,task.command_id);
 assert.equal(meta.ai_image.chunk_mime,'image/png');
 assert.equal(calls.some(x=>x.endpoint.includes('cloudflare')),false);
});
test('GitHub non-fast-forward conflict refetches main without regenerating blobs',async()=>{
 let blobs=0,patch=0;
 const request=async(method,url)=>{
   if(url.endsWith('/blobs')){blobs++;return {sha:String(blobs).repeat(40)}}
   if(url.endsWith('/ref/heads/main'))return {object:{sha:'3'.repeat(40)}};
   if(url.endsWith('/commits/'+'3'.repeat(40)))return {tree:{sha:'4'.repeat(40)}};
   if(url.endsWith('/trees'))return {sha:'5'.repeat(40)};
   if(url.endsWith('/commits'))return {sha:'6'.repeat(40)};
   if(url.endsWith('/refs/heads/main')){
     if(++patch===1){const e=Error('conflict');e.status=422;throw e;}
     return {};
   }
   throw Error('unexpected');
 };
 const result=await github.pushReceipt(task,row,original,{token:'test',request});
 assert.equal(result.status,'committed');
 assert.equal(blobs,2);
 assert.equal(patch,2);
});
