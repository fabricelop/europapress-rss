import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const html=fs.readFileSync('docs/index.html','utf8');
const match=html.match(/<script>([\s\S]*?)<\/script>/i);
assert(match,'Unified TT script absent');
const code=match[1].replace(
  /const app=location\.hash[\s\S]*?setApp\(app\);/,
  'globalThis.__TT_UI_TEST__={tabs,ttiRows,trendRows,itemData,manualPrompt,githubIssueUrl,state};'
);
const el={addEventListener(){},setAttribute(){},replaceChildren(){},style:{},classList:{add(){},remove(){}},removeAttribute(){},onclick:null,href:'',src:'',innerHTML:'',textContent:''};
const context={document:{getElementById:()=>({...el}),createElement:()=>({...el}),addEventListener(){}},window:{addEventListener(){}},location:{hash:''},
  URL,URLSearchParams,TextEncoder,TextDecoder,Uint8Array,navigator:{clipboard:{}},
  btoa,localStorage:{},sessionStorage:{},history:{replaceState(){}},confirm:()=>true,console};
vm.runInNewContext(code,context,{timeout:1000});
const tt=context.__TT_UI_TEST__, st=tt.state;
assert(tt,'UI test hooks unavailable');

// iOS: GitHub Mobile does not reliably support Issue Forms or their prefilled fields.
// The authenticated issue command must instead use the standard Markdown body.
for(const [project,id,action] of [
  ['ttittulares','abc123','deleted'],
  ['ttendencias','trend-123','dismissed']
]){
 const route=new URL(tt.githubIssueUrl(project,id,action,'Titular de prueba'));
 assert.equal(route.origin,'https://github.com');
 assert.equal(route.searchParams.get('template'),null,'Do not open unsupported issue forms in GitHub Mobile');
 const body=route.searchParams.get('body');
 assert(body.includes('### Proyecto\n\n'+project));
 assert(body.includes('### Acción\n\n'+action));
 assert(body.includes('### ID del elemento\n\n'+id));
 assert(route.searchParams.get('title').startsWith('[TT-MOVIL]'));
}
const mobileHtml=fs.readFileSync('docs/ttactualidad/index.html','utf8');
const mobileMatch=mobileHtml.match(/<script>([\s\S]*?)<\/script>/i);
assert(mobileMatch,'Dedicated TTActualidad mobile JavaScript absent');
new vm.Script(mobileMatch[1],{filename:'docs/ttactualidad/index.html'});
const start=mobileMatch[1].indexOf('function emergencyGithubIssueUrl(');
const end=mobileMatch[1].indexOf('async function pilotSend(',start);
assert(start>=0 && end>start,'Missing dedicated Safari command URL');
const linkContext={URL,URLSearchParams};
vm.runInNewContext(mobileMatch[1].slice(start,end)+
 ';globalThis.__mobileUrl=emergencyGithubIssueUrl("ttittulares","abc123","deleted","Título");',linkContext);
const dedicatedUrl=new URL(linkContext.__mobileUrl);
assert.equal(dedicatedUrl.searchParams.get('template'),null);
assert(dedicatedUrl.searchParams.get('body').includes('### Acción\n\ndeleted'));
assert(mobileHtml.includes("if(ON_PAGES)return btn(label,()=>sendEmergencyDirect(x,action)"),'Emergency controls must be in-page buttons');
assert(mobileHtml.includes("fetch('https://api.github.com/repos/fabricelop/europapress-rss/issues'"),'Emergency must submit authenticated commands without navigation');
assert(!mobileHtml.includes("location.href=url;"),'Emergency must not redirect to GitHub');
assert(mobileHtml.includes("'Authorization':'Bearer '+token"),'Emergency must authorize its direct GitHub API call');
assert(mobileHtml.includes("sessionStorage.setItem(EMERGENCY_TOKEN_KEY,token)"),'Token must remain session-scoped, not embedded');
assert(mobileHtml.includes("response.status!==201"),'No optimistic success without a confirmed API response');
assert(mobileHtml.includes("status:'awaiting_github'"),'Mobile must track unconfirmed orders');
assert(mobileHtml.includes("op.status!=='awaiting_github'"),'Never retry unauthenticated mobile issue orders with Worker API');


