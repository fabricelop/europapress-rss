import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import vm from "node:vm";
import worker from "../src/index.js";
import {readImageIncident,projectImageIncident} from "../src/image-incidents.js";
import {projectNews} from "../src/news.js";

const tid="trv2-"+"a".repeat(24),nid="ttn2-"+"b".repeat(24),hash="c".repeat(64);
const at="2026-11-16T20:00:00Z";
const problem={project:"ttendencias-v2",trend_id:tid,revision:2,editorial_sha256:hash,
 code:"V2_IMAGE_NEW_CHAT_ID_NOT_VERIFIED",at,detail_safe:"No se pudo verificar la identidad de la nueva conversación.",retry_mode:"manual_only"};
function ledger(incident=problem){return {step:"04_editorial_queue",effects_enabled:false,items:{[tid]:{
 trend_id:tid,revision:2,status:"captured_review",capture:{revision:2,sha256:hash},image_incident:incident}}};}
const fetcher=doc=>async()=>Response.json(doc);

test("image details are exclusively the exact persisted revision/hash, never a missing image inference",async()=>{
 let result=await readImageIncident({project:"ttendencias-v2",id:tid,revision:2,fetcher:fetcher(ledger())});
 assert.equal(result.available,true);assert.equal(result.incident.code,problem.code);assert.equal(result.incident.detail,problem.detail_safe);
 assert.deepEqual(Object.keys(result.incident).sort(),["at","code","detail","retry_mode"]);
 for(const wrong of [null,{...problem,revision:1},{...problem,editorial_sha256:"d".repeat(64)},{...problem,trend_id:"trv2-"+"d".repeat(24)}]){
  result=await readImageIncident({project:"ttendencias-v2",id:tid,revision:2,fetcher:fetcher(ledger(wrong))});
  assert.equal(result.available,false);assert.equal(result.incident,null);
 }
});
test("saved image or an active exact attempt hides a previous failed image incident",async()=>{
 for(const status of ["saved","generating"]){
  const doc=ledger();
  if(status==="saved")doc.items[tid].capture.image={status:"saved",revision:2};
  else doc.items[tid].image_progress={status:"in_progress",revision:2,editorial_sha256:hash,expires_at:new Date(Date.now()+600000).toISOString()};
  const result=await readImageIncident({project:"ttendencias-v2",id:tid,revision:2,fetcher:fetcher(doc)});
  assert.equal(result.available,false);
 }
});
test("only safe fields reach the private UI; raw exception/auth/session material never does",()=>{
 for(const detail_safe of ["https://chatgpt.com/c/private-session", "Error C:\\TTiTTulares\\private-profile", "Authorization: Bearer private", "access_token=secret"]){
  const value=projectImageIncident({...problem,detail_safe,raw_exception:"private",command_id:"private-opaque"},
   {project:"ttendencias-v2",id:tid,revision:2,editorialHash:hash});
  assert.equal(value.detail,undefined);assert.equal(value.raw_exception,undefined);assert.equal(value.command_id,undefined);
 }
 assert.equal(projectImageIncident({...problem,code:"<script>oops</script>"},{project:"ttendencias-v2",id:tid,revision:2,editorialHash:hash}),null);
});
test("Noticias reads a typed image job only on request and binds it to the immutable READY",async()=>{
 const event={project:"ttittulares-v2",schema_version:1,event_id:nid,current_revision:1};
 const path="v2/ttittulares/records/"+nid+"/r1.json";
 const job={project:"ttittulares-v2",schema_version:1,event_id:nid,revision:1,job_id:nid+"-r1-image",source_record_path:path,
  editorial_sha256:hash,status:"problematic",problem:{code:"NEWS_IMAGE_ORIGINAL_MISSING",at,retry_mode:"recover_same_chat",detail_safe:"No se ha podido recuperar el original de la imagen."}};
 const record={project:"ttittulares-v2",event_id:nid,revision:1,record_status:"ready",editorial_sha256:hash};
 const calls=[];
 const get=async url=>{calls.push(String(url));return Response.json(String(url).includes("/news/")?event:String(url).includes("/jobs/")?job:record);};
 let result=await readImageIncident({project:"ttittulares-v2",id:nid,revision:1,fetcher:get});
 assert.equal(result.available,true);assert.equal(result.incident.code,job.problem.code);assert.equal(calls.length,3);
 job.editorial_sha256="d".repeat(64);
 await assert.rejects(readImageIncident({project:"ttittulares-v2",id:nid,revision:1,fetcher:get}),/REVISION_CHANGED/);
});
test("Noticias with no image worker/job has no invented incident",async()=>{
 let calls=0;
 const result=await readImageIncident({project:"ttittulares-v2",id:nid,revision:1,fetcher:async url=>{
  calls++;return String(url).includes("/news/")?Response.json({project:"ttittulares-v2",schema_version:1,event_id:nid,current_revision:1}):new Response("",{status:404});
 }});
 assert.equal(result.available,false);assert.equal(calls,2);
});
test("missing/unreadable ledger is an unavailable request, never an invented generation cause",async()=>{
 await assert.rejects(readImageIncident({project:"ttendencias-v2",id:tid,revision:2,fetcher:async()=>new Response("",{status:503})}),/SOURCE_UNAVAILABLE/);
 await assert.rejects(readImageIncident({project:"ttendencias-v2",id:tid,revision:3,fetcher:fetcher(ledger())}),/REVISION_CHANGED/);
 await assert.rejects(readImageIncident({project:"ttendencias-v2",id:"../bad",revision:2,fetcher:fetcher(ledger())}),/ID_INVALID/);
});
test("news snapshot shows I only for an explicitly recorded exact image incident without per-item fetches",()=>{
 const index={project:"ttittulares-v2",schema_version:1,updated_at:at,items:{[nid]:{event_id:nid,canonical_title:"Noticia recuperada del radar",current_revision:1,status:"monitoring",source_families:[]}}};
 const queue={project:"ttittulares-v2",schema_version:1,queue_type:"editorial",updated_at:at,items:[]};
 assert.equal(projectNews(index,queue).items[0].image_incident_available,false);
 index.items[nid].image_incident={...problem,project:"ttittulares-v2",trend_id:undefined,event_id:nid,revision:1};
 assert.equal(projectNews(index,queue).items[0].image_incident_available,false);
 index.items[nid].editorial_sha256=hash;
 assert.equal(projectNews(index,queue).items[0].image_incident_available,true);
 index.items[nid].image_incident.revision=2;
 assert.equal(projectNews(index,queue).items[0].image_incident_available,false);
});

