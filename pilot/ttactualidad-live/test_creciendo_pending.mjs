import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const page=readFileSync('pilot/ttactualidad-live/index.html','utf8');
const begin=page.indexOf('function ttiRows(){');
const end=page.indexOf('function trendKey(',begin);
assert(begin>=0&&end>begin,'TTiTTulares rows found');
const source=page.slice(begin,end);
const id='growing123';
const prepare={key:'ttittulares:'+id,project:'ttittulares',id,kind:'tti',
 decision:'prepare',status:'submitted',revision:1,at:Date.now(),snapshot:{title:'Noticias creciendo'}};

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
 removeKey:(p,id)=>p+':'+id,
 itemProject:()=> 'ttittulares'
});
vm.runInContext(page.slice(hideStart,hideEnd)+
  ";var hideSource=isTemporarilyRemoved({_id:'growing123',_status:'CRECIENDO'});"+
  "var hideTarget=isTemporarilyRemoved({_id:'growing123',_status:'PENDIENTE DE CONFIRMACIÓN'});",ctx);
assert.equal(ctx.hideSource,true);
assert.equal(ctx.hideTarget,false);

assert(page.includes("if((prepared.items||[]).some(x=>String(x.event_id||'')===id))return 'ready';"));
assert(page.includes("if(decision==='prepare'||decision==='rework'){state.tab='elaboracion';render();}"));
console.log('TTActualidad V8.5: growing -> pending -> processing -> Listas OK');