// Regression: the screenshot showed the same 🌶️ line once inside "explanation"
// and again below the card, because closer_text was repeated visually.
const twice=tt.itemData({
  name:'Vinicius',
  explanation:'TT#1 Vinicius es tendencia por una expulsión.\n🌶️ El VAR le peinó la jugada completa.',
  closer_text:'🌶️ El VAR le peinó la jugada completa.'
});
assert.equal(twice.closer,'🌶️ El VAR le peinó la jugada completa.');
assert.equal(twice.displayExpl,'TT#1 Vinicius es tendencia por una expulsión.');
assert.equal(twice.editorial.split('🌶️').length-1,1,'Copied explanation must have exactly one remate');
const embeddedOnly=tt.itemData({
  explanation:'TT#3 #FelizDomingo es tendencia hoy.\n🌶️ Hasta el algoritmo ficha los domingos.\n🌶️ Hasta el algoritmo ficha los domingos.'
});
assert.equal(embeddedOnly.editorial.split('🌶️').length-1,1,'Duplicate embedded pepper line');
assert(!embeddedOnly.displayExpl.includes('🌶️'),'Display explanation must exclude the punchline');
const neutral=tt.itemData({explanation:'TT#2 ERC al Congreso es tendencia porque se confirmó la candidatura.'});
assert.equal(neutral.editorial,neutral.displayExpl,'Missing remate must not be invented by the UI');
assert.equal(neutral.closer,'','Missing remate is an editorial task, not a display duplication');


st.app='tti';st.tab='listas';
st.data={prepared:{items:[{event_id:'a'},{event_id:'b'},{event_id:'c'}]},
  decisions:{items:[{event_id:'a',status:'deleted'}]},
  status:{processing_items:[{event_id:'d'}],problematic_items:[{event_id:'a'},{event_id:'e'}],
    three_source_items:[{event_id:'a'},{event_id:'f'}]}};
assert.equal(tt.ttiRows().length,2,'Listas counter differs from visible cards');
st.tab='problematicas';assert.equal(tt.ttiRows().length,1,'Closed problematic card must disappear');
st.tab='creciendo';assert.equal(tt.ttiRows().length,1,'Closed growing card must disappear');
st.data.tremending={items:[{id:'tremending-abc',title:'Público · Tremending',tweets:[{author:'@ejemplo',url:'https://x.com/example/status/1'}]}]};
st.tab='tremending';
assert.equal(tt.ttiRows().length,1,'Tremending must be visible inside the unified app');
assert.equal(tt.ttiRows()[0]._kind,'tremending','Tremending must not be treated as a ready editorial item');
assert(html.includes("command('🗑 Borrar','deleted');"),'Tremending must provide a real delete action');
st.data.tremending.items[0].status='deleted';
assert.equal(tt.ttiRows().length,0,'Deleted Tremending must not reappear in the mobile list');

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
assert(tt.trendRows().every(x=>x._topOnly),'Top 30 should retain compact ranking cards');
assert(!html.includes('id="upcoming"'),'Upcoming trends should not appear separately');
st.data.manual.items.push({id:'test-ready',name:'Tendencia 1',revision:0,
  explanation:'Explicación completa de la primera tendencia.',
  closer_text:'🌶️ Remate exacto.',
  explained_at:new Date().toISOString()});
st.data.requests.requests.push({id:'test-progress',name:'Tendencia 2',
  status:'preparing',revision:0,requested_at:new Date().toISOString()});
st.data.manual.items.push({id:'test-group',name:'Evento agrupado',
  trend_names:['Tendencia 3'],status:'explained',revision:0,
  explanation:'Explicación compartida de la tercera tendencia.',
  explained_at:new Date().toISOString()});
const topRows=tt.trendRows();
assert.equal(topRows[0]._status,'EXPLICACIÓN SIN ENTREGAR',
  'An editorial explanation without Telegram proof is not yet EXPLICADA');
assert.equal(topRows[0].explanation,'',
  'Never offer unpublished explanations directly in Top 30');