const origin="https://v2-private.example.workers.dev";
const env={AUTH_PASSWORD:"private-test-password-long-enough",SESSION_SECRET:"private-tests-secret-longer-than-32-chars",SESSION_HOURS:"720",ASSETS:{fetch:async()=>new Response("private")}};
test("incident endpoint requires a private session, rejects POST, and cannot fetch arbitrary paths",async()=>{
 const before=globalThis.fetch;let calls=0;
 try{
  globalThis.fetch=async()=>{calls++;return Response.json(ledger());};
  const url=origin+"/api/image-incidents?project=ttendencias-v2&id="+tid+"&revision=2";
  assert.equal((await worker.fetch(new Request(url),env)).status,401);assert.equal(calls,0);
  const login=await worker.fetch(new Request(origin+"/api/login",{method:"POST",headers:{origin,"x-ttv2-action":"1","content-type":"application/json"},body:JSON.stringify({password:env.AUTH_PASSWORD})}),env);
  const cookie=login.headers.get("set-cookie").split(";")[0];
  const response=await worker.fetch(new Request(url,{headers:{cookie}}),env);
  assert.equal(response.status,200);assert.equal((await response.json()).incident.code,problem.code);
  assert.equal((await worker.fetch(new Request(url,{method:"POST",headers:{cookie}}),env)).status,405);
  assert.equal((await worker.fetch(new Request(url.replace(tid,"..%2Fsecret"),{headers:{cookie}}),env)).status,400);
  assert.equal(calls,1);
 }finally{globalThis.fetch=before;}
});

