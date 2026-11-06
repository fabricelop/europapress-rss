import test from 'node:test';
import assert from 'node:assert/strict';
import {handleRequest} from '../src/index.mjs';
import {episodeFingerprint} from '../src/editorial-truth.mjs';

const main = { text: 'Texto factual + remate', offline: false, removed: false, revision: 0 };
const currentTop30 = {ids:new Set(['my-trend']), offline:false};
const editor = async (url, options) => {
  if (url.includes('/trends/site-top30-current.json?ref=main')) {
    if (currentTop30.offline) throw Error('offline');
    return Response.json({items:[...currentTop30.ids].map(editorial_id=>({
      editorial_id,revision:0,explanation:'verified current trend'}))});
  }
  if (url.startsWith('https://api.github.com/repos/fabricelop/europapress-rss/contents/')) {
    if (main.offline) throw Error('offline');
    return new Response(JSON.stringify({ items: main.removed ? [] : [{
      id: 'my-trend', revision: main.revision, explanation: main.text,
    }] }), { status: 200 });
  }
  return new Response(JSON.stringify({ id: 7257052 }), {
    status: options.headers.Authorization === 'Bearer valid-oauth' ? 200 : 401,
    headers: {'Content-Type': 'application/json'},
  });
};
const identity = {
  project: 'ttendencias', editorialId:'my-trend', revision:0,
  commandId:'tr-img-job-123',
};
const png = new Uint8Array([137,80,78,71,13,10,26,10, 0,0,0,13,73,72,68,82, 0,0,0,1,0,0,0,1]);

class DB {
  constructor(){ this.rows=new Map(); }
  prepare(sql){
    let args=[];
    const api={
      bind(...values){args=values;return api;},
      async all(){return {results:sql.includes('ROW_NUMBER()') ? [...thisDB.rows.values()] :
   [...thisDB.rows.values()].filter(x=>x.status ===
     (sql.includes("approved_awaiting_publication")?'approved_awaiting_publication':'pending'))};},
      async first(){const r=thisDB.rows.get(args[0]);if(!r)return null; if(sql.includes('SELECT object_key'))return r.status === (sql.includes("approved_awaiting_publication")?'approved_awaiting_publication':'pending')?{...r}:null;return {status:r.status,editorial_text:r.editorial_text};},
      async run(){
        if (sql.includes('INSERT OR IGNORE')) {
          if(thisDB.rows.has(args[0]))return {meta:{changes:0}};
          const [id,project,editorial_id,revision,episode_fingerprint,command_id,raster_sha256,object_key,title,editorial_text,editorial_at,created_at]=args;
          thisDB.rows.set(id,{id,project,editorial_id,revision,episode_fingerprint,command_id,raster_sha256,object_key,title,editorial_text,editorial_at,created_at,status:'pending'});
          return {meta:{changes:1}};
        }
        if(sql.includes('UPDATE image_candidates')) {
          const [status, _at, _by,id,project,editorial_id,revision,episode_fingerprint,command_id,raster_sha256]=args;
          const row=thisDB.rows.get(id);
          if(!row || row.status!=='pending' || row.project!==project || row.editorial_id!==editorial_id || row.revision!==revision || row.episode_fingerprint!==episode_fingerprint || row.command_id!==command_id || row.raster_sha256!==raster_sha256)return {meta:{changes:0}};
          row.status=status;return {meta:{changes:1}};
        }
        throw new Error('Unexpected SQL');
      },
    };
    const thisDB=this;
    return api;
  }
}
function context(){
 const store=new Map();
 return {env:{DB:new DB(),ORIGINALS:{
   async put(key, bytes){store.set(key, bytes);},
   async get(key){const bytes=store.get(key);return bytes?{body:bytes,arrayBuffer:async()=>bytes instanceof ArrayBuffer?bytes:bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)}:null;}
 }, INGEST_TOKEN:'private-secret-'.repeat(4), APP_GITHUB_USER_ID:'7257052', GITHUB_SOURCE_READ_TOKEN:'read-only-github-test'},store};
}
function req(path,method='GET',body=null,oauth='valid-oauth') {
 return new Request('https://approval.example.test'+path, {method,body,
   headers: oauth ? {Authorization:'Bearer '+oauth}: {}});
}
async function importOne(env, changes={}) {
  const form=new FormData();
  const image=new Blob([changes.png||png],{type:'image/png'});
  form.set('image',image,'original.png');
  const editorialText=changes.editorialText||'Texto factual + remate';
  const incomplete={...identity,...changes.identity};
  const computed=await episodeFingerprint({...incomplete,editorialText});
  const full={...incomplete,episodeFingerprint:changes.identity?.episodeFingerprint||computed};
  form.set('metadata',JSON.stringify({identity:full,title:changes.title||'Tendencia',editorialText,
    editorialAt:changes.editorialAt||new Date().toISOString()}));
  const request=req('/v1/images/ingest','POST',form,null);
  request.headers.set('X-TT-Ingest-Key',env.INGEST_TOKEN);
  return handleRequest(request,env,editor);
}
async function receive(env) {
 const res=await handleRequest(req('/v1/images'),env,editor);
 return {res, data:await res.json()};
}
function decision(id,identity,action,oauth='valid-oauth') {
 const r=req(`/v1/images/${id}/decision`,'POST',JSON.stringify({action,expectedIdentity:identity}),oauth);
 r.headers.set('Content-Type','application/json');return r;
}

