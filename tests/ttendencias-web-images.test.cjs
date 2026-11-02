'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const crypto=require('node:crypto');
const {consume,dueTasks,sameContext,chatURL}=require('../windows/TTendenciasWebImages.cjs');
const sha=t=>crypto.createHash('sha256').update(t).digest('hex');
const ID='trend-first-2026',COMMAND='tr-img-auto-trend-first-2026-r0-a1-1234567890';
const TEXT='TT#14 Primera tendencia por un hecho corroborado.';
const HASH=sha(TEXT),IMAGE_HASH='f'.repeat(64);
const task=()=>({target_id:ID,command_id:COMMAND,revision:0,explanation_sha256:HASH,upload_accepted_at:'2026-10-30T21:00:00Z'});
const job=()=>({target_id:ID,command_id:COMMAND,revision:0,context_snapshot:{explanation:TEXT},status:'DONE',upload_sha256:IMAGE_HASH});
const manual=()=>({items:[{id:ID,revision:0,explanation:TEXT,ai_image:{generated:true,provider:'chat-imagegen',command_id:COMMAND,target_id:ID,revision:0,sha256:IMAGE_HASH,url:'https://raw.githubusercontent.com/fabricelop/europapress-rss/main/trends/generated-images/'+ID+'.png'}}]});
async function withDocuments(t,j,m,fn){
  const original=global.fetch;
  const calls=[];
  global.fetch=async url=>{
    calls.push(String(url));
    const doc=(String(url).includes('image-runs/jobs/')||String(url).includes('view=image-job'))?j:m;
    return {ok:true,status:200,json:async()=>doc};
  };
  try{await fn(calls);}finally{global.fetch=original;}
}
test('solo la imagen del mismo ID, revisión, comando y texto se confirma',async t=>{
  await withDocuments(t,job(),manual(),async calls=>{
    const r=await consume(task());
    assert.equal(r.status,'published');
    assert.equal(r.sha256,IMAGE_HASH);
    assert.ok(calls.length>=2);
    assert.ok(calls.slice(0,2).every(x=>x.startsWith('https://raw.githubusercontent.com/')));
    assert.ok(calls.slice(2).every(x=>x.startsWith('http://127.0.0.1:')));
  });
});
test('un enlace atribuido a otro comando nunca se marca entregado',async t=>{
  const m=manual();m.items[0].ai_image.command_id='tr-img-other';
  await withDocuments(t,job(),m,async()=>assert.equal((await consume(task())).status,'waiting'));
});
test('una tendencia reelaborada invalida la imagen de su texto anterior',async t=>{
  const m=manual();m.items[0].revision=1;
  await withDocuments(t,job(),m,async()=>assert.equal((await consume(task())).status,'obsolete'));
});
test('se rechaza la imagen de una revisión o ID distintos aunque la URL parezca correcta',async t=>{
  const m=manual();m.items[0].ai_image.target_id='another-trend';
  await withDocuments(t,job(),m,async()=>assert.equal((await consume(task())).status,'waiting'));
  m.items[0].ai_image.target_id=ID;m.items[0].ai_image.revision=1;
  await withDocuments(t,job(),m,async()=>assert.equal((await consume(task())).status,'waiting'));
});
test('un raster anterior sin prueba positiva de comando o SHA no se atribuye al nuevo job',async t=>{
  const m=manual();delete m.items[0].ai_image.command_id;delete m.items[0].ai_image.sha256;
  await withDocuments(t,job(),m,async()=>assert.equal((await consume(task())).status,'waiting'));
});
test('un upload aceptado se puede confirmar aunque el estado del job siga LAUNCHED',async t=>{
  const j=job();j.status='LAUNCHED';delete j.upload_sha256;
  const q=task();q.sha256=IMAGE_HASH;
  await withDocuments(t,j,manual(),async()=>assert.equal((await consume(q)).status,'published'));
});
test('un job no coincidente no puede abrir el navegador ni subir un raster',async t=>{
  const j=job();j.command_id='tr-img-other';
  await withDocuments(t,j,manual(),async calls=>{
    assert.equal((await consume(task())).status,'obsolete');
    assert.equal(calls.length,2);
    assert.ok(calls.every(x=>!x.includes('127.0.0.1')));
  });
});
test('la cola atiende otros trabajos aunque uno siga esperando imagen',()=>{
  const now=Date.parse('2026-10-31T00:00:00Z');
  const old={task:{status:'waiting',created_at:'2026-10-30T08:00:00Z',checked_at:'2026-10-30T23:59:00Z'}};
  const fresh={task:{status:'waiting',created_at:'2026-10-30T22:00:00Z',checked_at:'2026-10-30T22:15:00Z'}};
  const notDue={task:{status:'waiting',next_check_at:'2026-11-01T00:00:00Z',created_at:'2026-10-30T01:00:00Z'}};
  const done={task:{status:'published',created_at:'2026-10-30T01:00:00Z'}};
  assert.deepEqual(dueTasks([old,fresh,notDue,done],now),[fresh,old]);
});
test('solo URLs reales de conversación sirven para asociar imágenes',()=>{
  assert.equal(chatURL('https://chatgpt.com/c/6ae4adf9-f5b8-83ed-a524-37232d9b9992'),'https://chatgpt.com/c/6ae4adf9-f5b8-83ed-a524-37232d9b9992');
  assert.equal(chatURL('https://chatgpt.com/'),null);
  assert.equal(chatURL('https://external.example/c/6ae4adf9-f5b8-83ed-a524-37232d9b9992'),null);
});
test('los puestos del Top30 no intervienen en identidad de imagen',()=>{
  assert.ok(sameContext(task(),job()));
  const j=job();j.context_snapshot.rank_at_explanation=29;
  assert.ok(sameContext(task(),j));
});

