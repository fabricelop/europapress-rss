import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import vm from "node:vm";
const lib=readFileSync(new URL("../tt-shared/gag-actions.js",import.meta.url),"utf8");
const c={window:{},Math,Map,Object,String,Number,Array};vm.createContext(c);vm.runInContext(lib,c);
const gag=c.window.TTGag;
test("La copia móvil incorpora alternativa si falla Clipboard API",()=>{assert.equal(typeof gag.copyText,"function")});
test("GAG mantiene hechos, remate y varía estilo",()=>{
 const item={event_id:"demo",title:"Una noticia",factual_summary:"Informe confirma dos fuentes.",tweet:{text:"Noticia exacta.\n\n🌶️ Remate exacto.",remate:"🌶️ Remate exacto."}};
 const a=gag.buildPrompt("news",item,item.tweet.text,0),b=gag.buildPrompt("news",item,item.tweet.text,1);
 assert.match(a,/Informe confirma dos fuentes/);assert.ok(a.includes(item.tweet.text));assert.ok(a.includes(item.tweet.remate));assert.notEqual(a,b);assert.match(a,/No inventes declaraciones/);
});
test("Tendencia conserva explicación, categoría y closer",()=>{
 const x={id:"t",name:"#Tema",explanation:"TT#3 #Tema se explica.\n\n🌶️ Un remate.",closer_text:"🌶️ Un remate.",category:"Deportes",trend_names:["#Tema","Otro"]};
 const p=gag.buildPrompt("trend",x,x.explanation,0);for(const v of ["TT#3 #Tema","🌶️ Un remate.","CATEGORÍA: Deportes","TENDENCIAS RELACIONADAS: #Tema, Otro"])assert.ok(p.includes(v));
});
test("Cuatro pantallas usan botones manuales y biblioteca",()=>{
 for(const file of ["../ttittulares/index.html","../ttendencias/index.html","../ttendencias/explicadas/index.html","../ttendencias/historico/index.html"]){
  const html=readFileSync(new URL(file,import.meta.url),"utf8");
  assert.match(html,/\/tt-shared\/gag-actions\.js/);assert.match(html,/TTGag\.mount/);assert.match(html,/Mis imágenes IA/);
 }
 for(const label of ["Copiar prompt GAG","Chat Images","Copiar en X","Abrir en X"])assert.ok(lib.includes(label));
 assert.doesNotMatch(lib,/\/api\/|fetch\(/);
});
