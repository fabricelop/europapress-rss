import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const html=fs.readFileSync('docs/index.html','utf8');
const match=html.match(/<script>([\s\S]*?)<\/script>/i);
assert(match,'Unified TT script absent');
const code=match[1].replace(
  /const app=location\.hash[\s\S]*?setApp\(app\);/,
  'globalThis.__TT_UI_TEST__={tabs,ttiRows,trendRows,itemData,manualPrompt,state};'
);
const el={addEventListener(){},setAttribute(){},replaceChildren(){},style:{},classList:{add(){},remove(){}},removeAttribute(){},onclick:null,href:'',src:'',innerHTML:'',textContent:''};
const context={document:{getElementById:()=>({...el}),createElement:()=>({...el}),addEventListener(){}},window:{addEventListener(){}},location:{hash:''},
  URL,URLSearchParams,TextEncoder,TextDecoder,Uint8Array,navigator:{clipboard:{}},
  btoa,localStorage:{},sessionStorage:{},history:{replaceState(){}},confirm:()=>true,console};
vm.runInNewContext(code,context,{timeout:1000});
const tt=context.__TT_UI_TEST__, st=tt.state;
assert(tt,'UI test hooks unavailable');

st.app='tti';st.tab='listas';
st.data={prepared:{items:[{event_id:'a'},{event_id:'b'},{event_id:'c'}]},
  decisions:{items:[{event_id:'a',status:'deleted'}]},
  status:{processing_items:[{event_id:'d'}],problematic_items:[{event_id:'a'},{event_id:'e'}],
    three_source_items:[{event_id:'a'},{event_id:'f'}]}};
assert.equal(tt.ttiRows().length,2,'Listas counter differs from visible cards');
st.tab='problematicas';assert.equal(tt.ttiRows().length,1,'Closed problematic card must disappear');
st.tab='creciendo';assert.equal(tt.ttiRows().length,1,'Closed growing card must disappear');

st.app='tr';st.tab='top';
st.data={recent:{items:Array.from({length:30},(_,i)=>({rank:i+1,name:'Tendencia '+(i+1)}))},
  deliveries:{items:[
    {event_id:'live',revision:1,name:'Diomande',status:'sent',final:true,delivered_at:'2026-10-10T20:00:00Z'},
    {event_id:'old',revision:1,name:'Marcelo',status:'deleted',final:true,delivered_at:'2026-10-10T18:00:00Z',deleted_at:'2026-10-10T21:00:00Z'}]},
  manual:{items:[{id:'live',revision:1,explanation:'Explicación completa.\n🌶️ Remate literal.',closer_text:'🌶️ Remate literal.'},
    {id:'old',revision:1,explanation:'Explicación archivada.'}]},
  requests:{requests:[{id:'live',revision:1,name:'Diomande'}]},
  explained:{items:[]},mobileDecisions:{items:[{id:'old',status:'deleted'}]}};
assert.equal(tt.trendRows().length,30,'Top 30 must display all positions');
assert(tt.trendRows().every(x=>x._topOnly),'Top 30 should be search-only');
st.tab='explicadas';
const inbox=tt.trendRows();
assert.equal(inbox.length,1,'Explicadas must include only new active delivered cards');
assert.equal(inbox[0]._id,'live');
const prompt=tt.manualPrompt(inbox[0]);
assert(prompt.includes('Explicación completa.')&&prompt.includes('🌶️ Remate literal.'),'GAG incomplete');
st.tab='historico';
const archive=tt.trendRows();
assert.equal(archive.length,1,'Historical trend not recovered');
assert.equal(archive[0]._id,'old');
assert.equal(tt.tabs().length,3,'Only Top 30, Explicadas and Histórico should exist');
console.log('TT_UNIFIED_MOBILE_UI_OK: counters, Top30, active explanations, history, GAG');
