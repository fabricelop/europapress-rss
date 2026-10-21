"use strict";
const assert=require("node:assert/strict");
const fs=require("node:fs");
const vm=require("node:vm");
const files=["windows/TTiTTularesImageBridge.js","windows/TTendenciasImageBridge.js"];
for(const path of files){
 const source=fs.readFileSync(path,"utf8");
 const start=source.indexOf("function buildMessage(job){");
 const end=source.indexOf("\nconst BRIDGE_MODE=",start);
 assert(start>=0&&end>start,"buildMessage unavailable: "+path);
 const code="const commandId='test-no-pepper';const targetId='test-id';\n"+
   source.slice(start,end)+"\nthis.buildMessage=buildMessage;";
 const context=vm.createContext({});
 vm.runInContext(code,context);
 for(const editorial_image_mode of ["humor","rigor"]){
  const job={target_name:"Noticia de prueba",editorial_image_mode,
   context_snapshot:{
    tweet_text:"Hecho contrastado. 🌶️ Este remate solo va en texto.",
    remate:"🌶️ Este remate solo va en texto.",
    factual_summary:"Hecho contrastado.",
    explanation:"TT#1 es tendencia por un hecho. 🌶️ Remate de prueba.",
    closer_text:"🌶️ Remate de prueba.",
    image_style:"Pop art editorial",image_style_name:"pop_art"
   }};
  const prompt=context.buildMessage(job);
  assert(prompt.includes("PROHIBIDO representar guindillas"),path+" missing visual prohibition");
  assert(prompt.includes("el emoji 🌶️ solo es un marcador"),path+" marker semantics missing");
  assert(prompt.includes("nunca un elemento de la imagen"),path+" visual separation missing");
  assert(!/traducir la guindilla/i.test(prompt),path+" obsolete instruction");
  if(editorial_image_mode==="humor"){
   assert(prompt.includes("🌶️ Remate")||prompt.includes("🌶️ Este remate"),path+" editorial text lost");
  }
 }
}
for(const path of [
 ".github/workflows/repair-ttittulares-listas.yml",
 ".github/workflows/repair-ttendencias-explicadas.yml"
]){
 const content=fs.readFileSync(path,"utf8");
 assert(content.includes("NO_PEPPER="),path+" NO_PEPPER missing");
 assert(content.includes('style=style+" "+NO_PEPPER'),path+" sensitive override missing");
 assert(content.includes('"prohibitions":'),path+" instruction prohibitions missing");
}
for(const path of ["ttittulares/editorial-run-prompt.md","trends/editorial-run-prompt.md"]){
 const content=fs.readFileSync(path,"utf8");
 assert(content.includes("NORMA VISUAL PRIORITARIA 16/10/2026"),path+" durable rule missing");
}
console.log("TT NO PEPPER IMAGE POLICY: both bridges x humor/rigor, both repair workflows and editorial contracts OK");
