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
 assert.equal(currentTop30(radar).length,30);
 assert.equal(currentTop30({...radar,items:[]}).length,30,'top30 names must be a fallback');
 assert.equal(currentTop30({...radar,items:[]})[29].rank,30);

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
 const load=new Function('state','fields','aliases','fetchJson','$','render','pendingDeletes','checkPendingDeletes','sessionStorage',
  'let loadRevision=0;'+loadText+'return load;')(
   ctxState,fields,aliases,fetchJson,$,
   ()=>{seen.push({app:ctxState.app,hasRadar:currentTop30(ctxState.data.recent).length})},
   new Map(),()=>{}, {setItem(){}});
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
