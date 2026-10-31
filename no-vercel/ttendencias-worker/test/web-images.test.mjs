import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import worker from '../src/index.js';
import {webReceiptContext,explanationHash} from '../generated/lib/ttendencias-web-image-receipt.js';
const id='trend-test-123',command='tr-img-test-123',secret='test-secret-'+ 'x'.repeat(40),text='TT#14 Hecho vigente.\n#Prueba';
function setup(status='ERROR',editorial='explained'){
 const job={project:'ttendencias',target_id:id,command_id:command,revision:0,status,delivery_mode:'launch_only',attempt:1,context_snapshot:{explanation:text,explained_at:'2026-10-31T01:00:00Z'},pc_upload_secret_hash:crypto.createHash('sha256').update(secret).digest('hex')};
 const row={id,revision:0,status:editorial,telegram_package_status:editorial,explanation:text,explained_at:job.context_snapshot.explained_at};
 const docs=new Map([['trends/image-runs/jobs/'+id+'.json',job],['trends/telegram-manual-explained.json',{items:[row]}],['ttittulares/prepared.json',{items:[]}]]),puts=[],gets=[];
 const fetch=async(url,opts={})=>{
  const u=new URL(url),prefix='/repos/fabricelop/europapress-rss/contents/';assert.ok(u.pathname.startsWith(prefix),'only the existing repository');
  const path=decodeURIComponent(u.pathname.slice(prefix.length));
  if(opts.method==='PUT'){const body=JSON.parse(opts.body);puts.push({path,body});const bytes=Buffer.from(body.content,'base64');docs.set(path,path.endsWith('.json')?JSON.parse(bytes.toString()):bytes);return Response.json({content:{sha:'1'.repeat(40)}});}
  gets.push(path);if(!docs.has(path))return Response.json({message:'not found'},{status:404});const value=docs.get(path),raw=Buffer.isBuffer(value)?value:Buffer.from(JSON.stringify(value));return Response.json({sha:'1'.repeat(40),encoding:'base64',content:raw.toString('base64')});
 };
 const bytes=Buffer.alloc(16000);Buffer.from([137,80,78,71,13,10,26,10]).copy(bytes);bytes.write('IHDR',12);bytes.writeUInt32BE(1536,16);bytes.writeUInt32BE(864,20);
 const body={task:'web_image_upload',target_id:id,command_id:command,upload_secret:secret,context_explanation_sha256:explanationHash(text),image_data_url:'data:image/png;base64,'+bytes.toString('base64'),capture:{method:'original-fetch-img-web-consumer',width:1536,height:864}};
 return {job,row,docs,puts,gets,fetch,body};
}
async function run(s,body=s.body){const original=globalThis.fetch;globalThis.fetch=s.fetch;try{return await worker.fetch(new Request('https://worker.test/api/ttendencias-run',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)}),{GITHUB_TOKEN:'test-only'});}finally{globalThis.fetch=original;}}
test('existing raster from uncertain ERROR attaches after publication; replay cannot duplicate',async()=>{
 const s=setup('ERROR','published'),r=await run(s);assert.equal(r.status,200,await r.clone().text());assert.equal((await r.json()).status,'DONE');const row=s.docs.get('trends/telegram-manual-explained.json').items[0];assert.equal(row.status,'published');assert.equal(row.explanation,text);assert.equal(row.ai_image.context_guard.command_id,command);assert.equal(row.ai_image.context_guard.explanation,text);assert.equal(s.puts.filter(x=>x.path.endsWith('.png')).length,1);assert.equal(s.gets.some(x=>x.includes('copy-state')),false);const second=await run(s);assert.equal(second.status,200);assert.equal((await second.json()).idempotent,true);assert.equal(s.puts.filter(x=>x.path.endsWith('.png')).length,1);
});
test('cancellations, wrong secrets, changed text, revisions and episodes cannot write',async()=>{
 for(const kind of ['cancelled','secret','text','revision','episode']){const s=setup(),body={...s.body};if(kind==='cancelled')s.job.status='CANCELLED';if(kind==='secret')body.upload_secret='wrong';if(kind==='text')s.row.explanation='Reelaborada';if(kind==='revision')s.row.revision=1;if(kind==='episode')s.row.explained_at='2026-10-31T02:00:00Z';const r=await run(s,body);assert.ok([401,409].includes(r.status),kind);assert.equal(s.puts.length,0,kind);}
});
test('legacy image upload keeps its conservative terminal gate',async()=>{const s=setup(),r=await run(s,{...s.body,task:'image_upload'});assert.equal(r.status,409);assert.equal(s.puts.length,0);});
test('public contract exposes receipt version without credentials',async()=>{const r=await worker.fetch(new Request('https://worker.test/api/ttendencias-run-status?view=web-image-contract'),{}),d=await r.json();assert.equal(d.web_image_receipt,2);assert.equal(d.generates_images,false);});
test('rank changes keep identity; another editorial ID never does',()=>{const s=setup();s.row.rank=1;assert.equal(webReceiptContext(s.job,s.row,explanationHash(text)),null);assert.equal(webReceiptContext(s.job,{...s.row,id:'other'},explanationHash(text)),'revision_changed');});
