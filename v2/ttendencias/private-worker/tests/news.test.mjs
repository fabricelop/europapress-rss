import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import worker from "../src/index.js";
import {projectNews,pageNews,readNews,NEWS_SOURCE} from "../src/news.js";

const id="ttn2-"+"a".repeat(24),time="2026-11-16T18:13:24Z";
function fixture(){return [
 {schema_version:1,project:"ttittulares-v2",updated_at:time,items:{[id]:{event_id:id,current_revision:1,status:"editorial_pending",canonical_title:"Un titular pendiente de investigar",source_families:["EFE","RTVE","EFE","El País","Público"],canonical_urls:["https://example.org/news"],first_seen_at:time,last_seen_at:time}}},
 {schema_version:1,project:"ttittulares-v2",queue_type:"editorial",updated_at:time,items:[{event_id:id,revision:1,job_id:id+"-r1-editorial",status:"pending"}]}
];}

test("pending source title is visible without an invented explanation or publication",()=>{
 const view=projectNews(...fixture());assert.equal(view.counts.pending,1);assert.equal(view.items[0].source_family_count,4);
 assert.equal(view.items[0].explanation,null);assert.equal(view.items[0].publication_allowed,false);
 assert.equal(view.read_only,true);assert.equal(view.refresh_mode,"manual_radar");
});
test("monitoring candidates are distinct from pending editorial jobs",()=>{
 const [index,queue]=fixture();index.items[id].status="monitoring";queue.items=[];
 const view=projectNews(index,queue);assert.equal(view.counts.detected,1);assert.equal(view.counts.pending,0);
});
test("human terminal decisions override a stale pending queue",()=>{
 for(const status of ["published","dismissed","deleted","archived"]){const [i,q]=fixture();i.items[id].terminal_status=status;assert.equal(projectNews(i,q).items[0].group,"archived");}
});
test("working, recovery, incident and exact ready statuses are distinct",()=>{
 for(const [status,group] of [["claimed","working"],["capture_recovery","working"],["problematic","incident"],["ready","ready"]]){
  const [i,q]=fixture();q.items[0].status=status;if(status==="ready")i.items[id].status="ready";
  assert.equal(projectNews(i,q).items[0].group,group);
 }
 const [i,q]=fixture();i.items[id].status="ready";q.items=[];assert.equal(projectNews(i,q).items[0].group,"incident");
});
test("inconsistent snapshots, wrong revisions and foreign projects fail visibly",()=>{
 for(const mode of ["timestamp","revision","project","duplicate"]){const [i,q]=fixture();
  if(mode==="timestamp")q.updated_at="2026-11-16T18:20:00Z";
  if(mode==="revision")q.items[0].revision=2;
  if(mode==="project")i.project="V1";
  if(mode==="duplicate")q.items.push(q.items[0]);
  assert.throws(()=>projectNews(i,q));
 }
});
test("unsafe article URLs never become active links",()=>{
 for(const value of ["javascript:alert(1)","data:text/html,hello","https://user:password@example.org"]){
  const [i,q]=fixture();i.items[id].canonical_urls=[value];assert.equal(projectNews(i,q).items[0].source_url,null);
 }
});
test("paging is bounded and search is case insensitive",()=>{
 const [i,q]=fixture();for(let n=0;n<100;n++){const key="ttn2-"+n.toString(16).padStart(24,"0");i.items[key]={...i.items[id],event_id:key,status:"monitoring",canonical_title:"Noticia ABC "+n};}
 const view=projectNews(i,q),params=new URLSearchParams({state:"detected",q:"abc",page:"2"});
 const page=pageNews(view,params);assert.equal(page.total,100);assert.equal(page.items.length,40);assert.equal(page.pages,3);
 assert.equal(pageNews(view,new URLSearchParams({state:"detected",page:"999"})).items.length,20);
 assert.throws(()=>pageNews(view,new URLSearchParams({state:"bad"})),/FILTER_INVALID/);
});
test("news read fetches two V2 projections, never one request per article",async()=>{
 const docs=fixture(),calls=[];
 const data=await readNews({fetcher:async(url,options)=>{calls.push([url,options]);return new Response(JSON.stringify(docs[url.endsWith("news-index.json")?0:1]));}});
 assert.equal(data.total,1);assert.equal(calls.length,2);
 assert.ok(calls.every(([url,options])=>url.startsWith(NEWS_SOURCE)&&options.cf.cacheTtl===30));
});
test("upstream failure never becomes an empty successful list",async()=>{
 await assert.rejects(readNews({fetcher:async()=>new Response("Unavailable",{status:503})}),/SOURCE_UNAVAILABLE/);
});
test("anonymous requests cannot read news and authenticated POST is refused",async()=>{
 const origin="https://private.example",env={AUTH_PASSWORD:"test-password-more-than-sixteen",SESSION_SECRET:"test-session-secret-more-than-thirty-two-characters"};
 const response=await worker.fetch(new Request(origin+"/api/news"),env);assert.equal(response.status,401);
 const login=await worker.fetch(new Request(origin+"/api/login",{method:"POST",headers:{origin,"x-ttv2-action":"1","content-type":"application/json"},body:JSON.stringify({password:env.AUTH_PASSWORD})}),env);
 const cookie=login.headers.get("set-cookie").split(";")[0];
 const post=await worker.fetch(new Request(origin+"/api/news",{method:"POST",headers:{cookie}}),env);assert.equal(post.status,405);
});
test("authorized news API returns only the read-only projection",async()=>{
 const old=globalThis.fetch,docs=fixture(),origin="https://private.example",env={AUTH_PASSWORD:"test-password-more-than-sixteen",SESSION_SECRET:"test-session-secret-more-than-thirty-two-characters"};
 try{
  globalThis.fetch=async(url)=>new Response(JSON.stringify(docs[url.endsWith("news-index.json")?0:1]));
  const login=await worker.fetch(new Request(origin+"/api/login",{method:"POST",headers:{origin,"x-ttv2-action":"1","content-type":"application/json"},body:JSON.stringify({password:env.AUTH_PASSWORD})}),env);
  const cookie=login.headers.get("set-cookie").split(";")[0];
  const r=await worker.fetch(new Request(origin+"/api/news",{headers:{cookie}}),env);
  assert.equal(r.status,200);assert.match(r.headers.get("cache-control"),/no-store/);
  const data=await r.json();assert.equal(data.counts.pending,1);assert.equal(data.publication_allowed,false);
 }finally{globalThis.fetch=old;}
});
test("news UI uses text nodes, keeps trends and exposes no publish actions",()=>{
 const root=new URL("../web-source/",import.meta.url);
 const html=readFileSync(new URL("index.html",root),"utf8"),js=readFileSync(new URL("news.js",root),"utf8");
 assert.match(html,/id="nav-news"/);assert.match(html,/id="nav-trends"/);assert.match(html,/id="results"/);
 assert.match(html,/id="news-panel" hidden/);assert.match(js,/textContent=String/);
 assert.doesNotMatch(js,/innerHTML|P-X|publish_request|raw\.githubusercontent/);
 assert.match(js,/if\(!document.hidden&&!state.loading\)/);
 assert.match(js,/Último barrido/);assert.match(js,/pasadas puntuales/);
});
