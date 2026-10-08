import test from "node:test";
import assert from "node:assert/strict";
import worker, {stateSnapshot} from "../src/index.js";

const expectedPaths={
  recent:"trends/recent.json",
  requests:"trends/requests.json",
  explained:"trends/telegram-manual-explained.json",
  health:"trends/health-status.json",
  prepared:"trends/prepared.json",
  editorial_config:"trends/editorial-config.json",
  editorial_queue:"trends/editorial-queue.json"
};
function fixtures() {
  return {
    recent:{captured_at:"2026-10-08T11:00:00Z",items:[{rank:1,name:"Ejemplo"}],upcoming:[]},
    requests:{requests:[]},
    explained:{items:[]},
    health:{ok:true},prepared:{items:[]},
    editorial_config:{editorial:{}},
    editorial_queue:{items:[]}
  };
}
function fakeFetch(data,options={}){
  const calls=[];
  const stub=async (url,init)=>{
    calls.push({url:String(url),init});
    const key=Object.keys(expectedPaths).find(k=>String(url).endsWith("/"+expectedPaths[k]));
    assert.ok(key,"Solo se leen rutas GitHub de la lista blanca");
    if(options.fail===key)return new Response("upstream blocked",{status:503});
    return new Response(JSON.stringify(data[key]),{status:200,headers:{"content-type":"application/json"}});
  };
  return {stub,calls};
}

test("reads all seven state docs and refuses an artificial empty-queue fallback",async()=>{
  const {stub,calls}=fakeFetch(fixtures());
  const value=await stateSnapshot(stub);
  assert.equal(value.ok,true);
  assert.equal(value.recent.items[0].name,"Ejemplo");
  assert.equal(value.requests.requests.length,0);
  assert.equal(calls.length,7);
  assert.ok(calls.every(c=>c.url.startsWith("https://raw.githubusercontent.com/fabricelop/europapress-rss/main/")));
  assert.ok(calls.every(c=>c.init.cf.cacheTtl===60));
});

test("fails closed when a required upstream document cannot be fetched",async()=>{
  const {stub}=fakeFetch(fixtures(),{fail:"requests"});
  await assert.rejects(()=>stateSnapshot(stub),/GitHub HTTP 503/);
});

test("fails closed when upstream state format changes",async()=>{
  const data=fixtures();data.requests={items:[]};
  const {stub}=fakeFetch(data);
  await assert.rejects(()=>stateSnapshot(stub),/faltan arrays/);
});

test("health endpoint works without Vercel, PC or GitHub",async()=>{
  const response=await worker.fetch(new Request("https://example.workers.dev/health"),{});
  assert.equal(response.status,200);
  const body=await response.json();
  assert.equal(body.ok,true);
  assert.equal(body.phase,"read-only-test");
});

test("mutations are disabled even if a token is provided",async()=>{
  const r=await worker.fetch(new Request("https://example.workers.dev/api/ttendencias-control",{
    method:"POST",headers:{authorization:"Bearer abc","content-type":"application/json"},body:"{}"
  }),{});
  assert.equal(r.status,501);
  assert.equal((await r.json()).ok,false);
});

test("does not report unimplemented execution endpoints as successful",async()=>{
  const r=await worker.fetch(new Request("https://example.workers.dev/api/ttendencias-run-status"),{});
  assert.equal(r.status,501);
  assert.equal((await r.json()).ok,false);
});

test("static fallback comes from local Worker assets rather than Vercel",async()=>{
  let called=0;
  const assets={fetch:async()=>{called++;return new Response("<html>fallback</html>",{status:200,headers:{"content-type":"text/html"}})}};
  const r=await worker.fetch(new Request("https://example.workers.dev/"),{ASSETS:assets});
  assert.equal(r.status,200);
  assert.equal(called,1);
});