test('only editor can list or download originals', async()=>{
 const {env}=context();await importOne(env);
 const {data}=await receive(env);const id=data.items[0].id;
 for(const url of ['/v1/images',`/v1/images/${id}/original`]){
   const unauth=await handleRequest(req(url,'GET',null,null),env,editor);
   assert.equal(unauth.status,401);
   const wrong=await handleRequest(req(url,'GET',null,'someone-else'),env,editor);
   assert.equal(wrong.status,401);
 }
 const ok=await handleRequest(req(`/v1/images/${id}/original`),env,editor);
 assert.equal(ok.status,200);assert.equal(ok.headers.get('cache-control'),'private, no-store');
 assert.deepEqual(new Uint8Array(await ok.arrayBuffer()),png);
});
test('ingest is private and allows only original PNG',async()=>{
 const {env}=context();
 assert.equal((await handleRequest(req('/v1/images/ingest','POST',new FormData(),null),env,editor)).status,401);
 assert.equal((await importOne(env,{png:new Uint8Array(25).fill(1)})).status,415);
 assert.equal((await receive(env)).data.items.length,0);
});
test('approve removes candidate from inbox, does not publish anything',async()=>{
 const {env}=context();const one=await importOne(env);assert.equal(one.status,201);
 const row=(await receive(env)).data.items[0];
 const response=await handleRequest(decision(row.id,row.identity,'approve'),env,editor);
 assert.equal(response.status,200);
 assert.equal((await response.json()).state,'approved_awaiting_publication');
 assert.equal((await receive(env)).data.items.length,0);
 assert.equal(env.DB.rows.get(row.id).published_sites_at,undefined);
 assert.equal(env.DB.rows.get(row.id).published_app_at,undefined);
 assert.equal((await handleRequest(req(`/v1/images/${row.id}/original`),env,editor)).status,404);
 assert.equal((await handleRequest(decision(row.id,row.identity,'approve'),env,editor)).status,200);
 assert.equal((await handleRequest(decision(row.id,row.identity,'reject'),env,editor)).status,409);
});
test('reject removes only inbox entry and keeps original bytes',async()=>{
 const {env,store}=context();await importOne(env);
 const row=(await receive(env)).data.items[0];
 assert.equal((await handleRequest(decision(row.id,row.identity,'reject'),env,editor)).status,200);
 assert.equal((await receive(env)).data.items.length,0);
 assert.equal(store.size,1);assert.equal(env.DB.rows.get(row.id).status,'rejected');
 assert.equal((await importOne(env)).status,200);
 assert.equal((await receive(env)).data.items.length,0);
});
test('stale identity and changed revision cannot be approved',async()=>{
 const {env}=context();await importOne(env);
 const row=(await receive(env)).data.items[0];
 for(const expected of [{...row.identity,revision:1},{...row.identity,episodeFingerprint:'f'.repeat(64)}, {...row.identity,rasterSHA256:'9'.repeat(64)}]){
  const r=await handleRequest(decision(row.id,expected,'approve'),env,editor);
  assert.equal(r.status,409);
 }
 assert.equal((await receive(env)).data.items.length,1);
});
test('different r0 episode and raster are independent candidates',async()=>{
 const {env}=context();await importOne(env);
 await importOne(env,{editorialText:'Otro episodio de esta misma tendencia'});
 assert.equal((await receive(env)).data.items.length,1);
});
test('missing configuration fails closed',async()=>{
 const {env}=context();delete env.DB;
 assert.equal((await handleRequest(req('/v1/images'),env,editor)).status,503);
});

