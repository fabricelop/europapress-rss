'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),crypto=require('node:crypto');
const mod=require('./TTFotosRecover.cjs');
const digest=b=>crypto.createHash('sha256').update(b).digest('hex');
const fakePNG=Buffer.concat([Buffer.from('89504e470d0a1a0a','hex'),Buffer.alloc(32,8)]);
const id='a'.repeat(64),fingerprint='b'.repeat(64);
const task={project:'ttittulares',target_id:'123456789abc',command_id:'tt-img-test-123456789abc-r1',revision:1,
  created_at:'2026-11-11T14:00:00Z',status:'waiting',secret_dpapi:'sealed'};
function fixture(){
 const base=fs.mkdtempSync(path.join(os.tmpdir(),'tt-fotos-'));
 const folders=['ttittulares-web-images','image-approval-receipts',
   'image-approval-receipts/immediate-originals'];
 for(const f of folders)fs.mkdirSync(path.join(base,f),{recursive:true});
 fs.writeFileSync(path.join(base,'ttittulares-web-images',task.command_id+'.json'),JSON.stringify(task));
 const root=path.join(base,'image-approval-receipts');
 const staged=path.join(root,'immediate-originals',task.command_id+'.png');
 const stagedMeta=path.join(root,'immediate-originals',task.command_id+'.json');
 fs.writeFileSync(staged,fakePNG);
 fs.writeFileSync(stagedMeta,JSON.stringify({commandId:task.command_id}));
 return {base,root,staged};
}
function deps(overrides={}){
 const meta={project:'ttittulares',editorialId:task.target_id,revision:1,
   commandId:task.command_id,episodeFingerprint:fingerprint};
 let sends=0,lookups=0;
 const receiver={
   async editorialJob(){lookups++;return {command_id:task.command_id,target_id:task.target_id,revision:1}},
   metadata(){return {...meta}},
   send:async(_meta,bytes)=>{sends++;return {id,rasterSHA256:digest(bytes),state:'pending'}},
   cachedOriginal:()=>null,
 };
 const immediate={loadStaged:()=>fakePNG};
 return {source:{},receiver:{...receiver,...overrides},immediate,unprotect:()=>('x'.repeat(40)),
   counts:()=>({sends,lookups})};
}
test('inventory includes exact cached original but not a delivery',t=>{
 const x=fixture();t.after(()=>fs.rmSync(x.base,{recursive:true,force:true}));
 const r=mod.scan(x.base);
 assert.equal(r.summary.enrolled,1);assert.equal(r.summary.received,0);
 assert.equal(r.summary.cachedPending,1);assert.equal(r.items[0].hasSecret,true);
 assert(!JSON.stringify(mod.publicReport(r)).includes('sealed'));
});
test('an orphan PNG cannot be assigned by title or guess',t=>{
 const x=fixture();t.after(()=>fs.rmSync(x.base,{recursive:true,force:true}));
 fs.writeFileSync(path.join(x.root,'immediate-originals','orphan-unknown.png'),fakePNG);
 assert.equal(mod.scan(x.base).summary.orphanPNG,1);
});
test('only exact original with matching episode gets a private receipt',async t=>{
 const x=fixture();t.after(()=>fs.rmSync(x.base,{recursive:true,force:true}));
 const item=mod.scan(x.base).items[0],env=deps();
 const r=await mod.recoverOne(x.base,item,env);
 assert.equal(r.state,'DELIVERED_CONFIRMED_LOCAL');
 assert.equal(mod.scan(x.base).summary.received,1);
 assert.equal(env.counts().sends,1);
 assert(fs.existsSync(x.staged),'do not delete original cache');
 await assert.rejects(()=>mod.recoverOne(x.base,item,env),/RECEIPT_ALREADY_EXISTS/);
 assert.equal(env.counts().sends,1,'must not send twice');
});
test('mismatching episode never reaches the inbox',async t=>{
 const x=fixture();t.after(()=>fs.rmSync(x.base,{recursive:true,force:true}));
 const item=mod.scan(x.base).items[0];
 const env=deps({metadata:()=>({project:'ttittulares',editorialId:task.target_id,
    revision:0,commandId:task.command_id,episodeFingerprint:fingerprint})});
 await assert.rejects(()=>mod.recoverOne(x.base,item,env),/EPISODE_MISMATCH/);
 assert.equal(env.counts().sends,0);
});
test('rejection by private server does not create false receipt',async t=>{
 const x=fixture();t.after(()=>fs.rmSync(x.base,{recursive:true,force:true}));
 const item=mod.scan(x.base).items[0];
 const env=deps({send:async (_meta,bytes)=>({state:'rejected',id,rasterSHA256:digest(bytes)})});
 await assert.rejects(()=>mod.recoverOne(x.base,item,env),/PRIVATE_RECEIPT_NOT_PROVEN/);
 assert.equal(mod.scan(x.base).summary.received,0);assert(fs.existsSync(x.staged));
});
test('existing malformed receipt blocks automatic replay',t=>{
 const x=fixture();t.after(()=>fs.rmSync(x.base,{recursive:true,force:true}));
 fs.writeFileSync(path.join(x.root,task.command_id+'.json'),JSON.stringify({
   commandId:task.command_id,project:'ttendencias',editorialId:task.target_id,revision:1,id,
   rasterSHA256:digest(fakePNG)
 }));
 assert.equal(mod.scan(x.base).summary.conflict,1);
});


