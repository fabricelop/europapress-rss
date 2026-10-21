import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const page=readFileSync('pilot/ttactualidad-live/index.html','utf8');
const take=(start,end)=>{
 const a=page.indexOf(start),b=page.indexOf(end,a);
 assert(a>=0&&b>a,'missing selector '+start);
 return page.slice(a,b);
};
const funcs=[
 take('function ttiListasRows(data){','\nfunction ttiRows(){'),
 take('function trendListasRows(data){','\nfunction trendRows(){'),
 take('function badgeCount(){','\nfunction badgeActivationUi(){')
].join('\n');
const now=new Date().toISOString(),twoMinAgo=new Date(Date.now()-120000).toISOString();
const ctx=vm.createContext({
 Date,Map,Set,Number,String,
 isClosed:status=>['deleted','dismissed','published','removed','delete_pending'].includes(status),
 pending:new Set(['ttittulares:pending']),
 isTemporarilyRemoved:x=>ctx.pending.has((x._kind==='tr'?'ttendencias':'ttittulares')+':'+x._id),
 badgeSnapshots:{
  tti:{data:{
   prepared:{items:[{event_id:'news1'},{event_id:'news2'},{event_id:'pending'}]},
   decisions:{items:[{event_id:'news2',status:'deleted'}]}
  }},
  tr:{data:{
   manual:{items:[
    {id:'tr1',name:'Activa',revision:0,status:'explained',explanation:'Texto',explained_at:now},
    {id:'tr2',name:'Eliminada',revision:0,status:'explained',explanation:'Texto',explained_at:now}
   ]},
   requests:{requests:[
    {id:'tr1',revision:0,status:'explained',requested_at:twoMinAgo},
    {id:'tr2',revision:0,status:'deleted',requested_at:twoMinAgo}
   ]},
   deliveries:{items:[]},
   mobileDecisions:{items:[]},
   editorialQueue:{items:[]}
  }}
 }
});
vm.runInContext(funcs+'\nvar counts=badgeCount();',ctx);
assert.deepEqual(JSON.parse(JSON.stringify(ctx.counts)),{news:1,trends:1,total:2},'only visible Listas cards');
ctx.badgeSnapshots.tr.data.editorialQueue.items=[{id:'tr1',revision:1,status:'preparing'}];
vm.runInContext('counts=badgeCount();',ctx);
assert.deepEqual(JSON.parse(JSON.stringify(ctx.counts)),{news:1,trends:0,total:1},'stale trend revision excluded');
ctx.badgeSnapshots.tr=null;
vm.runInContext('counts=badgeCount();',ctx);
assert.equal(ctx.counts,null,'missing project data must not clear badge to zero');
for(const marker of [
 'id="listas-badge-total"','id="listas-badge-detail"','id="badge-enable"',
 'Notification.requestPermission()','navigator.setAppBadge(total)',
 'navigator.clearAppBadge()','paintListasBadge();',
 "['tti','tr'].map(async app=>"
])assert(page.includes(marker),'missing badge wiring '+marker);
assert(!page.includes("setInterval("),'no new polling or background memory usage');
console.log('TTActualidad iOS Listas badge counts, exclusions, permissions and no polling OK');