test('an uncertain ERROR with a saved handoff is kept pending while receiver update is unavailable',async()=>{
 const j=job();j.status='ERROR';delete j.upload_sha256;
 const q={...task(),conversation_url:'https://chatgpt.com/c/abc-123'};delete q.upload_accepted_at;
 await withDocuments(null,j,manual(),async()=>{const result=await consume(q);assert.equal(result.status,'waiting');assert.equal(result.reason,'browser_unavailable_original_not_captured');});
});

test('network failure reading RAW falls back to the existing strong receiver without bypassing identity',async()=>{
 const {readImageJob,readEditorialState}=require('../windows/TTendenciasWebImages.cjs');const original=global.fetch;const q=task();
 global.fetch=async url=>{if(String(url).startsWith('https://raw.githubusercontent.com/'))throw new TypeError('fetch failed');return {ok:true,json:async()=>String(url).includes('view=image-job')?job():{explained:manual()}};};
 try{assert.ok(sameContext(q,await readImageJob(q)));assert.equal((await readEditorialState()).items[0].id,ID);}finally{global.fetch=original;}
});
test('network failures identify the stopped stage without leaking request URLs',async()=>{
 const {readImageJob}=require('../windows/TTendenciasWebImages.cjs');const original=global.fetch;global.fetch=async()=>{const e=new TypeError('fetch failed');e.cause={code:'ECONNREFUSED'};throw e;};
 try{await assert.rejects(()=>readImageJob(task()),/image_job_ECONNREFUSED/);}finally{global.fetch=original;}
});