test('manual recovery is not blocked by an active scheduled receiver lock',async t=>{
  const x=fixture();t.after(()=>fs.rmSync(x.base,{recursive:true,force:true}));
  fs.writeFileSync(path.join(x.root,'receiver.lock'),JSON.stringify({pid:123456,at:Date.now()}));
  const env=deps();
  const map={
    'TTImageApprovalReceiver.cjs':env.receiver,
    'TTImagesImmediateInbox.cjs':env.immediate,
    'TTendenciasWebImages.cjs':env.source,
    'TTiTTularesWebImages.cjs':env.source
  };
  const result=await mod.applyCached(x.base,{
    dependencyLoader:name=>map[name],unprotect:env.unprotect,
    send:env.receiver.send
  });
  assert.equal(result.after.received,1);
  assert.equal(env.counts().sends,1);
  assert(fs.existsSync(path.join(x.root,'receiver.lock')),'must not remove scheduled receiver lock');
});
test('if the scheduled receiver wins the race, its exact receipt is accepted',async t=>{
  const x=fixture();t.after(()=>fs.rmSync(x.base,{recursive:true,force:true}));
  const item=mod.scan(x.base).items[0];
  const env=deps();
  const same=async (_meta,bytes)=>{
    const receipt={project:task.project,commandId:task.command_id,editorialId:task.target_id,
      revision:1,id,rasterSHA256:digest(bytes),state:'pending'};
    fs.writeFileSync(path.join(x.root,task.command_id+'.json'),JSON.stringify(receipt));
    return {id,rasterSHA256:digest(bytes),state:'pending'};
  };
  const result=await mod.recoverOne(x.base,item,{...env,send:same});
  assert.equal(result.state,'ALREADY_DELIVERED_BY_RECEIVER');
  assert.equal(mod.scan(x.base).summary.received,1);
});
test('a conflicting receipt for one command cannot stop recovery of other commands',async t=>{
  const x=fixture();t.after(()=>fs.rmSync(x.base,{recursive:true,force:true}));
  fs.writeFileSync(path.join(x.root,task.command_id+'.json'),JSON.stringify({
    commandId:task.command_id,project:'ttendencias',editorialId:task.target_id,
    revision:1,id,rasterSHA256:digest(fakePNG)}));
  const other={...task,command_id:'tt-img-another-123456789abc-r1'};
  fs.writeFileSync(path.join(x.base,'ttittulares-web-images',other.command_id+'.json'),JSON.stringify(other));
  fs.writeFileSync(path.join(x.root,'immediate-originals',other.command_id+'.png'),fakePNG);
  fs.writeFileSync(path.join(x.root,'immediate-originals',other.command_id+'.json'),JSON.stringify({commandId:other.command_id}));
  const env=deps({editorialJob:async(_source,job)=>({command_id:job.command_id,target_id:job.target_id,revision:1}),
    metadata:job=>({project:'ttittulares',editorialId:job.target_id,
      revision:1,commandId:job.command_id,episodeFingerprint:fingerprint})});
  // metadata uses task object in production; for this stub it receives the task.
  const map={'TTImageApprovalReceiver.cjs':env.receiver,'TTImagesImmediateInbox.cjs':env.immediate,
    'TTendenciasWebImages.cjs':env.source,'TTiTTularesWebImages.cjs':env.source};
  const result=await mod.applyCached(x.base,{dependencyLoader:n=>map[n],
    unprotect:env.unprotect,send:env.receiver.send});
  assert.equal(result.before.conflict,1);
  assert.equal(result.after.received,1);
  assert.equal(env.counts().sends,1);
});
