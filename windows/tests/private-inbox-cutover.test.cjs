'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {
  NEWS_CUTOFF,allowedTop30,inCurrentApprovalScope,selectCurrentTasks,
}=require('../TTImageApprovalReceiver.cjs');

test('only current Top30 editorial episodes and news prepared after 09:43 Paris are eligible',async()=>{
 const body={items:[{editorial_id:'trend-current',revision:1,explanation:'verificada'},
    {editorial_id:'pending',revision:0,explanation:''}]};
 const ids=await allowedTop30(async()=>Response.json(body));
 assert.equal(ids.size,1);
 assert(inCurrentApprovalScope({project:'ttendencias',target_id:'trend-current',revision:1},ids));
 assert(!inCurrentApprovalScope({project:'ttendencias',target_id:'trend-current',revision:0},ids));
 assert(!inCurrentApprovalScope({project:'ttendencias',target_id:'other',revision:1},ids));
 assert(!inCurrentApprovalScope({project:'ttendencias',target_id:'pending',revision:0},ids));
 assert(inCurrentApprovalScope({project:'ttittulares',created_at:'2026-11-06T08:43:01Z'},ids));
 assert(!inCurrentApprovalScope({project:'ttittulares',created_at:'2026-11-06T08:42:59Z'},ids));
 assert(!inCurrentApprovalScope({project:'ttittulares',created_at:''},ids));
 assert.equal(NEWS_CUTOFF,Date.parse('2026-11-06T08:43:00.000Z'));
});

test('closed trend snapshot is fail closed, without retrying all historical images',async()=>{
 const result=await allowedTop30(async()=>{throw Error('offline')});
 assert.equal(result,null);
 assert(!inCurrentApprovalScope({project:'ttendencias',target_id:'trend-current',revision:1},result));
});

test('no more than eight jobs selected, only eligible ones, no 500-job flood',()=>{
 const scope=new Set(['trend-current:r1']);
 const tasks=[
  ...Array.from({length:500},(_,i)=>({project:'ttittulares',target_id:'old-'+i,
    revision:0,command_id:'old-'+i,created_at:'2026-11-05T09:00:00Z'})),
  {project:'ttendencias',target_id:'trend-current',revision:1,command_id:'current-1'},
  {project:'ttendencias',target_id:'trend-old',revision:1,command_id:'old-trend'},
  {project:'ttittulares',target_id:'news-new',revision:0,command_id:'news-new',
   created_at:'2026-11-06T08:43:05Z'},
 ];
 const eligible=tasks.filter(t=>inCurrentApprovalScope(t,scope));
 assert.equal(eligible.length,2);
 const chosen=selectCurrentTasks(eligible,{},new Set(['ttendencias:trend-current:1']));
 assert.equal(chosen.length,2);
 assert(chosen.every(x=>['current-1','news-new'].includes(x.command_id)));
});