function dom(){
 class Node{
  constructor(tag){this.tag=tag;this.children=[];this.attributes={};this.events={};this.hidden=false;this.textContent="";}
  append(...children){this.children.push(...children);}
  replaceChildren(...children){this.children=children;this.textContent="";}
  setAttribute(name,value){this.attributes[name]=value;}
  addEventListener(name,handler){this.events[name]=handler;}
 }
 return {Node,document:{createElement:tag=>new Node(tag)}};
}
test("shared I button is lazy, accessible and toggles the real registered problem for both sections",async()=>{
 for(const project of ["ttendencias-v2","ttittulares-v2"]){
  const {Node,document}=dom();const calls=[];
  const context={document,URLSearchParams,AbortSignal,Intl,Date,fetch:async url=>{calls.push(String(url));return Response.json({project,target_id:tid,revision:2,available:true,incident:{code:problem.code,at,detail:problem.detail_safe}});}};
  vm.createContext(context);vm.runInContext(readFileSync(new URL("../web-source/image-incidents.js",import.meta.url),"utf8"),context);
  const card=new Node("details"),head=new Node("summary");
  context.TTImageIncidents.attach({card,head,project,id:tid,revision:2,available:false});
  assert.equal(head.children.length,0);assert.equal(calls.length,0);
  context.TTImageIncidents.attach({card,head,project,id:tid,revision:2,available:true});
  const button=head.children[0],panel=card.children[0];assert.equal(button.textContent,"I");assert.equal(button.attributes["aria-label"],"Incidencia de imagen");
  assert.equal(panel.hidden,true);assert.equal(calls.length,0);
  let prevented=0;const event={preventDefault(){prevented++;},stopPropagation(){prevented++;}};
  await button.events.click(event);
  assert.equal(prevented,2);assert.equal(card.open,true);assert.equal(panel.hidden,false);assert.equal(calls.length,1);
  assert.equal(panel.children[1].textContent,problem.code);assert.equal(panel.children[2].textContent,problem.detail_safe);
  assert.equal(button.attributes["aria-expanded"],"true");
  await button.events.click(event);assert.equal(panel.hidden,true);
  await button.events.click(event);assert.equal(calls.length,1); // toggling is not regeneration
 }
});
test("I never displays a stale identity's cause and a read failure can be retried",async()=>{
 const {Node,document}=dom();let calls=0;
 const context={document,URLSearchParams,AbortSignal,Intl,Date,fetch:async()=>{calls++;return Response.json({project:"ttendencias-v2",target_id:tid,revision:99,available:true,incident:{code:problem.code,at,detail:"CAUSE FROM ANOTHER REVISION"}});}};
 vm.createContext(context);vm.runInContext(readFileSync(new URL("../web-source/image-incidents.js",import.meta.url),"utf8"),context);
 const card=new Node("details"),head=new Node("summary");context.TTImageIncidents.attach({card,head,project:"ttendencias-v2",id:tid,revision:2,available:true});
 const button=head.children[0],panel=card.children[0],event={preventDefault(){},stopPropagation(){}};
 await button.events.click(event);assert.match(panel.textContent,/No se pudo consultar/);assert.doesNotMatch(panel.textContent,/CAUSE/);
 await button.events.click(event);await button.events.click(event);assert.equal(calls,2);
});
test("news incident offers a single manual fresh-chat image retry without affecting trends",async()=>{
 const {Node,document}=dom(),calls=[];let refreshed=0;
 const context={document,URLSearchParams,AbortSignal,Intl,Date,
  crypto:{randomUUID:()=>"12345678-1234-1234-1234-123456789abc"},
  fetch:async(url,options)=>{
   calls.push({url:String(url),options});
   return String(url).includes("/api/news-actions")?Response.json({ok:true}):
    Response.json({project:"ttittulares-v2",target_id:nid,revision:1,available:true,
     incident:{code:"NEWS_IMAGE_CAPTURE_TIMEOUT",at,retry_mode:"manual_only"}});
  }};
 vm.createContext(context);vm.runInContext(readFileSync(new URL("../web-source/image-incidents.js",import.meta.url),"utf8"),context);
 const card=new Node("details"),head=new Node("summary");
 context.TTImageIncidents.attach({card,head,project:"ttittulares-v2",id:nid,revision:1,available:true,
  manualRetry:true,onChange:async()=>{refreshed++;}});
 const event={preventDefault(){},stopPropagation(){}};
 await head.children[0].events.click(event);
 const panel=card.children[0],button=panel.children.find(x=>x.textContent==="↻ Reintentar imagen");
 assert.ok(button);assert.equal(calls.length,1);
 await button.events.click(event);
 assert.equal(calls.length,2);assert.equal(refreshed,1);assert.equal(button.disabled,true);
 assert.equal(JSON.parse(calls[1].options.body).action,"retry_image");
 assert.equal(JSON.parse(calls[1].options.body).event_id,nid);
 assert.equal(calls[1].options.credentials,"same-origin");
 await button.events.click(event);assert.equal(calls.length,2);
 const trend=new Node("details"),trendHead=new Node("summary");
 context.TTImageIncidents.attach({card:trend,head:trendHead,project:"ttendencias-v2",id:tid,revision:2,
  available:true,manualRetry:true});
 context.fetch=async()=>Response.json({project:"ttendencias-v2",target_id:tid,revision:2,available:true,
  incident:{code:problem.code,at,retry_mode:"manual_only"}});
 await trendHead.children[0].events.click(event);
 assert.equal(trend.children[0].children.some(x=>x.textContent==="↻ Reintentar imagen"),false);
});