test('an unavailable 9234 relay falls back to existing 9223 using only discovery GETs',async()=>{
 const {selectExistingBrowser}=require('../windows/TTendenciasWebImages.cjs');const original=global.fetch,calls=[];
 global.fetch=async(url,opts)=>{calls.push(String(url));assert.equal(opts.method,undefined);if(String(url).includes(':9234')){const e=new TypeError('fetch failed');e.cause={code:'ECONNREFUSED'};throw e;}return {ok:true,json:async()=>String(url).endsWith('/json/version')?{webSocketDebuggerUrl:'ws://127.0.0.1:9223/devtools/browser/test'}:[{type:'page',url:'https://chatgpt.com/c/abc-123'}]};};
 try{const selected=await selectExistingBrowser();assert.equal(selected.source,'generator_9223');assert.equal(selected.base,'http://127.0.0.1:9223');assert.deepEqual(calls,['http://127.0.0.1:9234/json/version','http://127.0.0.1:9223/json/version','http://127.0.0.1:9223/json/list']);}finally{global.fetch=original;}
});
test('a healthy relay remains preferred and never contacts the generator',async()=>{
 const {selectExistingBrowser}=require('../windows/TTendenciasWebImages.cjs');const original=global.fetch;
 global.fetch=async url=>{assert.ok(String(url).startsWith('http://127.0.0.1:9234/'));return {ok:true,json:async()=>String(url).endsWith('/json/version')?{webSocketDebuggerUrl:'ws://127.0.0.1:9234/devtools/browser/test'}:[{type:'page',url:'https://chatgpt.com/'}]};};
 try{assert.equal((await selectExistingBrowser()).source,'relay_9234');}finally{global.fetch=original;}
});
test('neither unavailable browser starts a process or opens an arbitrary conversation',async()=>{
 const {selectExistingBrowser}=require('../windows/TTendenciasWebImages.cjs');const original=global.fetch,calls=[];
 global.fetch=async url=>{calls.push(String(url));const e=new TypeError('fetch failed');e.cause={code:'ECONNREFUSED'};throw e;};
 try{await assert.rejects(()=>selectExistingBrowser(),/relay_version_ECONNREFUSED;generator_version_ECONNREFUSED/);assert.equal(calls.length,2);assert.ok(calls.every(x=>x.endsWith('/json/version')));}finally{global.fetch=original;}
});


test('the exact Site-return follow-up does not orphan the existing original raster',()=>{
 const {conversationProbe,rasterProbe}=require('../windows/TTendenciasWebImages.cjs');
 const conv=conversationProbe(COMMAND,true);
 const raster=rasterProbe(COMMAND);
 assert.match(conv,/TTENDENCIAS_SITE_RETURN_AFTER_IMAGE_V1/);
 assert.match(raster,/TTENDENCIAS_SITE_RETURN_AFTER_IMAGE_V1/);
 assert.match(raster,/later_user_turn/);
 assert.match(raster,/ambiguous_or_missing_raster/);
 // Only one adjacent follow-up for the SAME command may keep the raster
 // accessible; arbitrary later user messages must never match.
 assert.match(raster,/users\.length-2/);
 assert.match(raster,/command\+' '/);
});


