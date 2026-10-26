import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const page=readFileSync('pilot/ttactualidad-live/index.html','utf8');
const begin=page.indexOf('function ttiListasRows(data){');
const end=page.indexOf('function trendKey(',begin);
assert(begin>=0&&end>begin,'TTiTTulares rows found');
const source=page.slice(begin,end);
const id='growing123';
const prepare={key:'ttittulares:'+id,project:'ttittulares',id,kind:'tti',
 decision:'prepare',status:'submitted',revision:1,at:Date.now(),source_app:'tti',source_tab:'creciendo',source_id:id,snapshot:{title:'Noticias creciendo'}};

function check(queueItems,preparedItems,pending=true) {
 const ctx=vm.createContext({
  state:{tab:'elaboracion',data:{ttiQueue:{items:queueItems},status:{three_source_items:[{
   event_id:id,title:'Noticias creciendo',revision:1,source_count:3}]},
   decisions:{items:[]},prepared:{items:preparedItems}}},
  pendingDeletes:new Map(pending?[[prepare.key,prepare]]:[]),
  decisions:()=>new Map(),isClosed:()=>false,
  Array,Map,Set,String,Number
 });
 vm.runInContext(source+';var result=ttiRows();',ctx);
 return ctx.result;
}

let rows=check([],[]);
assert.equal(rows.length,1,'pending move must be shown in editorial section');
assert.equal(rows[0]._status,'PENDIENTE DE CONFIRMACIÓN');
assert.equal(rows[0].title,'Noticias creciendo');
rows=check([{event_id:id,title:'Noticias creciendo',status:'PROCESSING'}],[]);
assert.equal(rows.length,1,'no pending/processing duplicate');
assert.equal(rows[0]._status,'EN ELABORACIÓN');
rows=check([],[{event_id:id,title:'Noticias creciendo'}]);
assert.equal(rows.length,0,'completed news should move to Listas');
rows=check([],[],false);
assert.equal(rows.length,0,'no phantom pending without explicit request');

const hideStart=page.indexOf('function isTemporarilyRemoved(item){');
const hideEnd=page.indexOf('async function refreshPilotConnection(',hideStart);
assert(hideStart>=0&&hideEnd>hideStart);
const ctx=vm.createContext({
 pendingDeletes:new Map([[prepare.key,prepare]]),
 state:{app:'tti',tab:'creciendo'},
 removeKey:(p,id)=>p+':'+id,
 itemProject:()=> 'ttittulares'
});
vm.runInContext(page.slice(hideStart,hideEnd)+
  ";var hideSource=isTemporarilyRemoved({_id:'growing123',_status:'CRECIENDO'});"+
  "var hideTarget=isTemporarilyRemoved({_id:'growing123',_status:'PENDIENTE DE CONFIRMACIÓN'});",ctx);
assert.equal(ctx.hideSource,true);
assert.equal(ctx.hideTarget,false);

assert(page.includes("if((prepared.items||[]).some(x=>String(x.event_id||'')===id))return 'ready';"));
assert(!page.includes("if(decision==='prepare'||decision==='rework'){state.tab='elaboracion';render();}"),
 'The action may not jump to En elaboración');
assert(!page.includes("state.tab='listas';render();showToast('Noticia elaborada"),
 'The confirmation may not jump to Listas');
const moveContext=vm.createContext({
 pendingDeletes:new Map([['ttendencias:manual-123',{...prepare,key:'ttendencias:manual-123',
  id:'manual-123',project:'ttendencias',decision:'rework',source_app:'tr',
  source_tab:'top',source_id:'old-123',snapshot:{trend_name:'TOP 10',title:'TOP 10'}}]]),
 state:{app:'tr',tab:'top'},removeKey:(p,id)=>p+':'+id,itemProject:()=> 'ttendencias'
});
vm.runInContext(page.slice(hideStart,hideEnd)+
 ";var removedFromTop=isTemporarilyRemoved({_id:'old-123',_topOnly:true,name:'TOP 10'});"+
 "state.tab='elaboracion';var visibleInTarget=!isTemporarilyRemoved({_id:'manual-123',_status:'EN ELABORACIÓN'});",moveContext);
assert.equal(moveContext.removedFromTop,true,'Top30 source disappears instantly');
assert.equal(moveContext.visibleInTarget,true,'The target section remains available');
console.log('TTActualidad V8.5: growing -> pending -> processing -> Listas OK');
