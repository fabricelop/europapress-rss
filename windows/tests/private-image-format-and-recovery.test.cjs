'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const crypto=require('node:crypto'),vm=require('node:vm');
const {editorialJob,metadata,persistOriginal,cachedOriginal,discardOriginal,send}=require('../TTImageApprovalReceiver.cjs');
const trend=require('../TTendenciasWebImages.cjs'),news=require('../TTiTTularesWebImages.cjs');
const hash=v=>crypto.createHash('sha256').update(v).digest('hex');
const png=()=>{let b=Buffer.alloc(12600);Buffer.from('89504e470d0a1a0a','hex').copy(b);return b;};

for(const [name,consumer,userText] of [
 ['ttendencias',trend,'TTENDENCIAS_IMAGE_JOB_V4 job-exact trend-abc'],
 ['ttittulares',news,'TTITTULARES_IMAGE_JOB_V4 job-exact news-abc']]){
 test(name+' keeps legacy WebP untouched, but converts to private PNG without another image generation',async()=>{
  const u={innerText:userText,textContent:userText,contains:()=>false,
    compareDocumentPosition:()=>4};
  const img={alt:'AI illustration',complete:true,naturalWidth:1536,naturalHeight:1024,
    src:'https://chatgpt.com/render/original',compareDocumentPosition:()=>4};
  const sourceBlob=new Blob([Buffer.alloc(12500)],{type:'image/webp'});
  const converted=new Blob([png()],{type:'image/png'});
  const ctx={drawImage(){ctx.drawn=true}};
  const canvas={getContext:()=>ctx,toBlob:(callback,type)=>{assert.equal(type,'image/png');callback(converted)}};
  const document={
    querySelectorAll:q=>q==='img'?[img]:q==='[data-user-message-bubble="true"]'?[u]:[],
    querySelector:()=>null,createElement:q=>{assert.equal(q,'canvas');return canvas}
  };
  let decode=async flag=>{
    const sandbox={document,Node:{DOCUMENT_POSITION_FOLLOWING:4},
      fetch:async()=>({ok:true,blob:async()=>sourceBlob}),
      createImageBitmap:async blob=>{assert.equal(blob.type,'image/webp');return {width:1536,height:1024,close(){}}},
      Uint8Array,Blob,btoa:x=>Buffer.from(x,'binary').toString('base64')};
    return vm.runInNewContext(consumer.rasterProbe('job-exact',flag),sandbox);
  };
  const standard=await decode(false);
  assert.equal(standard.ready,true);
  assert.ok(standard.dataUrl.startsWith('data:image/webp;base64,'));
  const privateRaster=await decode(true);
  assert.equal(privateRaster.ready,true);
  assert.equal(privateRaster.sourceMime,'image/webp');
  assert.ok(privateRaster.dataUrl.startsWith('data:image/png;base64,'));
  assert.equal(Buffer.from(privateRaster.dataUrl.split(',')[1],'base64').subarray(0,8).toString('hex'),'89504e470d0a1a0a');
  assert.equal(ctx.drawn,true);
 });
}

test('missing news preparation time recovered from exact READY processing receipt after Listas',async()=>{
 const job={command_id:'job-news',event_id:'news-abc',revision:1,target_name:'Noticia lista',
    context_snapshot:{title:'Noticia lista',tweet_text:'Texto cerrado',
      factual_summary:'Hechos',remate:'Remate'}};
 const task={project:'ttittulares',target_id:'news-abc',command_id:'job-news',revision:1,
    editorial_sha256:hash(['Texto cerrado','Hechos','Remate'].join('\n'))};
 const fetcher=async url=>Response.json(url.includes('prepared.json')?{items:[]}:
  {items:[{event_id:'news-abc',revision:1,title:'Noticia lista',status:'READY',
    delivery_confirmation:'prepared_web',delivered_at:'2026-11-05T23:18:12.111419Z'}]});
 const recovered=await editorialJob({readImageJob:async()=>job},task,fetcher);
 assert.equal(recovered.context_snapshot.prepared_at,'2026-11-05T23:18:12.111419Z');
 assert.equal(metadata(task,recovered).editorialAt,'2026-11-05T23:18:12.111419Z');
 await assert.rejects(editorialJob({readImageJob:async()=>job},task,
  async()=>Response.json({items:[{event_id:'news-abc',revision:2,title:'Noticia lista',
    delivery_confirmation:'prepared_web',delivered_at:'2026-11-05T23:18:12Z'}]})),/PREPARED_DATE_NOT_RECOVERABLE/);
});

test('original raster is cached by exact episode and kept after network failure',async t=>{
 const base=fs.mkdtempSync(path.join(os.tmpdir(),'private-inbox-'));
 t.after(()=>fs.rmSync(base,{recursive:true,force:true}));
 const job={command_id:'job-abc',target_id:'trend-abc',revision:0,
    context_snapshot:{name:'Tendencia',explanation:'Texto original',explained_at:'2026-11-05T21:00:00Z'}};
 const task={command_id:'job-abc',target_id:'trend-abc',revision:0,
    explanation_sha256:hash('Texto original')};
 const meta=metadata(task,job),bytes=png();
 persistOriginal(base,task,meta,bytes);
 assert.deepEqual(cachedOriginal(base,task,meta),bytes);
 assert.doesNotThrow(()=>persistOriginal(base,task,meta,bytes)); // idempotent
 await assert.rejects(send(meta,bytes,'private-secret',async()=>Response.json({error:'unavailable'},{status:503})),/PRIVATE_RECEIPT_HTTP_503/);
 assert.deepEqual(cachedOriginal(base,task,meta),bytes);
 assert.throws(()=>cachedOriginal(base,task,{...meta,editorialText:'Other',episodeFingerprint:'different'}),/CACHED_ORIGINAL_CONFLICT/);
 await assert.rejects(send(meta,bytes,'private-secret',async()=>Response.json({id:'a'.repeat(64),state:'rejected'},{status:200})),/PRIVATE_RECEIPT_REJECTED/);
 discardOriginal(base,task);
 assert.equal(cachedOriginal(base,task,meta),null);
});
