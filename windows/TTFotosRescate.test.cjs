'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const http = require('node:http');
const moduleUnderTest = require('./TTFotosRescate.cjs');
function tmp(t) { const base = fs.mkdtempSync(path.join(os.tmpdir(), 'tt-fotos-rescate-test-')); t.after(()=>fs.rmSync(base,{recursive:true, force:true})); return base; }
const command='tt-img-auto-123456789abc-r1-a1-1794408088560';
const png=Buffer.concat([Buffer.from('89504e470d0a1a0a','hex'),Buffer.alloc(50, 0)]);
const digest = crypto.createHash('sha256').update(png).digest('hex');
const fp = 'a'.repeat(64);
function makeFixture(t){
 const base=tmp(t);
 fs.mkdirSync(path.join(base,'ttittulares-web-images'),{recursive:true});
 fs.mkdirSync(path.join(base,'image-approval-receipts','immediate-originals'),{recursive:true});
 const enrollment={command_id:command,target_id:'123456789abc',revision:1,
   secret_dpapi:'opaque-secret-do-not-expose',status:'waiting',created_at:'2026-11-11T15:00:00Z', editorial_sha256:fp};
 fs.writeFileSync(path.join(base,'ttittulares-web-images',command+'.json'),JSON.stringify(enrollment));
 fs.writeFileSync(path.join(base,'image-approval-receipts','immediate-originals',command+'.png'),png);
 fs.writeFileSync(path.join(base,'image-approval-receipts','immediate-originals',command+'.json'),JSON.stringify({project:'ttittulares',commandId:command,editorialId:'123456789abc',revision:1,editorialFingerprint:fp,sha256:digest}));
 return base;
}
test('inventories exact original without classifying it as delivered',t=>{
 const base=makeFixture(t),doc=moduleUnderTest.inventory(base);
 assert.equal(doc.counts.total,1);assert.equal(doc.counts.received,0);
 assert.equal(doc.counts.originalNotDelivered,1);assert.equal(doc.jobs[0].originalSha,digest);
 assert(!JSON.stringify(doc).includes('opaque-secret-do-not-expose'));
});
test('does not associate orphan via similarity, and does not upload',t=>{
 const base=makeFixture(t);const dir=path.join(base,'image-approval-receipts','immediate-originals');
 fs.writeFileSync(path.join(dir,'tt-img-auto-ffffffffffff-r1.png'),png);
 const doc=moduleUnderTest.inventory(base);assert.equal(doc.counts.orphans,1);
 assert.equal(doc.orphans[0].phase,'ORIGINAL_SIN_METADATOS_VERIFICABLES');
});
test('rejects conflicting command enrollments',t=>{
 const base=makeFixture(t);fs.mkdirSync(path.join(base,'ttendencias-web-images'));
 fs.writeFileSync(path.join(base,'ttendencias-web-images','collision.json'),JSON.stringify({command_id:command,target_id:'ffffffffffff',revision:0,status:'waiting'}));
 assert(moduleUnderTest.enrollmentFiles(base).duplicates.has(command));
 assert.equal(moduleUnderTest.inventory(base).jobs[0].phase,'IDENTIDAD_DUPLICADA');
});
test('correct local receipt proves delivery of the exact item',t=>{
 const base=makeFixture(t);fs.writeFileSync(path.join(base,'image-approval-receipts',command+'.json'),JSON.stringify({commandId:command,editorialId:'123456789abc',project:'ttittulares',revision:1,rasterSHA256:digest,id:'b'.repeat(64),state:'pending'}));
 assert.equal(moduleUnderTest.inventory(base).jobs[0].phase,'RECIBIDA_CON_RECIBO');
});

test('existing receiver lock does not stop recovery audit or block other deliveries',async t=>{
 const base=makeFixture(t),root=path.join(base,'image-approval-receipts');
 const lock=path.join(root,'receiver.lock');
 fs.writeFileSync(lock,JSON.stringify({pid:process.pid,at:Date.now()}));
 await assert.rejects(()=>moduleUnderTest.deliver(base),/MISSING_APPROVAL_RECEIVER/);
 assert(fs.existsSync(lock),'foreign lock must survive');
 assert.equal(moduleUnderTest.inventory(base).counts.received,0);
});
test('missing dependency does not create lock or erase originals',async t=>{
 const base=makeFixture(t),lock=path.join(base,'image-approval-receipts','receiver.lock');
 await assert.rejects(()=>moduleUnderTest.deliver(base),/MISSING_APPROVAL_RECEIVER/);
 assert(!fs.existsSync(lock));
 assert.equal(moduleUnderTest.inventory(base).counts.originalNotDelivered,1);
});

