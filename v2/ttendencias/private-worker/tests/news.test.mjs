import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import worker from "../src/index.js";
import {projectNews,decorateNews,pageNews,readNews,readNewsRecord,validateNewsRecord,NEWS_SOURCE,NEWS_RADAR_SOURCE} from "../src/news.js";

const id="ttn2-"+"a".repeat(24),time="2026-11-16T18:13:24Z";
function fixture(){return [
 {schema_version:1,project:"ttittulares-v2",updated_at:time,items:{[id]:{event_id:id,current_revision:1,status:"editorial_pending",canonical_title:"Un titular pendiente de investigar",source_families:["EFE","RTVE","EFE","El País","Público"],canonical_urls:["https://example.org/news"],first_seen_at:time,last_seen_at:time}}},
 {schema_version:1,project:"ttittulares-v2",queue_type:"editorial",updated_at:time,items:[{event_id:id,revision:1,job_id:id+"-r1-editorial",status:"pending"}]}
];}

test("pending source title is visible without an invented explanation or publication",()=>{
 const view=projectNews(...fixture());assert.equal(view.counts.pending,1);assert.equal(view.items[0].source_family_count,4);
 assert.equal(view.items[0].explanation,null);assert.equal(view.items[0].publication_allowed,false);
 assert.equal(view.read_only,true);assert.equal(view.refresh_mode,"scheduled_radar_15m");assert.equal(view.expected_interval_minutes,15);
});
test("independent radar time stays fresh when feature editorial commits are blocked",()=>{
 const [index,queue]=fixture();
 const live={schema_version:1,project:"ttittulares-v2",kind:"independent_radar_summary",observed_at:"2026-11-17T12:40:00Z",radar_sha256:"a".repeat(64),metrics:{accepted:12}};
 const view=projectNews(index,queue,Date.parse("2026-11-17T12:45:00Z"),live);
 assert.equal(view.radar_independent,true);
 assert.equal(view.radar_delayed,false);
 assert.equal(view.editorial_delayed,true);
 assert.equal(view.editorial_updated_at,time);
 assert.equal(view.observed_at,live.observed_at);
 assert.equal(view.refresh_mode,"independent_radar_15m");
 assert.match(NEWS_RADAR_SOURCE,/ttactualidad-v2-radar-live/);
});
test("monitoring candidates are distinct from pending editorial jobs",()=>{
 const [index,queue]=fixture();index.items[id].status="monitoring";queue.items=[];
 const view=projectNews(index,queue,Date.parse(time)+60_000);assert.equal(view.counts.detected,1);assert.equal(view.counts.pending,0);
});
test("DET expires exactly 24h after the first observation, even if materialization is late",()=>{
 const [index,queue]=fixture();index.items[id].status="monitoring";queue.items=[];
 const first=Date.parse(time);
 assert.equal(projectNews(index,queue,first+24*3600000-1).counts.detected,1);
 const expired=projectNews(index,queue,first+24*3600000);
 assert.equal(expired.counts.detected,0);
 assert.equal(expired.items.length,0);
 assert.equal(expired.counts.archived,0);
 index.items[id].status="archived";
 assert.equal(projectNews(index,queue,first+24*3600000).items.length,0);
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
test("INC controls are separate from READY publication and preserve confirmed suppression",()=>{
 const actions=readFileSync(new URL("../web-source/news-actions.js",import.meta.url),"utf8");
 const page=readFileSync(new URL("../web-source/news.js",import.meta.url),"utf8");
 assert.match(actions,/function attachIncident\(/);
 assert.match(actions,/wire\(retry,"retry_editorial"\)/);
 assert.match(actions,/wire\(dismiss,"dismiss"/);
 assert.match(actions,/onChange\(type==="retry_editorial"\?"pending":"archived",item\)/);
 assert.match(page,/TTNewsActions\.attachIncident\(/);
 assert.match(page,/state\.filter=group;state\.page=1;state\.open=moved\.event_id/);
 assert.match(page,/item\.status_label==="Suprimida"\)return;loaded=true/);
 const [index,queue]=fixture();queue.items[0].status="problematic";
 const projected=projectNews(index,queue);
 const controls={preferences:[{event_id:id,revision:1,archived:true,dismissed:true}]};
 // The source projection stays immutable; only the private per-user view hides the incident.
 assert.equal(projected.items[0].group,"incident");
 assert.equal(decorateNews(projected,controls).items[0].status_label,"Suprimida");
 // Source already supports dismissed as a terminal state, so ingestion cannot resurrect it.
 index.items[id].terminal_status="dismissed";
 assert.equal(projectNews(index,queue).items[0].group,"archived");
});
test("only verified image for the current revision is signalled on the closed news card",()=>{
 const [index,queue]=fixture();index.items[id].status="ready";queue.items[0].status="ready";
 index.items[id].image={revision:1,verified:true,asset_path:"v2/ttittulares/images/example.png"};
 const saved=projectNews(index,queue);assert.equal(saved.items[0].image_available,true);
 index.items[id].image.revision=2;
 assert.equal(projectNews(index,queue).items[0].image_available,false);
 delete index.items[id].image;
 index.items[id].image_progress={revision:1,expires_at:new Date(Date.now()+60000).toISOString()};
 assert.equal(projectNews(index,queue).items[0].image_in_progress,true);
 const js=readFileSync(new URL("../web-source/news.js",import.meta.url),"utf8");
 assert.match(js,/news-image-head-icon.*🖼️/u);
 assert.match(js,/news-image-head-progress.*🎨/u);
 assert.match(js,/Imagen generada y asociada a esta noticia/);
 const actions=readFileSync(new URL("../web-source/news-actions.js",import.meta.url),"utf8");
 assert.match(actions,/if\(item\.image_available\)\{\s*const image=el\("img","news-original"\)/);
 assert.match(actions,/Imagen visible aquí en V2; oculta en la web V1/);
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
 const view=projectNews(i,q,Date.parse(time)+60_000),params=new URLSearchParams({state:"detected",q:"abc",page:"2"});
 const page=pageNews(view,params);assert.equal(page.total,100);assert.equal(page.items.length,40);assert.equal(page.pages,3);
 assert.equal(pageNews(view,new URLSearchParams({state:"detected",page:"999"})).items.length,20);
 assert.throws(()=>pageNews(view,new URLSearchParams({state:"bad"})),/FILTER_INVALID/);
});
test("news read fetches two editorial projections and one isolated radar, never one per article",async()=>{
 const docs=fixture(),calls=[];
 const data=await readNews({params:new URLSearchParams({state:"pending"}),fetcher:async(url,options)=>{calls.push([url,options]);return url===NEWS_RADAR_SOURCE?new Response("Unavailable",{status:503}):new Response(JSON.stringify(docs[url.endsWith("news-index.json")?0:1]));}});
 assert.equal(data.total,1);assert.equal(calls.length,3);
 assert.equal(calls.filter(([url])=>url.startsWith(NEWS_SOURCE)).length,2);
 assert.ok(calls.every(([,options])=>options.cf.cacheTtl===30));
});
test("a mixed GitHub cache snapshot retries one time uncached instead of showing a transient error",async()=>{
 const [index,queue]=fixture();let requests=0;
 const data=await readNews({params:new URLSearchParams({state:"pending"}),fetcher:async(url,options)=>{
  requests++;
  if(url===NEWS_RADAR_SOURCE)return new Response("Unavailable",{status:503});
  if(url.includes("editorial-queue.json"))return Response.json(requests<=3?{...queue,updated_at:"2026-11-16T18:20:00Z"}:queue);
  return Response.json(index);
 }});
 assert.equal(data.total,1);
 assert.equal(requests,6);
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
 const app=readFileSync(new URL("app.js",root),"utf8");
 assert.match(html,/id="nav-news"/);assert.match(html,/id="nav-trends"/);assert.match(html,/id="results"/);
 assert.match(html,/id="news-panel" hidden/);assert.match(js,/textContent=String/);
 assert.doesNotMatch(js,/innerHTML|P-X|publish_request|raw\.githubusercontent/);
 assert.match(js,/if\(!document.hidden&&!state.loading\)/);
 assert.match(js,/Último barrido/);assert.doesNotMatch(html,/La actualidad que entra|news-eyebrow|id="news-time"/);assert.match(js,/\?selected:"ready"/);assert.match(js,/const short=/);
 assert.match(js,/\$\("publication-summary"\)\.hidden=false/);
 assert.match(app,/newsViewMode\?"\/api\/news-publication-count":"\/api\/publication-count"/);
 assert.match(app,/event\.news_title/);
 assert.match(app,/"ttv2:publication-recorded"/);
 assert.match(js,/if\(item\.has_image===true\)/);
 assert.match(js,/news-image-head-icon/);
 assert.match(app,/newsViewMode\?"PUB":"PU"/);
});
test("Noticias groups clear PUB and Quitar actions, keeps R and RE-X, and marks image headers",()=>{
 const root=new URL("../web-source/",import.meta.url);
 const controls=readFileSync(new URL("news-actions.js",root),"utf8");
 const styles=readFileSync(new URL("styles.css",root),"utf8");
 const news=readFileSync(new URL("news.js",root),"utf8");
 for(const label of ["Publicación","Gestión y reelaboración","Imagen"])
  assert.ok(controls.includes(label));
 assert.match(controls,/add\("PUB",[\s\S]{0,350}?action\(item,"publish"\)/);
 assert.match(controls,/add\("Quitar",[\s\S]{0,330}?action\(item,"archive"\)/);
 assert.doesNotMatch(controls,/add\("PU",/);
 assert.match(controls,/add\("R · Rojo",/);
 assert.match(controls,/add\("RE-X",/);
 assert.match(news,/news-image-head-icon/);
 assert.match(styles,/\.news-action-group\{display:flex;flex-wrap:wrap/);
 assert.match(styles,/@media\(max-width:450px\).*\.news-action-group/);
 assert.match(controls,/function attachPending\(/);
 assert.match(controls,/wire\(urgent,"urgent"\)/);
 assert.match(controls,/wire\(dismiss,"dismiss"\)/);
 assert.match(controls,/item\.group==="archived"&&item\.status_label!=="Suprimida"/);
 assert.match(controls,/attachPublicImageToggle\(item,artwork,onChange\)/);
 assert.match(controls,/await onChange\("archived",item\)/);
 assert.match(news,/state\.filter="archived"/);
 assert.match(news,/const filter=Object\.hasOwn\(names,selected\)\?selected:"ready"/);
});

test("default is Elaboradas even when only pending candidates exist",()=>{
 const view=pageNews(projectNews(...fixture()),new URLSearchParams());
 assert.equal(view.filter,"ready");assert.equal(view.total,0);assert.equal(view.counts.pending,1);
});
test("automatic radar exposes real age and a delayed capture without inventing freshness",()=>{
 const docs=fixture();
 assert.equal(projectNews(...docs,Date.parse(time)+16*60000).radar_delayed,false);
 const stale=projectNews(...docs,Date.parse(time)+40*60000);
 assert.equal(stale.radar_delayed,true);assert.equal(stale.radar_age_minutes,40);
 assert.equal(stale.observed_at,time);
});
function readyRecord(){return {schema_version:1,project:"ttittulares-v2",event_id:id,revision:1,
 record_status:"ready",editorial_job_id:id+"-r1-editorial",editorial_sha256:"a".repeat(64),
 verification:{essential_fact_verified:true},tweet:{text:"Una explicación editorial sintética, contrastada y breve para mostrar la noticia en un tuit. #Prueba #Noticias"},
 explanation:"Un dossier largo que no debe aparecer como tuit."};}
test("READY detail returns only the short tweet and preserves event/revision/hash identity",()=>{
 const r=validateNewsRecord(readyRecord(),id,1);
 assert.equal(r.tweet_text,readyRecord().tweet.text);assert.equal(r.revision,1);assert.equal(r.event_id,id);
 assert.equal(r.editorial_sha256,"a".repeat(64));assert.equal(r.publication_allowed,false);
 assert.equal(r.explanation,undefined);assert.ok(r.x_character_count<=280);
});
test("invalid, stale, unverified or oversized READY copy is rejected rather than truncated",()=>{
 for(const mode of ["event","revision","length","verification","missing_tweet"]){const r=readyRecord();
  if(mode==="event")r.event_id="ttn2-"+"b".repeat(24);
  if(mode==="revision")r.revision=2;
  if(mode==="length")r.tweet.text="Texto ".repeat(60);
  if(mode==="verification")r.verification.essential_fact_verified=false;
  if(mode==="missing_tweet")delete r.tweet;
  assert.throws(()=>validateNewsRecord(r,id,1),/NEWS_RECORD_INVALID/);
 }
});
test("opening a ready detail requires the same current revision and reads its own record",async()=>{
 const [index,queue]=fixture();index.items[id].status="ready";queue.items[0].status="ready";
 const calls=[];
 const fetcher=async url=>{calls.push(url);return new Response(JSON.stringify(url.includes("/records/")?readyRecord():url.endsWith("news-index.json")?index:queue));};
 const r=await readNewsRecord(id,1,{fetcher});assert.equal(r.tweet_text,readyRecord().tweet.text);
 assert.ok(calls[3].endsWith("/records/"+id+"/r1.json"));
 await assert.rejects(readNewsRecord(id,2,{fetcher}),/NOT_READY/);
 index.items[id].status="editorial_pending";queue.items[0].status="pending";
 await assert.rejects(readNewsRecord(id,1,{fetcher}),/NOT_READY/);
});
test("ready detail remains private and rejects malformed identities before an upstream read",async()=>{
 const env={AUTH_PASSWORD:"test-password-more-than-sixteen",SESSION_SECRET:"test-session-secret-more-than-thirty-two-characters"};
 assert.equal((await worker.fetch(new Request("https://private.example/api/news/"+id+"?revision=1"),env)).status,401);
 await assert.rejects(readNewsRecord("wrong",1,{fetcher:async()=>assert.fail("unexpected fetch")}),/ID_INVALID/);
});

