import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

for(const path of ['docs/ttactualidad/index.html','pilot/ttactualidad-live/index.html']){
 const html=readFileSync(path,'utf8');
 const script=(html.match(/<script>([\s\S]*?)<\/script>/)||[])[1];
 assert(script,path+': missing script');
 new Function(script); // Full syntax check of each shipped HTML.
 const pick=(from,to)=>{
  const a=script.indexOf(from),b=script.indexOf(to,a+from.length);
  assert(a>=0&&b>a,path+': missing '+from);
  return script.slice(a,b);
 };
 const topPart=pick('function currentTop30(recent){','function trendRows(){');
 const currentTop30=new Function(topPart+'return currentTop30;')();
 const radar={captured_at:'2026-10-20T11:40:56+02:00',
  items:Array.from({length:30},(_,i)=>({rank:i+1,name:'TOP'+(i+1)})),
  top30:Array.from({length:30},(_,i)=>'TOP'+(i+1))};
 // Both the production Worker and emergency page must default to Top 30.
 assert(html.includes("state.app=app;state.tab=app==='tr'?'top':'listas';"),
  path+': selecting TTendencias must open Top 30; news keep Listas');
 assert(html.includes("function tabs(){return state.app==='tti'?[]:[['top','Top 30'],['listas','Listas'],['elaboracion','En elaboración']]}"),
  path+': Trends must have no History navigation');
 assert(html.includes("if(state.app==='tr'&&!tabsList.some(t=>t[0]===state.tab))state.tab='top';"),
  path+': invalid or old Trends tab must fall back to Top 30');
 assert(html.includes("document.querySelector('.toolbar').classList.toggle('tti-compact',isNews);"),
  path+': TTitulares must use a compact toolbar');
 assert(html.includes(".toolbar.tti-compact{display:grid;grid-template-columns:minmax(0,1fr) auto auto;"),
  path+': search, refresh and +Noticia must occupy a single row');
 assert(html.includes("isNews?'Buscar noticia…':'Buscar tendencia…'"),
  path+': iPhone search placeholder should be shorter');
 assert(html.includes('id="manual-open"'),
  path+': news creation control must be present');
 if(path.startsWith('docs/')){
  assert(html.includes('href="https://ttactualidad-decisions-pilot.fabricelop.workers.dev/#ttittulares"'),
   path+': emergency +Noticia must open the working original editor rather than a no-op');
 }
 assert.equal(currentTop30(radar).length,30);
 assert.equal(currentTop30({...radar,items:[]}).length,30,'top30 names must be a fallback');
 assert.equal(currentTop30({...radar,items:[]})[29].rank,30);
 // A partial items array (e.g. 16 of 30) must not truncate the ranking.
 const partial=currentTop30({...radar,items:radar.items.slice(0,16)});
 assert.equal(partial.length,30,'16 detailed positions plus 30 names must produce 30 ranks');
 assert.equal(partial[16].rank,17);
 assert.equal(partial[29].name,'TOP30');
 assert(html.includes('.cards.top30{display:flex;flex-direction:column'),
  path+': Top 30 must render as compact vertical rows');
 assert(html.includes('function compactTop30Card(out,x){')&&
        (html.includes('detail.append(summary,content);out.replaceChildren(detail)')||
         (html.includes('detail.append(summary,content);')&&
          html.includes('out.replaceChildren(detail,quickImage)'))),
  path+': rows must expand to show explanation and controls');
 if(path.startsWith('pilot/')){
  assert(html.includes("const topImage=btn('Generar imagen IA'"),
   path+': every Top 30 trend must have an image action');
  assert(html.includes("quickImage.classList.add('top30-image-quick')"),
   path+': image action must remain visible while the ranked row is collapsed');
 }
 assert(html.includes("summary.addEventListener('click'")&&html.includes('expandedTop30'),
  path+': expanded row state must persist across live refreshes');
 assert(html.includes("if(ageBand)out.classList.add(ageBand)")&&
        html.includes('out.dataset.explainedAt=x.explained_at'),
  path+': each row must color by its own explanation timestamp');
 for(const band of ['green','yellow','red']){
  assert(html.includes('.card.trend-top.trend-age-'+band),
   path+': missing age-dependent background '+band);
 }
 assert(html.includes("document.addEventListener('visibilitychange',()=>{if(!document.hidden)updateTop30AgeColors()});"),
  path+': colors must refresh on returning to the app without background polling');
 assert(!html.includes('setInterval(updateTop30AgeColors'),
  path+': no recurring background work for age-color refresh');
 const ageCode=pick('function top30AgeBand(explainedAt,now=Date.now()){',
                    'function updateTop30AgeColors(){');
 const top30AgeBand=new Function(ageCode+'return top30AgeBand;')();
 const now=Date.parse('2026-10-26T18:00:00.000Z');
 const ago=milliseconds=>new Date(now-milliseconds).toISOString();
 assert.equal(top30AgeBand('',now),'','not explained = neutral background');
 assert.equal(top30AgeBand('invalid-date',now),'','invalid date = neutral');
 assert.equal(top30AgeBand(ago(11*3600000),now),'trend-age-green');
 assert.equal(top30AgeBand(ago(12*3600000-1),now),'trend-age-green','less than 12h green');
 assert.equal(top30AgeBand(ago(12*3600000),now),'trend-age-yellow','12h exactly yellow');
 assert.equal(top30AgeBand(ago(24*3600000),now),'trend-age-yellow','24h exactly yellow');
 assert.equal(top30AgeBand(ago(24*3600000+1),now),'trend-age-red','over 24h red');
 assert(html.includes("state.tab==='top'||!isTemporarilyRemoved(x)"),
  path+': pending editorial actions must never reduce Top 30 ranking');
 assert(html.includes("explained_at:readyText&&Number.isFinite(Date.parse(latestAt))?latestAt:''"),
  path+': show a valid explanation date for every explained Top 30 item, not just Listas');
 assert(html.includes("'Exp. '+stamp(x.explained_at)")&&html.includes('class="top30-date"'),
  path+': the collapsed bar must display the explanation day, month and time');
 assert(html.includes('.top30-side{display:flex;flex-direction:column'),
  path+': badge and last explanation date must remain on the right');

 const trending=pick('function trendRows(){','function dataRows(){');
 const state={app:'tr',tab:'top',q:'',data:{
  recent:radar,
  requests:{requests:[{id:'broken',name:'TOP1',status:'preparing',trend_context:{bad:true}}]},
  deliveries:{items:[{event_id:'broken',name:'TOP1',status:'sent',final:true}]},
  editorialQueue:{items:[]},explained:{items:[]},manual:{items:[]},
  mobileDecisions:{items:[]},editorialRuntime:{}
 }};
 const trendRows=new Function('state','trendClosed','currentTop30',
  trending+'return trendRows;')(state,()=>false,currentTop30);
 assert.equal(trendRows().length,30,'Top 30 cannot go blank if metadata is malformed');
 assert.equal(trendRows()[0].rank,1);
 state.data={recent:radar};
 assert.equal(trendRows().length,30,'Top 30 must load with radar alone');

 const loadText=pick('async function load(force=false){','function setApp(app){');
 const control=new Map(),seen=[];
 const els={refresh:{disabled:false},status:{textContent:''}};
 const $=id=>els[id]||{disabled:false,textContent:''};
 const aliases={
  'ttittulares/prepared.json':'prepared','trends/recent.json':'recent',
  'trends/requests.json':'requests','trends/telegram-manual-explained.json':'manual'
 };
 const fields={tti:['ttittulares/prepared.json'],tr:[
  'trends/recent.json','trends/requests.json','trends/telegram-manual-explained.json']};
 let unblockTti;
 const ttiPending=new Promise(resolve=>{unblockTti=resolve});
 const fetchJson=async path=>{
  if(path==='ttittulares/prepared.json')return ttiPending;
  if(path==='trends/recent.json')return radar;
  if(path==='trends/telegram-manual-explained.json')return {items:[]};
  return {requests:[]};
 };
 const ctxState={app:'tti',tab:'listas',data:{},busy:false,updated:0,lastError:''};
 const load=new Function('state','fields','aliases','fetchJson',String.fromCharCode(36),
  'render','pendingDeletes','checkPendingDeletes','sessionStorage','hasBadgeData','syncListasBadge',
  'let loadRevision=0;'+loadText+'return load;')(
   ctxState,fields,aliases,fetchJson,$,
   ()=>{seen.push({app:ctxState.app,hasRadar:currentTop30(ctxState.data.recent).length})},
   new Map(),()=>{}, {setItem(){}},()=>false,()=>{});
 const ttiLoad=load();
 ctxState.app='tr';ctxState.data={};
 const trLoad=load();
 await Promise.resolve();await Promise.resolve();await Promise.resolve();
 assert(seen.some(v=>v.app==='tr'&&v.hasRadar===30),
  'new app should show Top 30 BEFORE optional files finish');
 unblockTti({items:[{event_id:'old-news'}]});
 await Promise.all([ttiLoad,trLoad]);
 assert.equal(currentTop30(ctxState.data.recent).length,30,
  'old tti request must not overwrite newer trends');
 assert.equal(ctxState.data.prepared,undefined,'stale tab results must be ignored');
 assert.equal(ctxState.busy,false);
 console.log('TOP30_MOBILE_OK',path);
}
