import test from 'node:test';
import assert from 'node:assert/strict';
import {handleRequest} from '../src/index.mjs';
import {episodeFingerprint, verifyEditorialNow, readyTextFromMain} from '../src/editorial-truth.mjs';

const main = { text: 'Texto factual + remate', offline: false, removed: false, revision: 0, closed: false, closedAt: '', explainedAt: new Date().toISOString() };
const editor = async (url, options) => {
  if (url.startsWith('https://api.github.com/repos/fabricelop/europapress-rss/contents/')) {
    if (main.offline) throw Error('offline');
    if (url.includes('/ttittulares/prepared.json')) {
      return new Response(JSON.stringify({items:[{
        event_id:'news-demo',revision:0,status:'ready',prepared_at:'2026-11-01T12:00:00Z',
        factual_summary:'Texto factual de noticia sin tweet.text',
        tweet:{text:''},
      }]}),{status:200});
    }
    if (url.includes('/mobile-decisions.json') || url.includes('/ttittulares/decisions.json')) {
      return new Response(JSON.stringify({items: main.closed ? [
        { id: 'my-trend', revision: main.revision, status: 'deleted', updated_at: main.closedAt },
      ] : []}), {status:200});
    }
    return new Response(JSON.stringify({ items: main.removed ? [] : [{
      id: 'my-trend', revision: main.revision, status:'explained',
      explained_at:main.explainedAt, explanation: main.text,
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
      async all(){return {results:[...thisDB.rows.values()].filter(x=>x.status === (sql.includes("approved_awaiting_publication")?'approved_awaiting_publication':'pending'))};},
      async first(){const r=thisDB.rows.get(args[0]);if(!r)return null; if(sql.includes('SELECT object_key'))return r.status === (sql.includes("approved_awaiting_publication")?'approved_awaiting_publication':'pending')?{...r}:null;return {status:r.status,editorial_text:r.editorial_text};},
      async run(){
        if (sql.includes('INSERT OR IGNORE')) {
          if(thisDB.rows.has(args[0]))return {meta:{changes:0}};
          const [id,project,editorial_id,revision,episode_fingerprint,command_id,raster_sha256,object_key,title,editorial_text,created_at]=args;
          thisDB.rows.set(id,{id,project,editorial_id,revision,episode_fingerprint,command_id,raster_sha256,object_key,title,editorial_text,created_at,status:'pending'});
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
  form.set('metadata',JSON.stringify({identity:full,title:changes.title||'Tendencia',editorialText}));
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
 assert.equal((await receive(env)).data.items.length,2);
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
test('a safely imported historical image may be approved when Lists changes or GitHub fails',async()=>{
 for (const change of [
  {text:'Nuevo texto editorial'}, {removed:true}, {revision:1}, {offline:true},
 ]) {
  const {env}=context();
  await importOne(env);
  const row=(await receive(env)).data.items[0];
  Object.assign(main,{text:'Texto factual + remate',removed:false,revision:0,offline:false},change);
  const approval=await handleRequest(decision(row.id,row.identity,'approve'),env,editor);
  assert.equal(approval.status,200,'An approved original stays bound to its saved editorial episode');
  assert.equal((await approval.json()).state,'approved_awaiting_publication');
  assert.equal((await receive(env)).data.items.length,0);
 }
 Object.assign(main,{text:'Texto factual + remate',removed:false,revision:0,offline:false});
});
test('stored candidate identity still rejects modified fingerprints without live GitHub checks',async()=>{
 const {env}=context(); await importOne(env);
 const row=(await receive(env)).data.items[0];
 main.offline=true;
 try {
   const altered={...row.identity,episodeFingerprint:'f'.repeat(64)};
   assert.equal((await handleRequest(decision(row.id,altered,'approve'),env,editor)).status,409);
   assert.equal((await handleRequest(decision(row.id,row.identity,'approve'),env,editor)).status,200);
 } finally {main.offline=false;}
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

test('publisher can retrieve an approved historical image during GitHub outage, but never corrupt bytes',async()=>{
 const {env,store}=context(); env.PUBLISH_TOKEN='publish-private-secret'.repeat(3);
 await importOne(env); const row=(await receive(env)).data.items[0];
 const approval=await handleRequest(decision(row.id,row.identity,'approve'),env,editor);
 assert.equal(approval.status,200);
 const download=()=>{
   const r=req(`/v1/publications/${row.id}/original`,'GET',null,null);
   r.headers.set('X-TT-Publish-Key',env.PUBLISH_TOKEN);return r;
 };
 main.offline=true;
 try {
  delete env.GITHUB_SOURCE_READ_TOKEN;
  const good=await handleRequest(download(),env,editor);
  assert.equal(good.status,200);
  assert.deepEqual(new Uint8Array(await good.arrayBuffer()),png);
  store.set(env.DB.rows.get(row.id).object_key,new Uint8Array(png.length).fill(0));
  assert.equal((await handleRequest(download(),env,editor)).status,409);
 } finally {main.offline=false;}
});

test('manual image upload: editor-only, one candidate, ready for existing approval', async () => {
  const {env} = context();
  const sha = await crypto.subtle.digest('SHA-256', png);
  const rasterSHA256 = Array.from(new Uint8Array(sha), b=>b.toString(16).padStart(2,'0')).join('');
  const form = new FormData();
  form.set('image', new Blob([png], {type:'image/png'}), 'selected.png');
  form.set('metadata', JSON.stringify({
    project:'ttendencias', editorialId:'my-trend', revision:0,
    commandId:'manual-123456', rasterSHA256,
    editorialText:'Texto factual + remate', title:'Test',
  }));
  const upload = req('/v1/images/manual','POST',form);
  const response = await handleRequest(upload,env,editor);
  assert.equal(response.status,201);
  const saved = await response.json();
  assert.equal(saved.state,'pending');
  assert.equal((await receive(env)).data.items.length,1);
  const ready = (await receive(env)).data.items[0];
  assert.equal(ready.id,saved.id);
  const decided = await handleRequest(decision(ready.id,ready.identity,'approve'),env,editor);
  assert.equal(decided.status,200);
  assert.equal((await decided.json()).state,'approved_awaiting_publication');
});

test('manual intake refuses unauthenticated and outdated episodes', async () => {
  const {env,store} = context();
  const hashBytes = await crypto.subtle.digest('SHA-256',png);
  const rasterSHA256 = Array.from(new Uint8Array(hashBytes),b=>b.toString(16).padStart(2,'0')).join('');
  const upload = (who, changed) => {
    const form = new FormData();
    form.set('image',new Blob([png],{type:'image/png'}),'chosen.png');
    form.set('metadata',JSON.stringify({project:'ttendencias',
      editorialId:'my-trend',revision:0,commandId:'manual-123456',
      title:'Test',editorialText:'Texto factual + remate',rasterSHA256,...changed}));
    return req('/v1/images/manual','POST',form,who);
  };
  assert.equal((await handleRequest(upload(null,{}),env,editor)).status,401);
  assert.equal((await handleRequest(upload('someone-else',{}),env,editor)).status,401);
  assert.equal((await handleRequest(upload('valid-oauth',{revision:2}),env,editor)).status,409);
  assert.equal((await handleRequest(upload('valid-oauth',{rasterSHA256:'0'.repeat(64)}),env,editor)).status,409);
  assert.equal(store.size,0);
  assert.equal((await receive(env)).data.items.length,0);
});


test('manual upload uses the same authoritative Listas data as the app', async()=>{
 const {env}=context();
 // A tokenized trend row lives in telegram-manual-explained.json, not in prepared.json.
 // The authorization mock deliberately returns 404 for the obsolete path.
 const strict = async (url,opts) => {
   if (url.includes('/trends/prepared.json')) return new Response('',{status:404});
   return editor(url,opts);
 };
 const digest = await crypto.subtle.digest('SHA-256',png);
 const sha = Array.from(new Uint8Array(digest),x=>x.toString(16).padStart(2,'0')).join('');
 const form=new FormData();
 form.set('image',new Blob([png],{type:'image/png'}),'image.png');
 form.set('metadata',JSON.stringify({project:'ttendencias',editorialId:'my-trend',
  revision:0,commandId:'manual-source-test',title:'Tendencia',
  rasterSHA256:sha,editorialText:'Texto factual + remate'}));
 const response=await handleRequest(req('/v1/images/manual','POST',form),env,strict);
 assert.equal(response.status,201);
});

test('a historical image can be approved after its editorial card left Listas', async()=>{
 const {env}=context();
 await importOne(env);
 const row=(await receive(env)).data.items[0];
 main.closed=true;
 main.closedAt=new Date().toISOString();
 try {
   const r=await handleRequest(decision(row.id,row.identity,'approve'),env,editor);
   assert.equal(r.status,200);
   assert.equal((await r.json()).state,'approved_awaiting_publication');
   assert.equal((await receive(env)).data.items.length,0);
 } finally {main.closed=false;main.closedAt='';}
});

test('a terminal decision for a previous episode must not block a newer Listas episode', async()=>{
 main.closed = true;
 main.closedAt = '2026-11-01T08:00:00Z';
 main.explainedAt = new Date().toISOString();
 try {
   assert.equal(await verifyEditorialNow({
     project:'ttendencias',editorialId:'my-trend',revision:0,
   }, 'Texto factual + remate', editor, 'valid-oauth'), 'current');
 } finally {
   main.closed=false;
   main.closedAt='';
 }
});

test('iPhone can upload a news image using the actual fallback text of a READY card', async()=>{
 const {env}=context();
 const sha = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',png)),
  b=>b.toString(16).padStart(2,'0')).join('');
 const form = new FormData();
 form.set('image',new Blob([png],{type:'image/png'}),'news.png');
 form.set('metadata',JSON.stringify({
   project:'ttittulares',editorialId:'news-demo',revision:0,
   commandId:'manual-news-1',rasterSHA256:sha,title:'Noticia de prueba',
   editorialText:'Texto factual de noticia sin tweet.text',
 }));
 const upload=await handleRequest(req('/v1/images/manual','POST',form),env,editor);
 assert.equal(upload.status,201);
 const body=await upload.json();
 assert.equal(body.state,'pending');
 const pending=(await receive(env)).data.items;
 assert.equal(pending.length,1);
 const approved=await handleRequest(decision(body.id,pending[0].identity,'approve'),env,editor);
 assert.equal(approved.status,200);
 assert.equal((await approved.json()).state,'approved_awaiting_publication');
 assert.equal(env.DB.rows.get(body.id).published_sites_at,undefined);
});


test('out-of-Listas history remains an exact eligible image target', async()=>{
 const identity={project:'ttendencias',editorialId:'my-trend',revision:0};
 const date=new Date().toISOString();
 const make=(extra={})=>({items:[{id:'my-trend',revision:0,status:'explained',
  explained_at:date,explanation:'Texto factual + remate',...extra}]});
 assert.equal(readyTextFromMain(make(),identity),'Texto factual + remate');
 assert.equal(readyTextFromMain(make({explained_at:new Date(Date.now()-49*3600_000).toISOString()}),identity),'Texto factual + remate');
 assert.equal(readyTextFromMain(make({status:'published',group_leader_id:'another-trend'}),identity),'Texto factual + remate');
 assert.equal(readyTextFromMain(make({status:'deleted',telegram_package_status:'deleted'}),identity),'Texto factual + remate');
 assert.equal(readyTextFromMain(make({explained_at:''}),identity),null);
 assert.equal(readyTextFromMain({items:[{...make().items[0],id:'different'}]},identity),null);
 assert.equal(readyTextFromMain({items:[{...make().items[0],revision:1}]},identity),null);
 assert.equal(readyTextFromMain({items:[make().items[0],
   {...make().items[0],revision:1,explanation:'New revision'}]},identity),'Texto factual + remate');
});

