#!/usr/bin/env node
// Execute the actual TT Actualidad Top 30 rendering logic with controlled
// editorial/Telegram fixtures. No network, credentials, or live mutations.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');

const html=fs.readFileSync('docs/index.html','utf8');
const begin=html.indexOf('function trendKey(x)');
const end=html.indexOf('function dataRows()',begin);
assert.ok(begin>=0&&end>begin,'Could not locate Top 30 implementation');
const code=html.slice(begin,end);
const latest='2026-10-12T07:00:00Z';
const recent={items:[
 {rank:1,name:'Hispanidad'},
 {rank:2,name:'#FelizLunes'},
 {rank:3,name:'Hugo Duro'},
 {rank:4,name:'#EstrenoJotalent5'},
 {rank:5,name:'Feliz 12'},
 {rank:6,name:'Tendencia sin entrega'},
 {rank:7,name:'Tendencia entregada'},
 {rank:8,name:'Top diez sin elaborar'},
 {rank:11,name:'Tendencia nueva'},
 {rank:12,name:'Tendencia manual'},
 {rank:13,name:'Tendencia cerrada'}]};
const requests={requests:[
 {name:'Feliz Día de la Hispanidad',id:'hisp-old',status:'deleted',deleted_at:latest},
 {name:'Hispanidad',id:'hisp-new',status:'inactive',auto_queued:true,
  explanation:'Explicación histórica de la Hispanidad.'},
 {name:'#FelizLunes',id:'lunes',status:'published',published_at:latest,revision:2},
 {name:'Hugo Duro',id:'hugo',status:'deleted',deleted_at:latest},
 {name:'#jotalent5',id:'jota-lead',group_id:'group-jota',group_leader_id:'jota-lead',
  status:'deleted',deleted_at:latest},
 {name:'#EstrenoJotalent5',id:'jota-follower',group_id:'group-jota',
  group_leader_id:'jota-lead',status:'explained',revision:0,
  explanation:'Explicación agrupada.',explained_at:latest},
 {name:'Feliz 12',id:'feliz12',status:'preparing',auto_queued:false,
  request_source:'github_pages_authorized_issue',revision:1,requested_at:latest},
 {name:'Tendencia sin entrega',id:'no-send',status:'explained',revision:0,
  explanation:'Ya redactada, no enviada.',explained_at:latest},
 {name:'Tendencia entregada',id:'yes-send',status:'explained',revision:0,
  explanation:'Noticia verificada.',explained_at:latest},
 {name:'Tendencia manual',id:'manual12',rank:12,status:'preparing',auto_queued:false,
  request_source:'github_pages_authorized_issue',requested_at:latest,revision:1},
 {name:'Tendencia cerrada',id:'closed13',rank:13,status:'deleted',
  explanation:'Explicación conservada tras borrar Telegram.',deleted_at:latest,revision:0}
]};
const deliveries={items:[
 {event_id:'lunes',name:'#FelizLunes',status:'published',final:true,
  revision:2,updated_at:latest},
 {event_id:'hugo',name:'Hugo Duro',status:'deleted',final:true,
  revision:0,updated_at:latest},
 {event_id:'jota-lead',name:'#jotalent5',status:'deleted',final:true,
  revision:0,group_member_ids:['jota-lead','jota-follower'],updated_at:latest},
 {event_id:'yes-send',name:'Tendencia entregada',status:'sent',final:true,
  revision:0,delivered_at:latest},
 {event_id:'closed13',name:'Tendencia cerrada',status:'deleted',final:true,
  revision:0,updated_at:latest}
]};
const state={app:'tr',tab:'top',data:{recent,requests,
 manual:{items:[]},explained:{items:[]},deliveries,mobileDecisions:{items:[]}}};
const rows=vm.runInNewContext(code+'\ntrendRows()', {state, Date, Intl, console});
const status=name=>rows.find(row=>row.name===name)?._status;
assert.equal(status('Hispanidad'),'BORRADA');
assert.equal(status('#FelizLunes'),'PUBLICADA');
assert.equal(status('Hugo Duro'),'BORRADA');
assert.equal(status('#EstrenoJotalent5'),'BORRADA');
assert.equal(status('Feliz 12'),'EN COLA'); // No active editorial run was supplied
assert.equal(status('Tendencia sin entrega'),'EXPLICACIÓN SIN ENTREGAR');
assert.equal(status('Tendencia entregada'),'PENDIENTE EN EXPLICADAS');
assert.equal(status('Tendencia nueva'),'PREPARACIÓN MANUAL');
assert.equal(status('Tendencia manual'),'EN COLA');
assert.equal(status('Top diez sin elaborar'),'PENDIENTE');
assert.equal(rows.find(row=>row.name==='Hispanidad').explanation,
 'Explicación histórica de la Hispanidad.');
assert.equal(rows.find(row=>row.name==='Tendencia cerrada').explanation,
 'Explicación conservada tras borrar Telegram.');
const pending=vm.runInNewContext(code+'\ntrendRows()', {
 state:{...state,tab:'pendientes'},Date,Intl,console});
const pendingNames=pending.map(row=>row.name);
assert.ok(pendingNames.includes('Top diez sin elaborar'));
assert.ok(pendingNames.includes('Tendencia manual'));
assert.ok(pendingNames.includes('Tendencia sin entrega'));
assert.ok(!pendingNames.includes('Tendencia nueva'));
assert.ok(!pendingNames.includes('Tendencia cerrada'));
assert.ok(html.includes("command('Preparar novedad','prepare')"),
 'Ranks 11-30 must retain Prepare button');
console.log('TT_ACTUALIDAD_TOP30_TERMINAL_GROUP_MANUAL_AND_DELIVERY_TEST_OK');
