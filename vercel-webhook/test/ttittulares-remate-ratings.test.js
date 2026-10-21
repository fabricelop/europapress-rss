import test from "node:test";
import assert from "node:assert/strict";
import { titularTweet, titularRemateIdentity, titularRemateVariants, annotateTitularRemates, buildTitularRemateRecord } from "../lib/ttittulares-remate-ratings.js";
const base = {
 event_id:"evt-1", revision:2,title:"Suero y el portero",factual_summary:"Gol desde lejos",
 tweet:{text:"Hecho.\n\n🌶️ Una sola frase.",remate:"🌶️ Una sola frase."},
};
test("se puntúa exactamente el remate del tuit único",()=>{
 assert.equal(titularRemateVariants(base).length,1);
 assert.match(titularRemateIdentity(base),/^titular-remate-v2:[a-f0-9]{24}$/);
});
test("identidad ligada a noticia, revisión y texto exacto",()=>{
 for(const change of [{event_id:"evt-2"},{revision:3}])assert.notEqual(titularRemateIdentity(base),titularRemateIdentity({...base,...change}));
 assert.notEqual(titularRemateIdentity(base),titularRemateIdentity(base,{...base.tweet,remate:base.tweet.remate+" Cambiado."}));
});
test("valoración válida sólo de 1 a 5",()=>{
 for(const n of [0,6,1.5,"x",null])assert.throws(()=>buildTitularRemateRecord(base,base.tweet,n));
 const rec=buildTitularRemateRecord(base,base.tweet,5,"2026-09-28T20:00:00Z");
 const result=annotateTitularRemates({items:[base]}, {items:[rec]}).items[0];
 assert.equal(result.tweet.remate_rating,5);
 assert.equal(result.tweet.rating_key,rec.key);
 assert.equal(rec.label,undefined);
});
test("compatibilidad con datos históricos Principal/A/B/C",()=>{
 const legacy={...base,tweet:null,variants:[
  {label:"Principal",text:"Hecho.",remate:""},
  {label:"A",text:"Hecho.\n\n🌶️ Primera frase.",remate:"🌶️ Primera frase."},
  {label:"B",text:"Hecho.\n\n🌶️ Segunda frase.",remate:"🌶️ Segunda frase."},
  {label:"C",text:"Hecho.\n\n🌶️ Tercera frase.",remate:"🌶️ Tercera frase."},
 ]};
 assert.equal(titularTweet(legacy).remate,"🌶️ Primera frase.");
 assert.match(titularRemateIdentity(legacy),/^titular-remate-v2:/);
});
