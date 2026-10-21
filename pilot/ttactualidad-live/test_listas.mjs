import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const page=readFileSync('pilot/ttactualidad-live/index.html','utf8');
const start=page.indexOf('function trendListasRows(data){');
const end=page.indexOf('function dataRows(){',start);
assert(start>=0&&end>start);
const code=page.slice(start,end);
const dt=h=>new Date(Date.now()-h*3600000).toISOString();
const cases=[
 {name:'current editorial without Telegram',age:1,yes:true},
 {name:'old October 11 excluded',age:120,yes:false},
 {name:'49 hours excluded',age:49,yes:false},
 {name:'47 hours retained',age:47,yes:true},
 {name:'deleted mobile',age:1,mobile:true,yes:false}
];
for(const c of cases){
 const state={tab:'listas',data:{recent:{items:[]},deliveries:{items:[]},
 requests:{requests:[]},manual:{items:[{id:'testid123',name:'Tema de prueba',
 status:'explained',revision:1,explained_at:dt(c.age),
 explanation:'Explicación cerrada'}]},
 mobileDecisions:{items:c.mobile?[{id:'testid123',status:'deleted'}]:[]}}};
 const ctx=vm.createContext({state,Date,Set,Map,Number,String,console});
 vm.runInContext(code+';var result=trendRows();',ctx);
 assert.equal(ctx.result.length,c.yes?1:0,c.name);
}
assert(!page.includes('¿Cómo funciona este piloto?'));
assert(!page.includes('Desestimación registrada en pruebas'));
assert(page.includes('Pasar a En Elaboración'));
assert(page.includes("x._status==='CRECIENDO'){command('Pasar a En Elaboración','prepare')"));
console.log('TTActualidad V8: Listas and live buttons OK');
