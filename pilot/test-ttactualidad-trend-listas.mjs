import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
import vm from 'node:vm';
const html=readFileSync('docs/index.html','utf8');
const begin=html.indexOf('function trendRows(){');
const end=html.indexOf('function dataRows(){',begin);
assert(begin>=0&&end>begin,'TTendencias renderer missing');
const trendCode=html.slice(begin,end);
const now=Date.now();
const dt=h=>new Date(now-h*3600000).toISOString();
function ready(id,extras={}){
 return {id,name:'Trend '+id,revision:2,status:'explained',
  explanation:'TT#2 Es tendencia por un hecho factual. 🌶️ Remate.',
  explained_at:dt(1),...extras};
}
const cases=[
 {name:'explained without Telegram',manual:[ready('aa123')],expect:['aa123']},
 {name:'deleted manually',manual:[ready('aa123',{telegram_package_status:'deleted'})],expect:[]},
 {name:'deleted in mobile actions',manual:[ready('aa123')],mobile:[{id:'aa123',status:'deleted'}],expect:[]},
 {name:'deleted in requests',manual:[ready('aa123')],requests:[{id:'aa123',status:'deleted'}],expect:[]},
 {name:'closed Telegram delivery prevents resurrection',manual:[ready('aa123')],deliveries:[{event_id:'aa123',status:'deleted',revision:2}],expect:[]},
 {name:'old explanation not resurfaced',manual:[ready('aa123',{explained_at:dt(240)})],expect:[]},
 {name:'unexplained withheld',manual:[ready('aa123',{explanation:''})],expect:[]},
 {name:'latest revision wins',manual:[ready('aa123',{revision:1,status:'deleted'}),ready('aa123',{revision:2})],expect:['aa123']},
 {name:'group followers excluded',manual:[ready('aa123'),ready('bb456',{group_leader_id:'aa123'})],expect:['aa123']},
];
for(const c of cases){
 const state={tab:'listas',data:{
  recent:{items:[]},deliveries:{items:c.deliveries||[]},requests:{requests:c.requests||[]},
  manual:{items:c.manual||[]},explained:{items:[]},mobileDecisions:{items:c.mobile||[]}
 }};
 const context=vm.createContext({state,console,Date,Set,Map,Number,String});
 vm.runInContext(trendCode+';var results=trendRows();',context);
 const got=[...context.results].map(x=>x._id);
 assert.deepEqual(got,c.expect,c.name);
}
console.log('TTendencias Listas sin Telegram: '+cases.length+' casos OK');
