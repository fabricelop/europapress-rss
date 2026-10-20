import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

for(const path of ['pilot/ttactualidad-live/index.html','docs/ttactualidad/index.html']){
 const html=readFileSync(path,'utf8');
 const begin=html.indexOf('function trendRows(){');
 const end=html.indexOf('function dataRows(){',begin);
 assert(begin>=0&&end>begin,path+' lacks trendRows');
 const trendCode=html.slice(begin,end);

 const ferran={
  id:'f5060a515233',name:'Ferran',rank:3,revision:2,status:'preparing',
  requested_at:'2026-10-20T21:58:06.749659+00:00',
  request_source:'ttactualidad_direct_rework'
 };
 const op={
  key:'ttendencias:f5060a515233',project:'ttendencias',kind:'tr',
  id:ferran.id,decision:'rework',revision:1,status:'submitted',
  at:Date.now(),snapshot:{title:'Ferran',trend_name:'Ferran',trend_rank:3}
 };
 const run=(queue=[],requests=[],pending=true)=>{
  const state={tab:'elaboracion',data:{
   requests:{requests},editorialQueue:{items:queue},manual:{items:[]},
   explained:{items:[]},recent:{items:[]},deliveries:{items:[]},mobileDecisions:{items:[]}
  }};
  const context=vm.createContext({
   state,Map,Set,String,Array,Number,Date,
   pendingDeletes:new Map(pending?[[op.key,op]]:[]),
   trendClosed:()=>false
  });
  vm.runInContext(trendCode+';var result=trendRows();',context);
  return context.result;
 };
 let rows=run([],[],true);
 assert.equal(rows.length,1,path+': moving a Listas item may not blank En elaboración');
 assert.equal(rows[0].title,'Ferran');
 assert.equal(rows[0]._status,'PENDIENTE DE CONFIRMACIÓN');
 rows=run([ferran],[],true);
 assert.equal(rows.length,1,path+': confirmed queue cannot duplicate placeholder');
 assert.equal(rows[0].revision,2);
 assert.equal(rows[0]._status,'EN ELABORACIÓN');
 rows=run([], [ferran],false);
 assert.equal(rows.length,1,path+': persisted request must survive missing queue JSON');
 assert.equal(rows[0]._id,ferran.id);
 assert.equal(rows[0]._status,'EN ELABORACIÓN');
 rows=run([],[],false);
 assert.equal(rows.length,0,path+': no phantom card without a request');
 assert(html.includes("const queuePath=app==='tr'?'trends/editorial-queue.json':null"),
  path+': small active queue must be loaded before heavy history');
 console.log('REWORK_VISIBLE_OK',path);
}
