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
 {rank:11,name:'Tendencia nueva'}]};
const requests={requests:[
 {name:'Feliz Día de la Hispanidad',id:'hisp-old',status:'deleted',deleted_at:latest},
 {name:'Hispanidad',id:'hisp-new',status:'inactive',auto_queued:true},
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
  explanation:'Noticia verificada.',explained_at:latest}
]};
const deliveries={items:[
 {event_id:'lunes',name:'#FelizLunes',status:'published',final:true,
  revision:2,updated_at:latest},
 {event_id:'hugo',name:'Hugo Duro',status:'deleted',final:true,
  revision:0,updated_at:latest},
 {event_id:'jota-lead',name:'#jotalent5',status:'deleted',final:true,
  revision:0,group_member_ids:['jota-lead','jota-follower'],updated_at:latest},
 {event_id:'yes-send',name:'Tendencia entregada',status:'sent',final:true,
  revision:0,delivered_at:latest}
]};
const state={app:'tr',tab:'top',data:{recent,requests,
 manual:{items:[]},explained:{items:[]},deliveries,mobileDecisions:{items:[]}}};
const rows=vm.runInNewContext(code+'\ntrendRows()', {state, Date, Intl, console});
const status=name=>rows.find(row=>row.name===name)?._status;
assert.equal(status('Hispanidad'),'BORRADA');
assert.equal(status('#FelizLunes'),'PUBLICADA');
assert.equal(status('Hugo Duro'),'BORRADA');
assert.equal(status('#EstrenoJotalent5'),'BORRADA');
assert.equal(status('Feliz 12'),'EN ELABORACIÓN');
assert.equal(status('Tendencia sin entrega'),'EXPLICACIÓN SIN ENTREGAR');
assert.equal(status('Tendencia entregada'),'PENDIENTE EN EXPLICADAS');
assert.equal(status('Tendencia nueva'),'PREPARACIÓN MANUAL');
assert.ok(html.includes("command('Preparar novedad','prepare')"),
 'Ranks 11-30 must retain Prepare button');
console.log('TT_ACTUALIDAD_TOP30_TERMINAL_GROUP_MANUAL_AND_DELIVERY_TEST_OK');
