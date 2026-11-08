'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {
  allowedTop30,inCurrentApprovalScope,provesTop30AtImageCreation,
  selectCurrentTasks,MAX_IMAGE_AGE_MS,MAX_ORIGINAL_CHECKS_PER_CYCLE
}=require('../TTImageApprovalReceiver.cjs');
const NOW=Date.parse('2026-11-08T21:00:00Z');
const task=(project,id,ageHours=1,revision=1)=>({
  project,target_id:id,revision,command_id:project+'-'+id+'-r'+revision,
  status:'waiting',secret_dpapi:'encrypted-credential',
  created_at:new Date(NOW-ageHours*3600000).toISOString()
});

test('Top30 membership includes explained and not-yet-explained rows',async()=>{
  const top30=await allowedTop30(async()=>Response.json({items:[
    {editorial_id:'current',revision:1,explanation:'Texto'},
    {editorial_id:'not-yet-explained',revision:0,explanation:''}
  ]}));
  assert(top30.has('current:r1'));
  assert(top30.has('not-yet-explained:r0'));
});

test('any news currently in Listas is eligible regardless of publication state or revision',()=>{
  const listas=new Set(['renfe','paraguay']);
  assert(inCurrentApprovalScope(task('ttittulares','renfe'),null,listas,NOW));
  assert(inCurrentApprovalScope(task('ttittulares','paraguay',1,0),null,listas,NOW));
  assert(!inCurrentApprovalScope(task('ttittulares','not-in-listas'),null,listas,NOW));
  assert(!inCurrentApprovalScope(task('ttittulares','renfe'),null,null,NOW));
});

test('current Top30 remains eligible; historic Top30 is allowed if original job proves its rank',()=>{
  const snapshot=new Set(['current:r1']);
  const present=task('ttendencias','current');
  const exited=task('ttendencias','former');
  assert(inCurrentApprovalScope(present,snapshot,null,NOW));
  assert(inCurrentApprovalScope(exited,snapshot,null,NOW));
  assert(provesTop30AtImageCreation(present,{},snapshot));
  const goodJob={
    command_id:exited.command_id,target_id:exited.target_id,revision:1,
    context_snapshot:{rank_at_explanation:18}
  };
  assert(provesTop30AtImageCreation(exited,goodJob,snapshot));
  assert(!provesTop30AtImageCreation(exited,{...goodJob,
    context_snapshot:{rank_at_explanation:35}},snapshot));
  assert(!provesTop30AtImageCreation(exited,{...goodJob,
    target_id:'other'},snapshot));
  assert(!provesTop30AtImageCreation(exited,{...goodJob,
    command_id:'wrong-command'},snapshot));
});

test('48h recency is sole retrospective cutoff and not a ban on new jobs',()=>{
  const listas=new Set(['renfe']);
  assert(inCurrentApprovalScope(task('ttittulares','renfe',47.99),null,listas,NOW));
  assert(inCurrentApprovalScope(task('ttittulares','renfe',48),null,listas,NOW));
  assert(!inCurrentApprovalScope(task('ttittulares','renfe',48.01),null,listas,NOW));
  assert(!inCurrentApprovalScope(task('ttittulares','renfe',240),null,listas,NOW));
  assert(!inCurrentApprovalScope(task('ttittulares','renfe',-2),null,listas,NOW));
  assert.equal(MAX_IMAGE_AGE_MS,48*3600000);
});

test('600 old jobs do not flood inbox; 16 eligible checks maximum per cycle, no dropped candidates',()=>{
  const listas=new Set(['renfe']);
  const old=Array.from({length:600},(_,i)=>task('ttittulares','old'+i,49+i/1000));
  const fresh=Array.from({length:33},(_,i)=>task('ttendencias','trend'+i,2+i/100));
  const valid=[task('ttittulares','renfe',1),...fresh];
  const eligible=[...old,...valid].filter(t=>inCurrentApprovalScope(t,null,listas,NOW));
  assert.equal(eligible.length,34);
  const first=selectCurrentTasks(eligible,{},new Set());
  assert.equal(first.length,MAX_ORIGINAL_CHECKS_PER_CYCLE);
  const after=Object.fromEntries(first.map(t=>[t.command_id,{checkedAt:NOW}]));
  const second=selectCurrentTasks(eligible,after,new Set());
  assert.equal(second.length,MAX_ORIGINAL_CHECKS_PER_CYCLE);
  assert(second.some(x=>!first.some(y=>x.command_id===y.command_id)));
  assert.equal(new Set(eligible.map(t=>t.command_id)).size,34);
});

test('enrollment requires real identity and key; delivered duplicate never reentered',()=>{
  const t=task('ttendencias','current');
  assert(inCurrentApprovalScope(t,new Set(['current:r1']),null,NOW));
  assert(!inCurrentApprovalScope({...t,status:'published'},null,null,NOW));
  assert(!inCurrentApprovalScope({...t,secret_dpapi:''},null,null,NOW));
  assert(!inCurrentApprovalScope({...t,revision:-1},null,null,NOW));
});

test('Chrome safety stays at one newly opened relay tab per cycle',()=>{
  const fs=require('node:fs'),path=require('node:path');
  const code=fs.readFileSync(path.join(__dirname,'../TTImageApprovalReceiver.cjs'),'utf8');
  assert.match(code,/MAX_NEW_RELAY_TABS_PER_CYCLE=1/);
  assert.match(code,/RELAY_TAB_BUDGET/);
  assert.match(code,/scope:'listas_and_current_or_at_creation_top30_images_max_48h'/);
  assert.match(code,/provesTop30AtImageCreation\(task,job,top30\)/);
});