test('la cola reintenta asociación Site de imágenes ya publicadas con una conversación original',()=>{
 const now=Date.parse('2026-11-01T11:30:00Z');
 const published={task:{status:'published',created_at:'2026-11-01T10:00:00Z',conversation_url:'https://chatgpt.com/c/6ae4adf9-f5b8-83ed-a524-37232d9b9992'}};
 const attached={task:{...published.task,site_return_sent_at:'2026-11-01T11:00:00Z'}};
 const old={task:{...published.task,created_at:'2026-10-27T10:00:00Z'}};
 const noConversation={task:{...published.task,conversation_url:null}};
 assert.deepEqual(dueTasks([published,attached,old,noConversation],now),[published]);
});
test('un reintento Site solo instruye asociar el PNG original y conserva identidad exacta',()=>{
 const {siteReturnPrompt,siteReturnProbe}=require('../windows/TTendenciasWebImages.cjs');
 const t={target_id:ID,command_id:COMMAND,revision:0};
 const j={target_name:'Tendencia primera',context_snapshot:{explanation:TEXT,explained_at:'2026-11-01T10:40:57+01:00'}};
 const prompt=siteReturnPrompt(t,j);
 assert.ok(prompt.startsWith('TTENDENCIAS_SITE_RETURN_AFTER_IMAGE_V1 '+COMMAND+' '+ID));
 assert.match(prompt,/NO GENERES NINGUNA IMAGEN/);
 assert.match(prompt,/attach_trend_image/);
 assert.match(prompt,/verify_trend_image/);
 assert.match(prompt,/trends\/site-ai-images.json/);
 const m=prompt.match(/CONTEXTO EXACTO Y AUTORITATIVO \(revalídalo antes de escribir\): (\{[^\n]+\})/);
 assert.ok(m);
 const ctx=JSON.parse(m[1]);
 assert.equal(ctx.target_id,ID);assert.equal(ctx.revision,0);
 assert.equal(ctx.explanation,TEXT);
 assert.equal(ctx.explained_at,'2026-11-01T10:40:57+01:00');
 assert.match(siteReturnProbe(COMMAND,ID,'TTENDENCIAS_SITE_RETURN_AFTER_IMAGE_V1 '+COMMAND+' '+ID),/different_last_user_turn/);
 assert.match(siteReturnProbe(COMMAND,ID,'TTENDENCIAS_SITE_RETURN_AFTER_IMAGE_V1 '+COMMAND+' '+ID),/already_sent/);
});
test('si solo hay navegador productor 9223, no se crea pestaña de recuperación ni nueva generación',async()=>{
 const {recoverSiteAfterUpload}=require('../windows/TTendenciasWebImages.cjs');
 const original=global.fetch;
 const calls=[];
 const j=job(),m=manual();
 global.fetch=async(url,opts={})=>{
   calls.push({url:String(url),method:opts.method});
   if(String(url).includes(':9234/')){const e=new TypeError('unavailable');e.cause={code:'ECONNREFUSED'};throw e;}
   const doc=String(url).endsWith('/json/version')?{webSocketDebuggerUrl:'ws://127.0.0.1:9223/devtools/browser/test'}:
     String(url).endsWith('/json/list')?[{type:'page',url:'https://chatgpt.com/'}]:
     String(url).includes('telegram-manual-explained')?m:j;
   return {ok:true,status:200,json:async()=>doc};
 };
 try{
   const q={...task(),status:'published',conversation_url:'https://chatgpt.com/c/6ae4adf9-f5b8-83ed-a524-37232d9b9992'};
   const result=await recoverSiteAfterUpload(q,j);
   assert.equal(result.status,'published');
   assert.equal(result.site_return_status,'original_generator_tab_not_present');
   assert.ok(calls.every(x=>!x.method||x.method==='GET'));
 }finally{global.fetch=original;}
});

test('TTImages: un nuevo encargo gana dentro de la misma identidad, sin bloquear otras tendencias',()=>{
 const now=Date.parse('2026-11-01T11:53:00Z');
 const older={task:{target_id:'target-1',command_id:'tr-img-old-1',revision:0,status:'waiting',created_at:'2026-11-01T09:00:00Z'}};
 const newer={task:{target_id:'target-1',command_id:'tr-img-new-1',revision:0,status:'waiting',created_at:'2026-11-01T11:50:00Z'}};
 const other={task:{target_id:'target-2',command_id:'tr-img-another',revision:0,status:'waiting',created_at:'2026-11-01T11:51:00Z'}};
 const {newestActiveByTarget}=require('../windows/TTendenciasWebImages.cjs');
 assert.equal(newestActiveByTarget([older,newer,other],now).get('target-1'),newer);
 assert.deepEqual(dueTasks([older,newer,other],now),[other,newer]);
 // Failure/expiry of newest allows eligible old fallback without deleting it.
 newer.task.status='rejected';
 assert.deepEqual(dueTasks([older,newer,other],now),[other,older]);
});
test('TTImages: una imagen nueva publicada desprioriza intentos previos del mismo ID',()=>{
 const now=Date.parse('2026-11-01T11:53:00Z');
 const older={task:{target_id:'joint-group-1',command_id:'tr-img-old',status:'waiting',created_at:'2026-11-01T11:10:00Z'}};
 const newer={task:{target_id:'joint-group-1',command_id:'tr-img-new',status:'published',created_at:'2026-11-01T11:48:00Z',conversation_url:'https://chatgpt.com/c/6ae4adf9-f5b8-83ed-a524-37232d9b9992'}};
 const unrelated={task:{target_id:'term-other',command_id:'tr-img-other',status:'waiting',created_at:'2026-11-01T11:49:00Z'}};
 assert.deepEqual(dueTasks([older,newer,unrelated],now),[unrelated,newer]);
 newer.task.site_return_sent_at='2026-11-01T11:50:00Z';
 assert.deepEqual(dueTasks([older,newer,unrelated],now),[unrelated]);
});
