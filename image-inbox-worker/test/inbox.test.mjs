import test from 'node:test';
import assert from 'node:assert/strict';
import {handleRequest} from '../src/index.mjs';

const editor = async (_url, options) => new Response(JSON.stringify({ id: 7257052 }), {
  status: options.headers.Authorization === 'Bearer valid-oauth' ? 200 : 401,
  headers: {'Content-Type': 'application/json'},
});
const identity = {
  project: 'ttendencias', editorialId:'my-trend', revision:0,
  episodeFingerprint:'a'.repeat(64), commandId:'tr-img-job-123',
};
const png = new Uint8Array([137,80,78,71,13,10,26,10, 0,0,0,13,73,72,68,82, 0,0,0,1,0,0,0,1]);

class DB {
  constructor(){ this.rows=new Map(); }
  prepare(sql){
    let args=[];
    const api={
      bind(...values){args=values;return api;},
      async all(){return {results:[...thisDB.rows.values()].filter(x=>x.status==='pending').map(x=>x)};},
      async first(){const r=thisDB.rows.get(args[0]);if(!r)return null; if(sql.includes('SELECT object_key'))return r.status==='pending'?{object_key:r.object_key}:null;return {status:r.status};},
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
   async get(key){const bytes=store.get(key);return bytes?{body:bytes}:null;}
 }, INGEST_TOKEN:'private-secret-'.repeat(4), APP_GITHUB_USER_ID:'7257052'},store};
}
function req(path,method='GET',body=null,oauth='valid-oauth') {
 return new Request('https://approval.example.test'+path, {method,body,
   headers: oauth ? {Authorization:'Bearer '+oauth}: {}});
}
async function importOne(env, changes={}) {
  const form=new FormData();
  const image=new Blob([changes.png||png],{type:'image/png'});
  form.set('image',image,'original.png');
  form.set('metadata',JSON.stringify({identity:{...identity,...changes.identity},title:changes.title||'Tendencia',editorialText:'Texto factual + remate'}));
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
 await importOne(env,{identity:{episodeFingerprint:'f'.repeat(64)}});
 assert.equal((await receive(env)).data.items.length,2);
});
test('missing configuration fails closed',async()=>{
 const {env}=context();delete env.DB;
 assert.equal((await handleRequest(req('/v1/images'),env,editor)).status,503);
});