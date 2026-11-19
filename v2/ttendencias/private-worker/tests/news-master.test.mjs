import test from "node:test";
import assert from "node:assert/strict";
import {validateMaster,projectMaster,actOnMaster,newsMasterPublicationCount} from "../src/news-master.js";

const t="2026-11-19T17:00:00Z";
const id="ttn2-"+"a".repeat(24);
const sources=Array.from({length:4},(_,i)=>({family:"family"+i,url:"https://source.example/"+i,source:"Fuente "+i}));
const sample=()=>({project:"ttittulares-v2",schema_version:1,kind:"master_news",observed_at:t,items:[{id,title:"Una noticia contrastada por cuatro medios",url:"https://original.example/a",verified_at:t,sources:sources.map(x=>({...x}))}]});

test("four distinct source families required",()=>{
 assert.equal(validateMaster(sample()).items.length,1);
 const invalid=sample();invalid.items[0].sources[3].family="family0";
 assert.throws(()=>validateMaster(invalid),/QUORUM/);
});

test("suppressed news disappears from the single master projection",()=>{
 const master=validateMaster(sample());
 assert.equal(projectMaster(master,[],new URLSearchParams()).total,1);
 assert.equal(projectMaster(master,[{event_id:id,suppressed_at:t}],new URLSearchParams()).total,0);
});

test("a red mark survives the shared projection and can be removed",()=>{
 const master=validateMaster(sample());
 assert.equal(projectMaster(master,[],new URLSearchParams()).items[0].marked_red,false);
 assert.equal(projectMaster(master,[{event_id:id,marked_red:1}],new URLSearchParams()).items[0].marked_red,true);
 assert.equal(projectMaster(master,[{event_id:id,marked_red:0}],new URLSearchParams()).items[0].marked_red,false);
});

test("search works without editorial text or images",()=>{
 const view=projectMaster(validateMaster(sample()),[],new URLSearchParams({q:"cuatro"}));
 assert.equal(view.total,1);
 assert.equal(view.items[0].image,undefined);
 assert.equal(view.items[0].revision,undefined);
});

test("SUPRIMIR writes a single durable tombstone",async()=>{
 const previousFetch=globalThis.fetch;
 globalThis.fetch=async()=>({ok:true,text:async()=>JSON.stringify(sample())});
 const table=new Map();
 const db={prepare(sql){return {bind(...args){return {
   async first(){
    if(sql.startsWith("SELECT suppressed_at"))return table.get(args[0])||null;
    if(sql.startsWith("INSERT")){const [eventId,at]=args;table.set(eventId,{suppressed_at:at,published_at:null});return {event_id:eventId,action_at:at};}
    return null;
   },async all(){return {results:[]}}};},async run(){return {success:true}}};}};
 const request={method:"POST",headers:new Headers({"content-type":"application/json"}),json:async()=>({id,action:"suppress"})};
 try{
  const result=await actOnMaster(request,{MARKS_DB:db},{json:(body,status=200)=>({body,status}),sameOrigin:()=>true});
  assert.equal(result.status,200);
  assert.ok(table.get(id).suppressed_at);
  const duplicate=await actOnMaster(request,{MARKS_DB:db},{json:(body,status=200)=>({body,status}),sameOrigin:()=>true});
  assert.equal(duplicate.status,409);
 }finally{globalThis.fetch=previousFetch;}
});
