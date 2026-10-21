import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const html=readFileSync('pilot/ttactualidad-live/index.html','utf8');
function extract(start,end){
 const i=html.indexOf(start);
 const j=html.indexOf(end,i);
 assert(i>=0&&j>i, 'missing UI function '+start);
 return html.slice(i,j);
}
const code=[
 extract('function ttiListasRows(data){','function trendKey('),
 extract('function isTemporarilyRemoved(item){','async function refreshPilotConnection'),
 extract('function confirmedAction(op,docs){','async function retryAction(')
].join('\n');
const state={app:'tti',tab:'tremending',data:{
 tremending:{items:[
  {id:'tremending-abc123',status:'pending',title:'Pendiente'},
  {id:'tremending-def456',status:'deleted',title:'Borrada'}]},
 decisions:{items:[]},prepared:{items:[]},ttiQueue:{items:[]},
 status:{}
}};
const pendingDeletes=new Map();
const ctx=vm.createContext({state,pendingDeletes,Map,Set,String,Number,console,
 decisions:()=>new Map(),isClosed:()=>false,
 removeKey:(p,id)=>p+':'+id,
 itemProject:()=> 'ttittulares'});
vm.runInContext(code,ctx);
assert.equal(vm.runInContext('ttiRows().length',ctx),1);
pendingDeletes.set('ttittulares:tremending-abc123',{status:'submitted'});
assert.equal(vm.runInContext('ttiRows().filter(x=>!isTemporarilyRemoved(x)).length',ctx),0,
 'Tremending must disappear optimistically');
const op={id:'tremending-abc123',project:'ttittulares',kind:'tremending',decision:'deleted'};
const getDocs=(entries,status)=>[
 {items:[]},{items:[{event_id:op.id,status}]},{items:[]},{items:entries}
];
ctx.op=op;
ctx.docs=getDocs([{id:op.id,status:'pending'}],'deleted');
assert.equal(vm.runInContext('confirmedAction(op,docs)',ctx),false,
 'Must not confirm while item still exists');
ctx.docs=getDocs([],'deleted');
assert.equal(vm.runInContext('confirmedAction(op,docs)',ctx),true,
 'Must confirm only when record removed and decision persisted');
ctx.docs=getDocs([],'published');
assert.equal(vm.runInContext('confirmedAction(op,docs)',ctx),false,
 'Wrong decision cannot confirm');
assert(html.includes("targets.push(['ttittulares/tremending/items.json','tremending'])"));
assert(html.includes("command('Quitar de Listas','deleted')"));
// A confirmed manual "Elaborar" must remove the stale growing card,
// but NEVER hide the authoritative PROCESSING/READY record in its new section.
const growingId='growing-moved-123';
pendingDeletes.set('ttittulares:'+growingId,{status:'confirmed',decision:'prepare'});
state.data.status.three_source_items=[{event_id:growingId,revision:1,title:'Noticia creciendo'}];
state.data.ttiQueue.items=[{event_id:growingId,revision:1,status:'PROCESSING',title:'Noticia en proceso'}];
state.tab='creciendo';
assert.equal(vm.runInContext('ttiRows().filter(x=>!isTemporarilyRemoved(x)).length',ctx),0,
 'Stale Creciendo card must be hidden once prepare is confirmed');
state.tab='elaboracion';
assert.equal(vm.runInContext('ttiRows().filter(x=>!isTemporarilyRemoved(x)).length',ctx),1,
 'Authoritative PROCESSING card must appear in En elaboración');
state.data.prepared.items=[{event_id:growingId,title:'Noticia lista'}];
state.tab='listas';
assert.equal(vm.runInContext('ttiRows().filter(x=>!isTemporarilyRemoved(x)).length',ctx),1,
 'Prepared card must appear in Listas despite prior prepare marker');
pendingDeletes.set('ttittulares:'+growingId,{status:'confirmed',decision:'deleted'});
assert.equal(vm.runInContext('ttiRows().filter(x=>!isTemporarilyRemoved(x)).length',ctx),0,
 'Delete marker must still hide the card');
console.log('TTActualidad Tremending + growing prepare visibility regression tests OK');