assert.equal(topRows[1]._status,'EN COLA','Queued work must not be mistaken for active editorial execution');
assert.equal(topRows[2]._status,'EXPLICACIÓN SIN ENTREGAR',
  'A grouped explanation is not publishable until its Telegram delivery');
assert.equal(topRows[2].explanation,'',
  'Grouped explanations may not bypass Explicadas');
assert.equal(topRows[3]._status,'PENDIENTE','Unexplained Top 10 positions remain pending');
assert.equal(topRows[10]._status,'PREPARACIÓN MANUAL','Top 11-30 should not be auto-explained');
assert(html.includes("command('Preparar novedad','prepare');"),
  'Top 11-30 must offer the explicit Prepare novelty command');
// A completed trend is visible only in Explicadas until the actual delivery is
// closed/deleted. The exact historical explanation then reappears in Top 30.
st.data.deliveries.items.push({event_id:'test-ready',revision:0,
    name:'Tendencia 1',status:'sent',final:true,delivered_at:new Date().toISOString()});
const stillInExplained=tt.trendRows()[0];
assert.equal(stillInExplained._status,'PENDIENTE EN EXPLICADAS');
assert.equal(stillInExplained.explanation,'','Top30 must not reveal active Explicadas text');
assert.equal(stillInExplained.closer_text,'','Top30 must not reveal active remate');
assert.equal(stillInExplained._inExplained,true);
st.data.mobileDecisions.items.push({id:'test-ready',status:'deleted'});
const closedInExplained=tt.trendRows()[0];
assert.equal(closedInExplained._status,'BORRADA','Closing Explicadas must show deleted terminal state');
assert.equal(closedInExplained.explanation,'Explicación completa de la primera tendencia.',
  'A closed Explicadas card retains the explanation in Top 30');
assert.equal(closedInExplained._telegramConfirmed,false,
  'A closed trend must never recover publishing actions');
assert.equal(closedInExplained._inExplained,false);
st.data.deliveries.items.push({event_id:'test-group',revision:0,
    name:'Evento agrupado',status:'sent',final:true,delivered_at:new Date().toISOString()});
assert.equal(tt.trendRows()[2]._status,'PENDIENTE EN EXPLICADAS','Grouped trend shares the active explanation');
st.data.mobileDecisions.items.push({id:'test-group',status:'deleted'});
assert.equal(tt.trendRows()[2]._status,'BORRADA','Grouped deleted card must remain closed in Top 30');
assert.equal(tt.trendRows()[2].explanation,'Explicación compartida de la tercera tendencia.',
  'A closed grouped explanation remains visible for consultation');
st.tab='explicadas';
const inbox=tt.trendRows();
assert.equal(inbox.length,1,'Explicadas must include only new active delivered cards');
assert.equal(inbox[0]._id,'live');
const prompt=tt.manualPrompt(inbox[0]);
assert(prompt.includes('Explicación completa.')&&prompt.includes('🌶️ Remate literal.'),'GAG incomplete');
st.tab='historico';
const archive=tt.trendRows();
assert(archive.some(x=>x._id==='old'),'Historical trend not recovered');
assert(archive.some(x=>x._id==='test-ready'),'Closed Explicadas must also appear in Histórico');
assert(archive.some(x=>x._id==='test-group'),'Closed grouped Explicadas must remain auditable');
assert.equal(tt.tabs().length,5,'Top 30, En elaboración, Pendientes, Explicadas and Histórico should exist');
assert(tt.tabs().some(x=>x[0]==='elaboracion'),'The verified editorial queue needs its own mobile tab');
st.data.editorialQueue={items:[{id:'manual11',name:'Tendencia 11',rank:11,status:'preparing',requested_at:new Date().toISOString()}]};
st.tab='elaboracion';
const editing=tt.trendRows();
assert.equal(editing.length,1,'An authenticated Prepare must appear in En elaboración');
assert.equal(editing[0]._status,'EN ELABORACIÓN');
assert.equal(editing[0].name,'Tendencia 11');
assert.equal(editing[0]._id,'manual11');
console.log('TT_UNIFIED_MOBILE_UI_OK: counters, Top30, active explanations, history, GAG');
