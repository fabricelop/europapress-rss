import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const backend=fs.readFileSync(new URL("../lib/ttittulares-control-handler.js",import.meta.url),"utf8");
const ui=fs.readFileSync(new URL("../ttittulares/index.html",import.meta.url),"utf8");
const start=backend.indexOf("async function dismissOpenStory(eventId){");
const end=backend.indexOf("async function markUserValidated(eventId){",start);
assert.ok(start>0&&end>start,"Las funciones del descarte deben existir");
const logic=backend.slice(start,end);

function fixture(){
  const docs={
    decisions:{items:[]},
    prepared:{items:[]},
    processing:{items:[{event_id:"news1",status:"PROBLEMATIC",problem_reason:"Sin confirmar"}]},
    events:{events:[{id:"news1",status:"PROBLEMATIC"}]},
    manual:{items:[]}
  };
  let writes=0;
  const context={
    DECISIONS:"decisions",PREPARED:"prepared",PROCESSING:"processing",EVENTS:"events",MANUAL_ARCHIVE:"manual",
    Date,Promise,console,
    idOf:v=>String(v||"").trim(),
    readJson:async path=>({doc:structuredClone(docs[path])}),
    mutateJson:async(path,message,fn)=>{
      docs[path]=await fn(structuredClone(docs[path]));
      writes++;return docs[path];
    }
  };
  vm.createContext(context);
  vm.runInContext(logic,context);
  return {docs,context,getWrites:()=>writes};
}

test("Descartar de Revisión llega a una acción válida",()=>{
  assert.match(ui,/dismiss-problematic[\s\S]*?api\("dismiss",\{event_id:item\.event_id\}\)/);
  assert.match(backend,/if\(action==="dismiss"\)return res\.status\(200\)\.json\(await dismissOpenStory\(body\.event_id\)\)/);
});

test("Descartar guarda decisión definitiva y cierra la noticia problemática",async()=>{
  const {docs,context}=fixture();
  const result=await context.dismissOpenStory("news1");
  assert.equal(result.ok,true);
  assert.equal(result.sync_pending,false);
  assert.equal(docs.decisions.items[0].status,"dismissed");
  assert.equal(docs.decisions.items[0].decision_source,"web_user");
  assert.equal(docs.processing.items[0].status,"DISMISSED");
  assert.equal(docs.processing.items[0].history_hidden_source,"web_user_dismissal");
  assert.equal(docs.events.events[0].status,"DISMISSED");
});

test("Descartar es idempotente",async()=>{
  const {docs,context,getWrites}=fixture();
  await context.dismissOpenStory("news1");
  const count=getWrites();
  const second=await context.dismissOpenStory("news1");
  assert.equal(second.duplicate,true);
  assert.equal(getWrites(),count);
  assert.equal(docs.decisions.items.length,1);
});

test("No se puede descartar desde Revisión una noticia ya publicada o en Listas",async()=>{
  const {docs,context}=fixture();
  docs.prepared.items.push({event_id:"news1"});
  await assert.rejects(()=>context.dismissOpenStory("news1"),error=>error.statusCode===409);
  docs.prepared.items=[];
  docs.decisions.items.push({event_id:"news1",status:"published"});
  await assert.rejects(()=>context.dismissOpenStory("news1"),error=>error.statusCode===409);
  assert.equal(docs.decisions.items[0].status,"published");
});

test("Una decisión cerrada oculta también las salidas con sincronización parcial",()=>{
  assert.match(backend,/\.filter\(x=>!closedIds\.has\(String\(x\.event_id\|\|""\)\)\&\&processingOutcomeVisible/);
});
