'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const crypto=require('node:crypto'),fs=require('node:fs'),path=require('node:path');
for(const filename of ['TTImageApprovalReceiver.cjs','TTendenciasWebImages.cjs','TTiTTularesWebImages.cjs']){
 console.log('PRIVATE_INBOX_FILE_SHA256 '+filename+'='+crypto.createHash('sha256')
   .update(fs.readFileSync(path.join(__dirname,'..',filename))).digest('hex'));
}
const {allowedTop30,inCurrentApprovalScope,selectCurrentTasks,activeIdentities}=require('../TTImageApprovalReceiver.cjs');

test('top30 current editorial episode and any-age READY/Listas news are eligible',async()=>{
 const body={items:[{editorial_id:'trend-current',revision:1,explanation:'verificada'},
                    {editorial_id:'pending',revision:0,explanation:''}]};
 const top30=await allowedTop30(async()=>Response.json(body));
 const ready=new Set(['ttittulares:old-ready:2','ttittulares:new-ready:1']);
 assert.equal(top30.size,1);
 assert(inCurrentApprovalScope({project:'ttendencias',target_id:'trend-current',revision:1},top30,ready));
 assert(!inCurrentApprovalScope({project:'ttendencias',target_id:'trend-current',revision:0},top30,ready));
 assert(!inCurrentApprovalScope({project:'ttendencias',target_id:'pending',revision:0},top30,ready));
 assert(inCurrentApprovalScope({project:'ttittulares',target_id:'old-ready',revision:2,
   created_at:'2026-10-28T09:00:00Z'},top30,ready));
 assert(inCurrentApprovalScope({project:'ttittulares',target_id:'new-ready',revision:1,
   created_at:'2026-11-07T09:00:00Z'},top30,ready));
 assert(!inCurrentApprovalScope({project:'ttittulares',target_id:'old-ready',revision:1},top30,ready));
 assert(!inCurrentApprovalScope({project:'ttittulares',target_id:'closed',revision:1},top30,ready));
 assert(!inCurrentApprovalScope({project:'ttittulares',target_id:'old-ready',revision:2},top30,null));
});

test('missing Top30 snapshot fails closed without resurrecting historical trends',async()=>{
 const top30=await allowedTop30(async()=>{throw Error('offline')});
 assert.equal(top30,null);
 assert(!inCurrentApprovalScope({project:'ttendencias',target_id:'trend-current',revision:1},top30,new Set()));
});

test('500 obsolete news jobs never flood the inbox: only exact READY/Listas jobs enter',()=>{
 const top30=new Set(['trend-current:r1']);
 const ready=new Set(['ttittulares:news-old:0','ttittulares:news-new:1']);
 const tasks=[
  ...Array.from({length:500},(_,i)=>({project:'ttittulares',target_id:'closed-'+i,
      revision:0,command_id:'closed-'+i,created_at:'2026-10-25T09:00:00Z'})),
  {project:'ttendencias',target_id:'trend-current',revision:1,command_id:'trend-current'},
  {project:'ttendencias',target_id:'trend-removed',revision:1,command_id:'trend-removed'},
  {project:'ttittulares',target_id:'news-old',revision:0,command_id:'news-old',
    created_at:'2026-10-27T09:00:00Z'},
  {project:'ttittulares',target_id:'news-new',revision:1,command_id:'news-new',
    created_at:'2026-11-07T09:00:00Z'},
 ];
 const eligible=tasks.filter(t=>inCurrentApprovalScope(t,top30,ready));
 assert.equal(eligible.length,3);
 const chosen=selectCurrentTasks(eligible,{},ready);
 assert.equal(chosen.length,3);
 assert.deepEqual(chosen.map(x=>x.command_id).sort(),['news-new','news-old','trend-current']);
});

test('news closed or older revision excluded; age alone never removes current READY',()=>{
 const prepared={items:[
  {event_id:'old-ready',revision:1,prepared_at:'2026-10-27T09:00:00Z'},
  {event_id:'closed',revision:1,prepared_at:'2026-11-07T10:00:00Z'},
  {event_id:'newer',revision:2,prepared_at:'2026-11-07T09:00:00Z'},
  {event_id:'newer',revision:1,prepared_at:'2026-11-06T09:00:00Z'}
 ]};
 const active=activeIdentities('ttittulares',prepared,
      {items:[{event_id:'closed',revision:1,status:'published'}]});
 assert(active.has('ttittulares:old-ready:1'));
 assert(active.has('ttittulares:newer:2'));
 assert(!active.has('ttittulares:newer:1'));
 assert(!active.has('ttittulares:closed:1'));
});
