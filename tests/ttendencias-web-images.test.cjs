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
    const doc=String(url).includes('image-runs/jobs/')?j:m;
    return {ok:true,status:200,json:async()=>doc};
  };
  try{await fn(calls);}finally{global.fetch=original;}
}
test('solo la imagen del mismo ID, revisión, comando y texto se confirma',async t=>{
  await withDocuments(t,job(),manual(),async calls=>{
    const r=await consume(task());
    assert.equal(r.status,'published');
    assert.equal(r.sha256,IMAGE_HASH);
    assert.equal(calls.length,2);
    assert.ok(calls.every(x=>x.startsWith('https://raw.githubusercontent.com/')));
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
    assert.equal(calls.length,1);
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
