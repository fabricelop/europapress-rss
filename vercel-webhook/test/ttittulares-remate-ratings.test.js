import test from "node:test";
import assert from "node:assert/strict";
import { titularRemateIdentity, titularRemateVariants, annotateTitularRemates, buildTitularRemateRecord } from "../lib/ttittulares-remate-ratings.js";
const base = {
 event_id:"evt-1", revision:2,title:"Suero y el portero",factual_summary:"Gol desde lejos",
 variants:[
  {label:"Principal",text:"Hecho.",remate:""},
  {label:"A",text:"Hecho.\n\n🌶️ Primera frase.",remate:"🌶️ Primera frase."},
  {label:"B",text:"Hecho.\n\n🌶️ Segunda frase.",remate:"🌶️ Segunda frase."},
  {label:"C",text:"Hecho.\n\n🌶️ Tercera frase.",remate:"🌶️ Tercera frase."},
 ],
};
test("se puntúan A B C por separado y nunca Principal",()=>{
 assert.equal(titularRemateVariants(base).length,3);
 assert.equal(titularRemateIdentity(base,base.variants[0]),null);
 assert.notEqual(titularRemateIdentity(base,base.variants[1]),titularRemateIdentity(base,base.variants[2]));
});
test("identidad ligada a noticia, revisión y texto exacto",()=>{
 const a=base.variants[1];
 for(const change of [{event_id:"evt-2"},{revision:3}])assert.notEqual(titularRemateIdentity(base,a),titularRemateIdentity({...base,...change},a));
 assert.notEqual(titularRemateIdentity(base,a),titularRemateIdentity(base,{...a,remate:a.remate+" Cambiado."}));
});
test("valoración válida sólo de 1 a 5",()=>{
 for(const n of [0,6,1.5,"x",null])assert.throws(()=>buildTitularRemateRecord(base,base.variants[1],n));
 const rec=buildTitularRemateRecord(base,base.variants[1],5,"2026-09-28T20:00:00Z");
 const result=annotateTitularRemates({items:[base]}, {items:[rec]}).items[0];
 assert.equal(result.variants[0].rating_key,null);
 assert.equal(result.variants[1].remate_rating,5);
 assert.equal(result.variants[2].remate_rating,null);
 assert.equal(result.variants[3].remate_rating,null);
});
test("compatibilidad con prepared_item primary + alternatives",()=>{
 const alt={...base,variants:[],primary:{text:"Hecho"},alternatives:[
  {label:"A",tweet_text:"Hecho. A",remate:"🌶️ A."},
  {label:"B",tweet_text:"Hecho. B",remate:"🌶️ B."},
 ]};
 const rec=buildTitularRemateRecord(alt,{label:"A",text:"Hecho. A",remate:"🌶️ A."},4);
 const x=annotateTitularRemates({items:[alt]}, {items:[rec]}).items[0];
 assert.equal(x.alternatives[0].remate_rating,4);
 assert.equal(x.alternatives[1].remate_rating,null);
});