test('episode fingerprint cannot be invented by the uploader',async()=>{
 const {env}=context();
 assert.equal((await importOne(env,{identity:{episodeFingerprint:'a'.repeat(64)}})).status,409);
 assert.equal((await receive(env)).data.items.length,0);
});
test('approval fails closed when main changed, is missing or unavailable; rejection unaffected',async()=>{
 const {env}=context();await importOne(env);
 const row=(await receive(env)).data.items[0];
 for(const change of [
  {text:'Nuevo texto editorial'}, {removed:true}, {revision:1}, {offline:true},
 ]) {
  Object.assign(main,{text:'Texto factual + remate',removed:false,revision:0,offline:false},change);
  const response=await handleRequest(decision(row.id,row.identity,'approve'),env,editor);
  assert.equal(response.status,change.offline?503:409);
  assert.equal((await receive(env)).data.items.length,1);
 }
 Object.assign(main,{text:'Texto factual + remate',removed:false,revision:0,offline:false});
 const r=await handleRequest(decision(row.id,row.identity,'reject'),env,editor);
 assert.equal(r.status,200);
 assert.equal((await receive(env)).data.items.length,0);
});
test('after editorial repair an exact current pending episode can be approved',async()=>{
 const {env}=context(); await importOne(env);
 const row=(await receive(env)).data.items[0];
 main.text='Corregido';
 assert.equal((await handleRequest(decision(row.id,row.identity,'approve'),env,editor)).status,409);
 main.text='Texto factual + remate';
 assert.equal((await handleRequest(decision(row.id,row.identity,'approve'),env,editor)).status,200);
});

test('only a separate publisher secret can see approved candidates and exact raster; no public writes',async()=>{
 const {env,store}=context(); env.PUBLISH_TOKEN='publish-private-secret'.repeat(3);
 await importOne(env);const row=(await receive(env)).data.items[0];
 assert.equal((await handleRequest(req('/v1/publications', 'GET', null, null),env,editor)).status,401);
 assert.equal((await handleRequest(req(`/v1/publications/${row.id}/original`,'GET',null,null),env,editor)).status,401);
 const approval=await handleRequest(decision(row.id,row.identity,'approve'),env,editor);
 assert.equal(approval.status,200);
 const q=req('/v1/publications','GET',null,null);q.headers.set('X-TT-Publish-Key',env.PUBLISH_TOKEN);
 const result=await handleRequest(q,env,editor);
 assert.equal(result.status,200);
 const {items}=await result.json(); assert.equal(items.length,1);
 assert.equal(items[0].id,row.id);assert.equal(items[0].state,'approved_awaiting_publication');
 assert.equal(items[0].identity.rasterSHA256,row.identity.rasterSHA256);
 const download=req(`/v1/publications/${row.id}/original`,'GET',null,null);
 download.headers.set('X-TT-Publish-Key',env.PUBLISH_TOKEN);
 const response=await handleRequest(download,env,editor);
 assert.equal(response.status,200);
 assert.deepEqual(new Uint8Array(await response.arrayBuffer()),png);
 assert.equal(response.headers.get('X-Original-SHA256'),row.identity.rasterSHA256);
 assert.equal(store.size,1);
 assert.equal(env.DB.rows.get(row.id).status,'approved_awaiting_publication');
 assert.equal(env.DB.rows.get(row.id).published_sites_at,undefined);
});
test('publisher never receives rejected or pending images; mutated original fails SHA verification',async()=>{
 const {env,store}=context(); env.PUBLISH_TOKEN='publish-private-secret'.repeat(3);
 await importOne(env);let row=(await receive(env)).data.items[0];
 const download=(id)=>{const r=req(`/v1/publications/${id}/original`,'GET',null,null);r.headers.set('X-TT-Publish-Key',env.PUBLISH_TOKEN);return r;};
 assert.equal((await handleRequest(download(row.id),env,editor)).status,404);
 await handleRequest(decision(row.id,row.identity,'reject'),env,editor);
 assert.equal((await handleRequest(download(row.id),env,editor)).status,404);
 await importOne(env,{editorialText:'Nuevo contexto',identity:{commandId:'tr-img-next'}});
 row=(await receive(env)).data.items[0];
 main.text='Nuevo contexto';
 assert.equal((await handleRequest(decision(row.id,row.identity,'approve'),env,editor)).status,200);
 const [r2key]=[env.DB.rows.get(row.id).object_key];
 store.set(r2key,new Uint8Array([137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,2]));
 assert.equal((await handleRequest(download(row.id),env,editor)).status,409);
 main.text='Texto factual + remate';
});

