'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {
  inCurrentApprovalScope,provesExactNewImageJob,isNewImageJob,
  selectCurrentTasks,MAX_ORIGINAL_CHECKS_PER_CYCLE,IMAGE_INBOX_CUTOVER_UTC
}=require('../TTImageApprovalReceiver.cjs');
const CUTOVER=Date.parse(IMAGE_INBOX_CUTOVER_UTC);
const NOW=CUTOVER+3600000;
const date=ms=>new Date(ms).toISOString();
const task=(project,id,created=CUTOVER+1000,revision=1)=>({
 project,target_id:id,revision,command_id:project+'-'+id+'-r'+revision,
 status:'waiting',secret_dpapi:'encrypted-credential',created_at:date(created)
});
const job=(t,requested=CUTOVER+1000)=>({
 command_id:t.command_id,target_id:t.target_id,revision:t.revision,
 requested_at:date(requested),context_snapshot:{rank_at_explanation:99}
});

test('only new image jobs enter the private inbox: hard cutover, never older backlog',()=>{
 const news=task('ttittulares','news',CUTOVER);
 const trend=task('ttendencias','trend',CUTOVER);
 assert(inCurrentApprovalScope(news,null,null,NOW));
 assert(inCurrentApprovalScope(trend,null,null,NOW));
 assert(!inCurrentApprovalScope({...news,created_at:date(CUTOVER-1)},null,new Set(['news']),NOW));
 assert(!inCurrentApprovalScope({...trend,created_at:date(CUTOVER-1)},new Set(['trend:r1']),null,NOW));
 assert(!isNewImageJob(job(trend,CUTOVER-1)));
 assert(isNewImageJob(job(trend,CUTOVER)));
 assert(!isNewImageJob({...job(trend),requested_at:null}));
});

test('image from news outside Listas is eligible, without publishing the news',()=>{
 const n=task('ttittulares','not-in-listas');
 assert(inCurrentApprovalScope(n,null,new Set(),NOW));
 assert(provesExactNewImageJob(n,job(n)));
});
test('image from trend outside Top 30 is eligible, without Top30 origin proof',()=>{
 const t=task('ttendencias','never-ranked');
 assert(inCurrentApprovalScope(t,new Set(),null,NOW));
 assert(provesExactNewImageJob(t,job(t)));
});
test('exact new command and revision still mandatory even when editorial scope is ignored',()=>{
 const t=task('ttendencias','trend');
 assert(!provesExactNewImageJob(t,{...job(t),command_id:'wrong-command'}));
 assert(!provesExactNewImageJob(t,{...job(t),target_id:'wrong-target'}));
 assert(!provesExactNewImageJob(t,{...job(t),revision:2}));
 assert(!provesExactNewImageJob(t,job(t,CUTOVER-1)), 'legacy image never recovered');
});
test('missing secrets, invalid identity, closed handoff and future clock are rejected',()=>{
 const t=task('ttendencias','trend');
 assert(!inCurrentApprovalScope({...t,secret_dpapi:''},null,null,NOW));
 assert(!inCurrentApprovalScope({...t,status:'published'},null,null,NOW));
 assert(!inCurrentApprovalScope({...t,revision:-1},null,null,NOW));
 assert(!inCurrentApprovalScope({...t,command_id:'../bad'},null,null,NOW));
 assert(!inCurrentApprovalScope({...t,created_at:date(NOW+70000)},null,null,NOW));
});
test('no historical flood; max 16 checks per cycle with rotation, independent of rank',()=>{
 const old=Array.from({length:600},(_,i)=>task('ttittulares','old'+i,CUTOVER-1000-i));
 const fresh=Array.from({length:33},(_,i)=>task('ttendencias','trend'+i,CUTOVER+1+i));
 const eligible=[...old,...fresh].filter(x=>inCurrentApprovalScope(x,null,null,NOW));
 assert.equal(eligible.length,33);
 const first=selectCurrentTasks(eligible,{},null);
 assert.equal(first.length,MAX_ORIGINAL_CHECKS_PER_CYCLE);
 const checked=Object.fromEntries(first.map(x=>[x.command_id,{checkedAt:NOW}]));
 const second=selectCurrentTasks(eligible,checked,null);
 assert(second.some(x=>!first.some(y=>y.command_id===x.command_id)));
});
test('receiver makes no Listas/Top30 request in production path and preserves Chrome safety',()=>{
 const fs=require('node:fs'),path=require('node:path');
 const source=fs.readFileSync(path.join(__dirname,'../TTImageApprovalReceiver.cjs'),'utf8');
 const runtime=source.slice(source.indexOf('async function once('));
 assert.doesNotMatch(runtime,/allowedTop30\(/);
 assert.doesNotMatch(runtime,/listNews\?\.has\(/);
 assert.doesNotMatch(runtime,/provesTop30AtImageCreation/);
 assert.match(runtime,/provesExactNewImageJob\(task,job\)/);
 assert.match(runtime,/MAX_NEW_RELAY_TABS_PER_CYCLE=1/);
 assert.match(runtime,/RELAY_TAB_BUDGET/);
 assert.match(runtime,/scope:'new_image_jobs_only_no_listas_or_top30'/);
 assert.match(runtime,/cutoverUtc:IMAGE_INBOX_CUTOVER_UTC/);
});
