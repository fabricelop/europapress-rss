'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const os=require('node:os');
const crypto=require('node:crypto');
const immediate=require('../TTImagesImmediateInbox.cjs');
const sha=x=>crypto.createHash('sha256').update(x).digest('hex');
const png=Buffer.concat([Buffer.from('89504e470d0a1a0a','hex'),Buffer.alloc(256,42)]);
const secret='test-only-secret-must-have-32-characters';
function fixture(project='ttendencias'){
 const tmp=fs.mkdtempSync(path.join(os.tmpdir(),'tt-immediate-'));
 const job={command_id:'job-1234',target_id:'target-1234',revision:2,
  context_snapshot:project==='ttendencias'?
   {explanation:'Una tendencia precisa',explained_at:'2026-11-09T00:20:00Z'}:
   {tweet_text:'Una noticia verificada',factual_summary:'Hechos completos',remate:'Un remate',
    prepared_at:'2026-11-09T00:20:00Z'}};
 let sent=0,saved=0,discarded=0,cache=null;
 const source={rasterProbe:id=>{assert.equal(id,'job-1234');return 'exact-probe';},
  readImageJob:async()=>job};
 const receiver={
  editorialJob:async()=>job,
  metadata:(task,j)=>{assert.equal(j.command_id,task.command_id);return {
    project,editorialId:task.target_id,revision:task.revision,
    episodeFingerprint:'episode-exact'};},
  cachedOriginal:()=>cache,
  persistOriginal:(_base,task,_meta,bytes)=>{
   assert.equal(task.command_id,'job-1234');saved++;
   cache=Buffer.from(bytes);
   const dir=path.join(tmp,'image-approval-receipts','original-cache');
   fs.mkdirSync(dir,{recursive:true});
   fs.writeFileSync(path.join(dir,'job-1234.json'),'cached');},
  send:async(meta,bytes,key)=>{
   assert.equal(key,secret);assert.equal(meta.project,project);
   assert.deepEqual(bytes,png);sent++;
   return {id:'a'.repeat(64),state:'pending',rasterSHA256:sha(bytes)};},
  discardOriginal:()=>{discarded++;cache=null;}
 };
 let ready=true;
 const cdp={call:async(method,options,timeout)=>{
   assert.equal(method,'Runtime.evaluate');assert.equal(options.expression,'exact-probe');
   assert.equal(options.awaitPromise,true);assert.ok(timeout>=20000);
   return {result:{value:ready?{ready:true,dataUrl:'data:image/png;base64,'+png.toString('base64')}:
     {ready:false,reason:'generating'}}};
 }};
 const run=()=>immediate.deliver({project,job,commandId:'job-1234',targetId:'target-1234',
  secret,cdp,baseDir:tmp,dependencies:{receiver,source}});
 return {tmp,job,run,receiver,source,setReady:v=>{ready=v;},
   counts:()=>({sent,saved,discarded})};
}
for(const project of ['ttendencias','ttittulares']){
 test(project+': original is ingested once during generator process; no approval',async()=>{
  const f=fixture(project);
  try{
   const first=await f.run();
   assert.equal(first.state,'received');assert.match(first.reason,/private_inbox_pending/);
   assert.deepEqual(f.counts(),{sent:1,saved:1,discarded:1});
   const receipt=immediate.readReceipt(f.tmp,{
    command_id:'job-1234',target_id:'target-1234',revision:2});
   assert.equal(receipt.state,'pending');
   assert.equal(receipt.rasterSHA256,sha(png));
   const again=await f.run();
   assert.equal(again.state,'received');assert.equal(f.counts().sent,1);
  }finally{fs.rmSync(f.tmp,{recursive:true,force:true});}
 });
 test(project+': not-yet-generated image never reaches inbox',async()=>{
  const f=fixture(project);
  try{
   f.setReady(false);
   const state=await f.run();
   assert.equal(state.state,'waiting');
   assert.equal(state.reason,'generating');
   assert.deepEqual(f.counts(),{sent:0,saved:0,discarded:0});
  }finally{fs.rmSync(f.tmp,{recursive:true,force:true});}
 });
 test(project+': failed private upload keeps original for retry',async()=>{
  const f=fixture(project);
  try{
   const prior=f.receiver.send;
   f.receiver.send=async()=>{throw Error('PRIVATE_RECEIPT_NETWORK_UNAVAILABLE');};
   await assert.rejects(f.run(),/PRIVATE_RECEIPT_NETWORK_UNAVAILABLE/);
   assert.equal(f.counts().saved,1);
   f.receiver.send=prior;f.setReady(false);
   const result=await f.run();
   assert.equal(result.state,'received');
   assert.equal(f.counts().sent,1);
  }finally{fs.rmSync(f.tmp,{recursive:true,force:true});}
 });
}
test('wrong exact command or missing editorial identity is rejected before capture',()=>{
 const job={command_id:'different',target_id:'target-1234',revision:2,
  context_snapshot:{explanation:'Text'}};
 assert.throws(()=>immediate.makeTask('ttendencias',job,'job-1234','target-1234'),
   /IMMEDIATE_IMAGE_JOB_MISMATCH/);
 assert.throws(()=>immediate.makeTask('ttendencias',{...job,command_id:'job-1234',
  context_snapshot:{}},'job-1234','target-1234'),/IMMEDIATE_IMAGE_EDITORIAL_MISSING/);
});
test('existing private receipt must match command, target, revision and hash',()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'tt-receipt-'));
 try{
  const task={command_id:'job-1234',target_id:'target-1234',revision:2};
  immediate.saveReceipt(dir,task,{},{id:'b'.repeat(64),rasterSHA256:sha(png),state:'pending'});
  assert(immediate.readReceipt(dir,task));
  assert.equal(immediate.readReceipt(dir,{...task,revision:3}),null);
  assert.equal(immediate.readReceipt(dir,{...task,target_id:'other'}),null);
 }finally{fs.rmSync(dir,{recursive:true,force:true});}
});
test('both bridges retain old fallback and same-process private transfer wiring',()=>{
 const root=path.join(__dirname,'..');
 for(const file of ['TTendenciasImageBridge.js','TTiTTularesImageBridge.js']){
  const src=fs.readFileSync(path.join(root,file),'utf8');
  assert.match(src,/require\('\.\/TTImagesImmediateInbox\.cjs'\)\.deliver/);
  assert.match(src,/PRIVATE_INBOX_IMMEDIATE_RECEIVED/);
  assert.match(src,/PRIVATE_ORIGINAL_RECEIVED/);
  assert.match(src,/manual_approval_required/);
  assert.match(src,/await confirmPromptLaunched\(\)/);
 }
 const updater=fs.readFileSync(path.join(root,'TT-AutoUpdater.ps1'),'utf8');
 assert(updater.indexOf('windows/TTImagesImmediateInbox.cjs')<
        updater.indexOf('windows/TTendenciasImageBridge.js'));
 assert(updater.indexOf('windows/TTImagesImmediateInbox.cjs')<
        updater.indexOf('windows/TTiTTularesImageBridge.js'));
});