test('local dashboard exposes read-only verified originals and never leaks enrollment secrets', async t=>{
 const base=makeFixture(t),server=moduleUnderTest.serve(base,{port:0});
 t.after(async()=>{await new Promise(resolve=>server.close(resolve))});
 if(!server.listening)await new Promise(resolve=>server.once('listening',resolve));
 const url='http://127.0.0.1:'+server.address().port;
 const r=await fetch(url+'/api/status');assert.equal(r.status,200);
 const status=await r.text();assert(!status.includes('opaque-secret-do-not-expose'));
 assert.equal(JSON.parse(status).counts.originalNotDelivered,1);
 const preview=await fetch(url+'/api/original/'+command);assert.equal(preview.status,200);
 assert(Buffer.from(await preview.arrayBuffer()).equals(png));
 assert.equal((await fetch(url+'/api/original/'+command,{method:'POST'})).status,405);
 const denied=await new Promise(resolve=>{const req=http.request(url+'/api/status',{headers:{Host:'evil.localhost'}},res=>{res.resume();res.on('end',()=>resolve(res.statusCode));});req.end();});
 assert.equal(denied,403);
 assert.equal((await fetch(url+'/api/status',{headers:{Origin:'https://evil.example'}})).status,403);
 assert.equal((await fetch(url+'/api/status',{headers:{'Sec-Fetch-Site':'cross-site'}})).status,403);
});

test('duplicate enrollments with identical identity are quarantined, not silently guessed',t=>{
 const base=makeFixture(t),file=path.join(base,'ttittulares-web-images','duplicate.json');
 const existing=JSON.parse(fs.readFileSync(path.join(base,'ttittulares-web-images',command+'.json'),'utf8'));
 fs.writeFileSync(file,JSON.stringify(existing));
 assert.equal(moduleUnderTest.inventory(base).jobs[0].phase,'IDENTIDAD_DUPLICADA');
});

test('orphan image preview remains local and never changes associations',async t=>{
 const base=makeFixture(t),dir=path.join(base,'image-approval-receipts','immediate-originals');
 fs.writeFileSync(path.join(dir,'orphan-test.png'),png);
 const server=moduleUnderTest.serve(base,{port:0});
 t.after(async()=>new Promise(resolve=>server.close(resolve)));
 if(!server.listening)await new Promise(resolve=>server.once('listening',resolve));
 const url='http://127.0.0.1:'+server.address().port;
 const preview=await fetch(url+'/api/orphan/immediate-originals/orphan-test.png');
 assert.equal(preview.status,200);
 assert(Buffer.from(await preview.arrayBuffer()).equals(png));
 assert.equal((await fetch(url+'/api/orphan/immediate-originals/no-such.png')).status,404);
 assert.equal((await fetch(url+'/api/orphan/immediate-originals/%2e%2e%2forphan-test.png')).status,404);
 assert.equal((await fetch(url+'/api/orphan/original-cache/orphan-test.png')).status,404);
});

