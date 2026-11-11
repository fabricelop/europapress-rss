import test from 'node:test';
import assert from 'node:assert/strict';
import {createTTFotosApi} from '../src/lib/api.mjs';
import {commandDetails,exactJob,sourceEvidence,rasterSha} from '../src/lib/core.mjs';
const cmd='tt-img-auto-753d587ec61b-r1-a1-1794420306285';
const other='tr-img-auto-e617da285349-r0-a1-1794421194128';
const job={command_id:cmd,target_id:'753d587ec61b',project:'ttittulares',revision:1,requested_at:'2026-11-11T12:00:00Z',target_name:'Noticia de prueba',conversation_url:'https://chatgpt.com/c/6af2c9b5-e0c4-83eb-9526-dc7abf479048'};
const trend={command_id:other,target_id:'e617da285349',project:'ttendencias',revision:0,requested_at:'2026-11-11T13:00:00Z',target_name:'Tendencia de prueba'};
function png(seed=0){return new Uint8Array([...Buffer.from('89504e470d0a1a0a','hex'),...Array(48).fill(seed)])}
function mockStore(){
 const s={assets:new Map(),jobs:new Map(),matches:new Map(),history:[],objects:new Map()};
 const key=p=>[p.project,p.editorial_id,p.revision,p.command_id].join(':');
 const db={prepare(sql){const params=[];
  return {bind(...a){params.push(...a);return this},async first(){
   if(sql.includes('FROM tt_fotos_assets WHERE sha='))return s.assets.get(params[0])||null;
   if(sql.includes('FROM tt_fotos_matches WHERE project='))return s.matches.get(params.join(':'))||null;
   if(sql.includes('COUNT(*) n FROM tt_fotos_assets a'))return {n:[...s.assets.values()].filter(a=>![...s.matches.values()].some(m=>m.asset_sha===a.sha)).length};
   if(sql.includes('COUNT(*) n FROM tt_fotos_assets'))return {n:s.assets.size};
   if(sql.includes('COUNT(*) n FROM tt_fotos_matches'))return {n:s.matches.size};
   if(sql.includes('COUNT(*) n FROM tt_fotos_jobs'))return {n:s.jobs.size};
   throw Error('Unexpected query first: '+sql);
  },async run(){
   if(sql.includes('INSERT INTO tt_fotos_jobs')){const [command_id,project,editorial_id,revision,title,requested_at,conversation_url,registered_at]=params;s.jobs.set(command_id,{command_id,project,editorial_id,revision,title,requested_at,conversation_url,registered_at});return}
   if(sql.includes('INSERT INTO tt_fotos_assets')){const [sha,size_bytes,created_at,source_kind,conversation_url,evidence_command,evidence_reason,title]=params;s.assets.set(sha,{sha,size_bytes,created_at,source_kind,conversation_url,evidence_command,evidence_reason,title});return}
   if(sql.includes('INSERT INTO tt_fotos_matches')){const [project,editorial_id,revision,command_id,asset_sha,confidence,updated_at]=params;const entry={project,editorial_id,revision,command_id,asset_sha,confidence,updated_at};s.matches.set(key(entry),entry);return}
   if(sql.includes('INSERT INTO tt_fotos_match_history')){const [project,editorial_id,revision,command_id,asset_sha,confidence,changed_at,action]=params;s.history.push({project,editorial_id,revision,command_id,asset_sha,confidence,changed_at,action});return}
   throw Error('Unexpected query run '+sql);
  },async all(){
   if(sql.includes('FROM tt_fotos_assets a')){const onlyUnmatched=sql.includes('WHERE NOT EXISTS');return {results:[...s.assets.values()].filter(a=>!onlyUnmatched||![...s.matches.values()].some(m=>m.asset_sha===a.sha)).map(a=>({...a,matches:[...s.matches.values()].filter(m=>m.asset_sha===a.sha).length}))}}
   if(sql.includes('FROM tt_fotos_jobs j'))return {results:[...s.jobs.values()].map(j=>({...j,...([...s.matches.values()].find(m=>m.command_id===j.command_id)||{})}))};
   throw Error('Unexpected query all '+sql);
  }};
 },async batch(q){for(const item of q)await item.run()}};
 const r2={async put(key,bytes){s.objects.set(key,new Uint8Array(bytes))},async get(key){return s.objects.has(key)?{body:s.objects.get(key)}:null}};
 return {...s,db,r2};
}
function setup({editor=true,jobVerification}={}){const store=mockStore(),jobProvider={async find(commandId){return commandId===cmd?{...job,...(jobVerification?{verification:jobVerification}:{})}:commandId===other?trend:null}};
 const handler=createTTFotosApi({db:store.db,r2:store.r2,authenticate:async()=>({isEditor:editor}),jobProvider});
 const base='https://ttactualidad.rainyraven22.chatgpt.site';
 const post=async(route,form,{origin=base}={})=>handler(new Request(base+'/api/tt-fotos/v1'+route,{method:'POST',headers:{origin,'x-tt-fotos-action':'editor-v1'},body:form}));
 const get=async(route)=>handler(new Request(base+'/api/tt-fotos/v1'+route));
 function upload({bytes=png(),evidence={},expectedSHA256}={}){const f=new FormData();f.set('image',new Blob([bytes],{type:'image/png'}),'original.png');f.set('source',JSON.stringify(evidence));if(expectedSHA256)f.set('expectedSHA256',expectedSHA256);return f}
 return {store,handler,post,get,upload,base};
}
test('command identity is exact and cannot infer from title',()=>{
 assert.deepEqual(commandDetails(cmd),{commandId:cmd,project:'ttittulares',editorialId:'753d587ec61b',revision:1});
 assert(exactJob(job,commandDetails(cmd)));assert(!exactJob({...job,revision:2},commandDetails(cmd)));
 assert.equal(commandDetails('TT#15 foo'),null);
});
test('no auto-match from gallery only, filename, or wrong turn',()=>{
 const j=commandDetails(cmd);
 assert.equal(sourceEvidence({kind:'gallery_visible',conversationUrl:job.conversation_url,commandId:cmd},j,job).automatic,false);
 assert.equal(sourceEvidence({kind:'same_turn_image',rasterSource:'original_image',conversationUrl:job.conversation_url,promptText:'TTITTULARES_IMAGE_JOB_V4 tt-img-auto-000000000000-r1-a1-1794420306285'},j,job).automatic,false);
});
test('all endpoints reject unapproved editor',async()=>{
 const x=setup({editor:false});assert.equal((await x.get('/status')).status,403);
 assert.equal((await x.post('/assets',x.upload())).status,403);
 assert.equal(x.store.objects.size,0);
});
test('cross-origin POST and missing custom action rejected before storage',async()=>{
 const x=setup();assert.equal((await x.post('/assets',x.upload(),{origin:'https://evil.example'})).status,403);
 assert.equal(x.store.objects.size,0);
});
test('valid gallery PNG is privately stored as unmatched and served only after auth',async()=>{
 const x=setup(),e={kind:'gallery_visible',rasterSource:'original_image',title:'Sin título'};
 const r=await x.post('/assets',x.upload({evidence:e}));assert.equal(r.status,200);
 const v=await r.json();assert.equal(v.needsReview,true);assert.equal(v.association,null);
 assert.equal(x.store.objects.size,1);assert.equal((await x.get('/assets?state=unmatched')).status,200);
 const image=await x.get('/assets/'+v.assetSha+'/original');assert.equal(image.status,200);assert.equal(image.headers.get('content-type'),'image/png');
 assert.deepEqual(new Uint8Array(await image.arrayBuffer()),png());
});
test('trusted exact chat turn and exact current job auto-associate',async()=>{
 const x=setup(),e={kind:'same_turn_image',rasterSource:'original_image',conversationUrl:job.conversation_url,
   commandId:cmd,promptText:'TTITTULARES_IMAGE_JOB_V4 '+cmd+' 753d587ec61b'};
 const r=await x.post('/assets',x.upload({evidence:e}));const v=await r.json();
 assert.equal(v.association?.confidence,'auto_exact');assert.equal(v.needsReview,false);
 assert.equal(x.store.matches.size,1);assert.equal(x.store.jobs.size,1);assert.equal(x.store.history.length,1);
 const c=await (await x.get('/status')).json();assert.equal(c.counts.associated,1);assert.equal(c.counts.withoutMatch,0);
});
test('wrong conversation URL blocks auto-association',async()=>{
 const x=setup(),e={kind:'same_turn_image',rasterSource:'original_image',conversationUrl:'https://chatgpt.com/c/11111111-1111-1111-1111-111111111111',
   commandId:cmd,promptText:'TTITTULARES_IMAGE_JOB_V4 '+cmd};
 const v=await (await x.post('/assets',x.upload({evidence:e}))).json();assert.equal(v.needsReview,true);assert.equal(v.reason,'CONVERSATION_MISMATCH');
});
test('manual match requires exact job plus explicit editor confirmation',async()=>{
 const x=setup(),up=await (await x.post('/assets',x.upload({evidence:{kind:'gallery_visible'}}))).json();
 const wrong=JSON.stringify({assetSha:up.assetSha,commandId:cmd,project:'ttendencias',editorialId:'753d587ec61b',revision:1,confirmation:'CONFIRMAR_ASOCIACION_EDITOR'});
 let r=await x.post('/matches',wrong);assert.equal(r.status,409);
 const manual={assetSha:up.assetSha,commandId:cmd,project:'ttittulares',editorialId:'753d587ec61b',revision:1,confirmation:'CONFIRMAR_ASOCIACION_EDITOR'};
 r=await x.post('/matches',JSON.stringify({...manual,confirmation:'NO'}));assert.equal(r.status,400);
 r=await x.post('/matches',JSON.stringify(manual));assert.equal(r.status,200);assert.equal(x.store.matches.size,1);
});
test('replacing a photo changes only TT Fotos match and preserves previous original/history',async()=>{
 const x=setup(),a=await (await x.post('/assets',x.upload({bytes:png(1)}))).json(),b=await (await x.post('/assets',x.upload({bytes:png(2)}))).json();
 const base={commandId:cmd,project:'ttittulares',editorialId:'753d587ec61b',revision:1,confirmation:'CONFIRMAR_ASOCIACION_EDITOR'};
 await x.post('/matches',JSON.stringify({...base,assetSha:a.assetSha}));const replace=await (await x.post('/matches',JSON.stringify({...base,assetSha:b.assetSha}))).json();
 assert.equal(replace.association.operation,'replace');assert.equal(x.store.matches.size,1);assert.equal(x.store.history.length,2);
 assert.equal(x.store.objects.size,2);assert.equal(x.store.matches.values().next().value.asset_sha,b.assetSha);
});
test('invalid raster SHA, non-PNG, oversized input rejected',async()=>{
 const x=setup();assert.equal((await x.post('/assets',x.upload({expectedSHA256:'a'.repeat(64)}))).status,400);
 assert.equal((await x.post('/assets',x.upload({bytes:new Uint8Array(64)}))).status,400);
 assert.equal(x.store.objects.size,0);
});
test('GET registered job includes authoritative exact identity only',async()=>{
 const x=setup(),good=await x.get('/jobs/'+encodeURIComponent(cmd));assert.equal(good.status,200);
 const miss=await x.get('/jobs/tt-img-auto-000000000000-r1-a1-1794420306285');assert.equal(miss.status,404);
 assert.equal(x.store.jobs.size,0);
});
test('missing exact receipt never triggers automatic association; editor may confirm corroborated identity',async()=>{
 const x=setup({jobVerification:'editorial_identity_only'});
 const evidence={kind:'same_turn_image',rasterSource:'original_image',conversationUrl:job.conversation_url,
  commandId:cmd,promptText:'TTITTULARES_IMAGE_JOB_V4 '+cmd};
 const upload=await (await x.post('/assets',x.upload({evidence}))).json();
 assert.equal(upload.needsReview,true);
 assert.equal(upload.reason,'EDITORIAL_ID_CORROBORATED_EXACT_JOB_MISSING');
 assert.equal(upload.association,null);
 assert.equal(x.store.matches.size,0);
 const lookup=await (await x.get('/jobs/'+encodeURIComponent(cmd))).json();
 assert.equal(lookup.job.verification,'editorial_identity_only');
 const decision=await (await x.post('/matches',JSON.stringify({
  assetSha:upload.assetSha,commandId:cmd,project:'ttittulares',
  editorialId:'753d587ec61b',revision:1,confirmation:'CONFIRMAR_ASOCIACION_EDITOR'
 }))).json();
 assert.equal(decision.verification,'editorial_identity_only');
 assert.equal(decision.association.confidence,'editor_confirmed');
 assert.equal(x.store.matches.size,1);
});

test('reimporting the same photo and repeating manual confirmation is idempotent',async()=>{
 const x=setup(),e={kind:'same_turn_image',rasterSource:'original_image',conversationUrl:job.conversation_url,
   commandId:cmd,promptText:'TTITTULARES_IMAGE_JOB_V4 '+cmd};
 const first=await (await x.post('/assets',x.upload({evidence:e}))).json();
 assert.equal(first.association?.operation,'associate');
 const again=await (await x.post('/assets',x.upload({evidence:e}))).json();
 assert.equal(again.existing,true);
 assert.equal(again.association?.operation,'unchanged');
 assert.equal(again.association?.confidence,'auto_exact');
 assert.equal(x.store.history.length,1);
 const manual=await (await x.post('/matches',JSON.stringify({assetSha:first.assetSha,commandId:cmd,
  project:'ttittulares',editorialId:'753d587ec61b',revision:1,
  confirmation:'CONFIRMAR_ASOCIACION_EDITOR'}))).json();
 assert.equal(manual.association.operation,'unchanged');
 assert.equal(manual.association.confidence,'auto_exact');
 assert.equal(x.store.matches.size,1);
 assert.equal(x.store.history.length,1);
});