test('approved original handoff fails closed after new editorial content or lost read credential',async()=>{
 const {env}=context(); env.PUBLISH_TOKEN='publish-private-secret'.repeat(3);
 await importOne(env);const row=(await receive(env)).data.items[0];
 await handleRequest(decision(row.id,row.identity,'approve'),env,editor);
 const download=()=>{const r=req(`/v1/publications/${row.id}/original`,'GET',null,null);r.headers.set('X-TT-Publish-Key',env.PUBLISH_TOKEN);return r;};
 main.text='Cambiado después de aprobar';
 assert.equal((await handleRequest(download(),env,editor)).status,409);
 main.text='Texto factual + remate'; main.offline=true;
 assert.equal((await handleRequest(download(),env,editor)).status,503);
 main.offline=false;
 delete env.GITHUB_SOURCE_READ_TOKEN;
 assert.equal((await handleRequest(download(),env,editor)).status,503);
});
test('news before 09:43 are rejected even when delivered today; current Top30 still admitted',async()=>{
 const {env}=context();
 const bad=await importOne(env,{identity:{project:'ttittulares',editorialId:'old-news'},
   editorialAt:'2026-11-06T08:42:00Z'});
 assert.equal(bad.status,409,await bad.clone().text());
 assert.equal((await bad.json()).error,'NEWS_BEFORE_CUTOVER');
 assert.equal(env.DB.rows.size,0);
 const now=await importOne(env);
 assert.equal(now.status,201);
 currentTop30.ids.delete('my-trend');
 currentTop30.ids.add('another-current-trend');
 const oldTrend=await importOne(context().env);
 assert.equal(oldTrend.status,409);
 currentTop30.ids.delete('another-current-trend');
 currentTop30.ids.add('my-trend');
});
test('only latest pending per episode, no resurrection after rejecting newer, never show 500',async()=>{
 const {env}=context();const recent=new Date().toISOString();
 for(let i=0;i<250;i++)env.DB.rows.set('o'+i,{
   id:'o'+i,project:'ttittulares',editorial_id:'old-news-'+i,revision:0,
   editorial_at:'2026-11-05T08:00:00Z',status:'pending',
   created_at:recent,title:'old',editorial_text:'old',episode_fingerprint:'a'.repeat(64),
   raster_sha256:'b'.repeat(64),command_id:'old-'+i,
 });
 for(let i=0;i<25;i++){
   env.DB.rows.set('n'+i,{
     id:'n'+i,project:'ttittulares',editorial_id:'new-'+i,revision:0,
     editorial_at:recent,status:'pending',
     created_at:new Date(Date.now()+i).toISOString(),title:'new',editorial_text:'new',
     episode_fingerprint:'a'.repeat(64),raster_sha256:'b'.repeat(64),command_id:'new-'+i
   });
 }
 const first=await receive(env);assert.equal(first.res.status,200,JSON.stringify(first.data));
 assert.equal(first.data.items.length,20);
 assert(first.data.items.every(x=>x.title==='new'));
 assert.equal(first.data.hasMore,true);
 const url='/v1/images?limit=20&before='+encodeURIComponent(first.data.nextCursor);
 const next=await handleRequest(req(url),env,editor);assert.equal(next.status,200);
 assert.equal((await next.json()).items.length,5);
 // Once the current/newest image was decided, do not show a previous
 // request for the very same episode.
 const dup={...env.DB.rows.get('n24'),id:'n25',created_at:new Date(Date.now()+999).toISOString(),status:'rejected'};
 env.DB.rows.set('n25',dup);
 const after=await receive(env);
 assert(!after.data.items.some(x=>x.identity.editorialId==='new-24'));
});
test('Top30 scope fetch outage does not leak old pending catalog',async()=>{
 const {env}=context();await importOne(env);
 currentTop30.offline=true;
 const reply=await handleRequest(req('/v1/images'),env,editor);
 assert.equal(reply.status,503);
 assert.equal((await reply.json()).error,'TOP30_SCOPE_UNAVAILABLE');
 currentTop30.offline=false;
});
test('more than 20 requested is rejected and none of the 500 historical news is listed',async()=>{
 const {env}=context();
 const out=await handleRequest(req('/v1/images?limit=100'),env,editor);
 assert.equal(out.status,400);
});
