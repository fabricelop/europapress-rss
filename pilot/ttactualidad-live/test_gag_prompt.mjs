import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

// Test the exact functions called by both copy buttons, without a DOM or network.
function getManualPrompt(path){
  const html=readFileSync(new URL(path,import.meta.url),'utf8');
  const begin=html.indexOf('function itemData(x){');
  const end=html.indexOf('\nasync function copyText(',begin);
  assert.ok(begin>=0&&end>begin,'Funciones editoriales: '+path);
  const ctx=vm.createContext({String,Math,Array,Number,RegExp});
  vm.runInContext(html.slice(begin,end),ctx);
  return ctx.manualPrompt;
}
const files=['./index.html','../../docs/ttactualidad/index.html'];

for(const file of files){
 test('Copiar GAG sin texto ni tarjeta en '+file,()=>{
  const make=getManualPrompt(file);
  const news={_kind:'tti',_id:'demo',revision:1,title:'Una factura',factual_summary:'La empresa pagó una factura verificada.',tweet:{text:'Texto factual confirmado.\n\n#Factura #Empresa\n🌶️ El papel pasó por caja.',remate:'🌶️ El papel pasó por caja.'}};
  const trends={_kind:'tr',_id:'tendencia',revision:0,name:'Factura',title:'Factura',rank:3,explanation:'TT#3 Factura es tendencia por un hecho confirmado.\n#Factura #Empresa\n🌶️ El papel pasó por caja.',closer_text:'🌶️ El papel pasó por caja.'};
  for(const item of [news,trends]){
   const p=make(item);
   for(const required of [
    'SOLO IMAGEN','FORMATO HORIZONTAL 16:9','PROHIBIDO TODO TEXTO',
    'franja','banda inferior','NO diseñes una tarjeta','NO COPIAR',
    'SIN NINGÚN TEXTO','guindillas','Más gag, menos barroquismo'
   ])assert.ok(p.includes(required),'Falta '+required+' en '+item._kind);
   assert.ok(p.includes('El papel pasó por caja.'));
   assert.ok(p.includes('HECHOS EDITORIALES'));
   assert.ok(!p.includes('EXPLICACIÓN EDITORIAL COMPLETA (NO OMITIR NI REESCRIBIR)'));
  }
 });
 test('Copiar GAG mantiene tratamiento respetuoso en '+file,()=>{
  const p=getManualPrompt(file)({_kind:'tti',_id:'sensitive',title:'Accidente con víctimas',tweet:{text:'Accidente con víctimas confirmadas.\n\n#Hechos #Sucesos\n🌶️ Respetar a las familias.',remate:'🌶️ Respetar a las familias.'}});
  assert.match(p,/PERIODÍSTICA SOBRIA Y RESPETUOSA/);
  assert.match(p,/sin humor/);
 });
}
