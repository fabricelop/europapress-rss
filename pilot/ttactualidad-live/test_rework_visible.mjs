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
 assert.equal(rows[0]._status,'PENDIENTE DE GITHUB');
 rows=run([ferran],[],true);
 assert.equal(rows.length,1,path+': confirmed queue cannot duplicate placeholder');
 assert.equal(rows[0].revision,2);
 assert.equal(rows[0]._status,'EN ELABORACIÓN');
 rows=run([], [ferran],false);
 assert.equal(rows.length,1,path+': persisted request must survive missing queue JSON');
 assert.equal(rows[0]._id,ferran.id);
 assert.equal(rows[0]._status,'EN ELABORACIÓN');
 const completed={...ferran,status:'explained',revision:2,
  explained_at:'2026-10-21T00:03:00+02:00',
  explanation:'TT#6 Ferran: nuevo contexto. Remate nuevo.'};
 rows=run([ferran],[completed],false);
 assert.equal(rows.length,0,path+': old queue cannot display a completed item twice');
 rows=run([ferran],[],false);
 assert.equal(rows.length,1,path+': queue still visible when requests ledger is late');
 rows=run([],[],false);
 assert.equal(rows.length,0,path+': no phantom card without a request');
 assert(html.includes("const queuePath=app==='tr'?'trends/editorial-queue.json':null"),
  path+': small active queue must be loaded before heavy history');
 const reworkReady={...completed};
 const readyContext=vm.createContext({
  state:{tab:'listas',data:{recent:{items:[]},requests:{requests:[completed]},
   editorialQueue:{items:[ferran]},manual:{items:[reworkReady]},
   explained:{items:[]},deliveries:{items:[]},mobileDecisions:{items:[]}}},
  Date,Array,Map,Set,Number,String,console,pendingDeletes:new Map(),trendClosed:()=>false
 });
 vm.runInContext(trendCode+';var readyRows=trendRows();',readyContext);
 assert.equal(readyContext.readyRows.length,1,path+': completed Ferran must be in Listas');
 assert.equal(readyContext.readyRows[0]._status,'EXPLICADA');
 const pendingContext=vm.createContext({
  state:{tab:'top',data:{recent:{items:[{name:'Ferran',rank:6}]},
   requests:{requests:[completed]},manual:{items:[reworkReady]},
   explained:{items:[]},deliveries:{items:[]},mobileDecisions:{items:[]},
   editorialQueue:{items:[]}}},
  Date,Array,Map,Set,Number,String,console,
  pendingDeletes:new Map([[op.key,op]]),
  removeKey:(p,id)=>p+':'+id,trendClosed:()=>false,
  currentTop30:x=>x.items||[]
 });
 vm.runInContext(trendCode+';var topRows=trendRows();',pendingContext);
 assert.equal(pendingContext.topRows[0]._status,'PENDIENTE DE GITHUB',
  path+': Top30 must show the visible pending GitHub request');
 assert.equal(pendingContext.topRows[0]._reworkable,false);
 const confirmStart=html.indexOf('function confirmedAction(op,docs){');
 const confirmEnd=html.indexOf('async function retryAction(',confirmStart);
 assert(confirmStart>=0&&confirmEnd>confirmStart);
 const confirm=new Function('op','docs',html.slice(confirmStart,confirmEnd)+'return confirmedAction(op,docs);');
 const docs=[{items:[reworkReady]},{items:[]},{items:[]},{requests:[]}];
 const submitted={...op};
 assert.equal(confirm(submitted,docs),false,path+': old ready must not confirm a new request');
 const newWork={...ferran,revision:3,requested_at:new Date().toISOString()};
 assert.equal(confirm(submitted,[docs[0],docs[1],{items:[newWork]},{requests:[newWork]}]),
  'processing',path+': new in-progress same ID must confirm rework');
 const top30Work={...ferran,id:'fresh-ferran',revision:0,
  originated_from_prior_id:ferran.id,requested_at:new Date().toISOString()};
 const top30Op={...op,revision:2};
 assert.equal(confirm(top30Op,[docs[0],docs[1],{items:[top30Work]},{requests:[top30Work]}]),
  'processing',path+': a new Top30 ID must confirm rework');
 console.log('REWORK_VISIBLE_OK',path);
}