test('two different valid PNGs under same command are not auto-selected',t=>{
 const base=makeFixture(t),root=path.join(base,'image-approval-receipts','original-cache');
 fs.mkdirSync(root,{recursive:true});
 const other=Buffer.concat([Buffer.from('89504e470d0a1a0a','hex'),Buffer.alloc(50,1)]);
 const otherSha=crypto.createHash('sha256').update(other).digest('hex');
 fs.writeFileSync(path.join(root,command+'.png'),other);
 fs.writeFileSync(path.join(root,command+'.json'),JSON.stringify({commandId:command,editorialId:'123456789abc',revision:1,rasterSHA256:otherSha}));
 const doc=moduleUnderTest.inventory(base);
 assert.equal(doc.counts.originalNotDelivered,0);
 assert.equal(doc.jobs[0].phase,'IMAGEN_NO_VERIFICADA');
});
test('date filter uses Madrid local calendar day and excludes unknown dates',t=>{
 const base=makeFixture(t);
 assert.equal(moduleUnderTest.inventory(base,{since:'2026-11-10'}).counts.total,1);
 assert.equal(moduleUnderTest.inventory(base,{since:'2026-11-12'}).counts.total,0);
 assert.equal(moduleUnderTest.madridDate('2026-11-09T23:30:00Z'),'2026-11-10');
 assert.equal(moduleUnderTest.eligibleDate({created_at:'2026-11-09T23:30:00Z'},'2026-11-10'),true);
 assert.equal(moduleUnderTest.eligibleDate({created_at:'2026-11-09T22:30:00Z'},'2026-11-10'),false);
 assert.throws(()=>moduleUnderTest.inventory(base,{since:'yesterday'}),/INVALID_SINCE_DATE/);
});
test('manual attribution preserves downloaded PNG with exact SHA and editorial ID',t=>{
 const base=makeFixture(t),dir=path.join(base,'imports');fs.mkdirSync(dir);
 const name='Descarga-Captura.png';fs.writeFileSync(path.join(dir,name),png);
 // A preserved exact original takes priority over manual association.
 assert.throws(()=>moduleUnderTest.associateManual(base,dir,{file:name,commandId:command,sha256:digest,confirmation:'CONFIRMO_ASOCIACION_MANUAL'}),/EXACT_ORIGINAL_ALREADY_AVAILABLE/);
 const staged=path.join(base,'image-approval-receipts','immediate-originals');
 fs.rmSync(path.join(staged,command+'.png'));fs.rmSync(path.join(staged,command+'.json'));
 const link=moduleUnderTest.associateManual(base,dir,{file:name,commandId:command,sha256:digest,confirmation:'CONFIRMO_ASOCIACION_MANUAL'});
 assert.equal(link.editorialId,'123456789abc');assert.equal(link.sha256,digest);
 assert.equal(link.provenance,'editor_manual_selection_from_download');
 assert.equal(moduleUnderTest.inventory(base,{importDir:dir}).counts.manualPending,1);
 assert.equal(moduleUnderTest.inventory(base,{importDir:dir}).orphans[0].phase,'ASOCIADA_MANUAL');
 assert.equal(moduleUnderTest.readManualLinks(base).length,1);
 assert.equal(moduleUnderTest.associateManual(base,dir,{file:name,commandId:command,sha256:digest,confirmation:'CONFIRMO_ASOCIACION_MANUAL'}).sha256,digest);
 assert(fs.existsSync(path.join(base,'image-approval-receipts','manual-originals',digest+'.png')));
});
test('manual attribution requires explicit confirmation, matching hash and unique job',t=>{
 const base=makeFixture(t),dir=path.join(base,'imports');fs.mkdirSync(dir);
 fs.writeFileSync(path.join(dir,'candidate.png'),png);
 const staged=path.join(base,'image-approval-receipts','immediate-originals');
 fs.rmSync(path.join(staged,command+'.png'));fs.rmSync(path.join(staged,command+'.json'));
 const item={file:'candidate.png',commandId:command,sha256:digest};
 assert.throws(()=>moduleUnderTest.associateManual(base,dir,item),/EDITOR_CONFIRMATION_REQUIRED/);
 assert.throws(()=>moduleUnderTest.associateManual(base,dir,{...item,confirmation:'CONFIRMO_ASOCIACION_MANUAL',sha256:'0'.repeat(64)}),/IMPORTED_PNG_HASH_CHANGED/);
 assert.throws(()=>moduleUnderTest.associateManual(base,dir,{...item,confirmation:'CONFIRMO_ASOCIACION_MANUAL',file:'../candidate.png'}),/BAD_IMPORT_NAME/);
 assert.equal(moduleUnderTest.readManualLinks(base).length,0);
});
test('local web monitor lists recent jobs and accepts only confirmed same-origin associations',async t=>{
 const base=makeFixture(t),dir=path.join(base,'imports');fs.mkdirSync(dir);
 const source=path.join(dir,'gag.png');fs.writeFileSync(source,png);
 const staged=path.join(base,'image-approval-receipts','immediate-originals');
 fs.rmSync(path.join(staged,command+'.png'));fs.rmSync(path.join(staged,command+'.json'));
 const server=moduleUnderTest.serve(base,{port:0,importDir:dir});
 t.after(()=>new Promise(resolve=>server.close(resolve)));
 if(!server.listening)await new Promise(resolve=>server.once('listening',resolve));
 const url='http://127.0.0.1:'+server.address().port;
 assert.equal((await fetch(url+'/api/status?since=2026-11-12').then(x=>x.json())).counts.total,0);
 assert.equal((await fetch(url+'/api/status?since=2026-11-10').then(x=>x.json())).counts.total,1);
 const body={file:'gag.png',commandId:command,sha256:digest,confirmation:'CONFIRMO_ASOCIACION_MANUAL'};
 const headers={'content-type':'application/json','x-tt-fotos-action':'manual-editor-confirmation-v1',Origin:url};
 assert.equal((await fetch(url+'/api/associate',{method:'POST',headers:{...headers,Origin:'https://evil.example'},body:JSON.stringify(body)})).status,403);
 assert.equal((await fetch(url+'/api/associate',{method:'POST',headers,body:JSON.stringify({...body,confirmation:'NO'})})).status,400);
 const response=await fetch(url+'/api/associate',{method:'POST',headers,body:JSON.stringify(body)});
 assert.equal(response.status,200);assert((await response.json()).ok);
 assert.equal((await fetch(url+'/api/manual-original/'+command)).status,200);
 assert.equal((await fetch(url+'/api/status?since=2026-11-10').then(x=>x.json())).counts.manualPending,1);
 // No invisible auto delivery; this endpoint requires an additional explicit click.
 assert.equal((await fetch(url+'/api/deliver-manual',{method:'POST',headers,body:JSON.stringify({commandId:command})})).status,400);
 assert.equal((await fetch(url+'/api/deliver-manual',{method:'POST',headers,body:JSON.stringify({commandId:command,confirmation:'CONFIRMO_ENTREGA_MANUAL'})})).status,400); // missing private receiver in fixture
 assert(!fs.existsSync(path.join(base,'image-approval-receipts',command+'.json')));
});
test('manual confirmed association can be delivered only through a second explicit step',async t=>{
 const base=makeFixture(t),dir=path.join(base,'imports');fs.mkdirSync(dir);
 fs.writeFileSync(path.join(dir,'foto-original.png'),png);
 const staged=path.join(base,'image-approval-receipts','immediate-originals');
 fs.rmSync(path.join(staged,command+'.png'));fs.rmSync(path.join(staged,command+'.json'));
 moduleUnderTest.associateManual(base,dir,{file:'foto-original.png',commandId:command,sha256:digest,confirmation:'CONFIRMO_ASOCIACION_MANUAL'});
 let sends=0;
 const meta={project:'ttittulares',editorialId:'123456789abc',revision:1,commandId:command,episodeFingerprint:'f'.repeat(64)};
 const sent={id:'b'.repeat(64),rasterSHA256:digest,state:'pending'};
 const fakeReceiver={editorialJob:async()=>({}),metadata:()=>meta};
 const receiptFile=path.join(base,'image-approval-receipts',command+'.json');
 const fakeInbox={
   saveReceipt:()=>fs.writeFileSync(receiptFile,JSON.stringify({project:'ttittulares',commandId:command,editorialId:'123456789abc',revision:1,...sent})),
   readReceipt:()=>JSON.parse(fs.readFileSync(receiptFile,'utf8'))};
 const result=await moduleUnderTest.deliverManual(base,command,{getReceiver:()=>fakeReceiver,getSource:()=>({}),getInbox:()=>fakeInbox,readSecret:()=>('x'.repeat(40)),send:async(given,bytes,secret)=>{
   sends++;assert.deepEqual(given,meta);assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'),digest);
   assert.equal(secret.length,40);return sent}});
 assert.equal(sends,1);assert.equal(result.result,'DELIVERED_pending');
 assert.equal(moduleUnderTest.inventory(base,{importDir:dir}).counts.received,1);
 await assert.rejects(()=>moduleUnderTest.deliverManual(base,command),/EXISTING_RECEIPT_REPLACEMENT_NOT_SUPPORTED/);
 assert.equal(sends,1);
 assert(fs.existsSync(path.join(base,'image-approval-receipts','manual-originals',digest+'.png')));
});
test('import preview accepts safe Unicode filename without escaping outside import directory',async t=>{
 const base=makeFixture(t),dir=path.join(base,'imports');fs.mkdirSync(dir);
 const file='Borrasca Bruna — viñeta.png';fs.writeFileSync(path.join(dir,file),png);
 const server=moduleUnderTest.serve(base,{port:0,importDir:dir});
 t.after(()=>new Promise(resolve=>server.close(resolve)));
 if(!server.listening)await new Promise(resolve=>server.once('listening',resolve));
 const url='http://127.0.0.1:'+server.address().port;
 assert.equal((await fetch(url+'/api/orphan/CARPETA_DESCARGAS/'+encodeURIComponent(file))).status,200);
 assert.equal((await fetch(url+'/api/orphan/CARPETA_DESCARGAS/'+encodeURIComponent('../'+file))).status,404);
});