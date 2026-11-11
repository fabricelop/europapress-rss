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

test('existing receiver lock does not stop recovery audit and delivery stays disabled',async t=>{
 const base=makeFixture(t),root=path.join(base,'image-approval-receipts');
 const lock=path.join(root,'receiver.lock');
 fs.writeFileSync(lock,JSON.stringify({pid:process.pid,at:Date.now()}));
 await assert.rejects(()=>moduleUnderTest.deliver(base),/INBOX_DELIVERY_DISABLED_FOR_MONITOR/);
 assert(fs.existsSync(lock),'foreign lock must survive');
 assert.equal(moduleUnderTest.inventory(base).counts.received,0);
});
test('missing dependency does not create lock or erase originals',async t=>{
 const base=makeFixture(t),lock=path.join(base,'image-approval-receipts','receiver.lock');
 await assert.rejects(()=>moduleUnderTest.deliver(base),/INBOX_DELIVERY_DISABLED_FOR_MONITOR/);
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
test('manual association overrides local preview only and retains original PNG',t=>{
 const base=makeFixture(t),dir=path.join(base,'imports');fs.mkdirSync(dir);
 const name='Descarga-Captura.png';fs.writeFileSync(path.join(dir,name),png);
 const receipt=path.join(base,'image-approval-receipts',command+'.json');
 fs.writeFileSync(receipt,JSON.stringify({commandId:command,editorialId:'123456789abc',project:'ttittulares',revision:1,rasterSHA256:digest,id:'b'.repeat(64),state:'pending'}));
 const before=fs.readFileSync(receipt);
 const stored=path.join(base,'image-approval-receipts','immediate-originals',command+'.png');
 const link=moduleUnderTest.associateManual(base,dir,{file:name,commandId:command,sha256:digest,confirmation:'CONFIRMO_ASOCIACION_MANUAL'});
 assert.equal(link.editorialId,'123456789abc');assert.equal(link.sha256,digest);
 assert.equal(link.provenance,'editor_manual_selection_from_download');
 const doc=moduleUnderTest.inventory(base,{importDir:dir});
 assert.equal(doc.counts.manualAssociated,1);
 assert.equal(doc.jobs[0].phase,'ASOCIADA_EN_MONITOR');
 assert.equal(doc.orphans[0].phase,'ASOCIADA_MANUAL');
 assert.equal(moduleUnderTest.readManualLinks(base).length,1);
 assert.equal(moduleUnderTest.associateManual(base,dir,{file:name,commandId:command,sha256:digest,confirmation:'CONFIRMO_ASOCIACION_MANUAL'}).sha256,digest);
 assert(fs.existsSync(path.join(base,'image-approval-receipts','manual-originals',digest+'.png')));
 assert(fs.readFileSync(receipt).equals(before),'no change to inbox receipts');
 assert(fs.existsSync(stored),'do not remove original cache');
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
 assert.equal((await fetch(url+'/api/status?since=2026-11-10').then(x=>x.json())).counts.manualAssociated,1);
 // Monitor has NO delivery route at all, even with confirmed legacy payload.
 assert.equal((await fetch(url+'/api/deliver-manual',{method:'POST',headers,body:JSON.stringify({commandId:command,confirmation:'CONFIRMO_ENTREGA_MANUAL'})})).status,405);
 assert(!fs.existsSync(path.join(base,'image-approval-receipts',command+'.json')));
});
test('last manual selection changes local card while preserving history and both PNGs',async t=>{
 const base=makeFixture(t),dir=path.join(base,'imports');fs.mkdirSync(dir);
 fs.writeFileSync(path.join(dir,'foto-a.png'),png);
 const other=Buffer.concat([Buffer.from('89504e470d0a1a0a','hex'),Buffer.alloc(50,9)]);
 const otherSha=crypto.createHash('sha256').update(other).digest('hex');
 fs.writeFileSync(path.join(dir,'foto-b.png'),other);
 const a=moduleUnderTest.associateManual(base,dir,{file:'foto-a.png',commandId:command,sha256:digest,confirmation:'CONFIRMO_ASOCIACION_MANUAL'});
 const b=moduleUnderTest.associateManual(base,dir,{file:'foto-b.png',commandId:command,sha256:otherSha,confirmation:'CONFIRMO_ASOCIACION_MANUAL'});
 assert.equal(a.sha256,digest);assert.equal(b.sha256,otherSha);
 assert.equal(moduleUnderTest.inventory(base,{importDir:dir}).jobs[0].manualAssociation.sha256,otherSha);
 assert(fs.existsSync(path.join(base,'image-approval-receipts','manual-originals',digest+'.png')));
 assert(fs.existsSync(path.join(base,'image-approval-receipts','manual-originals',otherSha+'.png')));
 const ledger=JSON.parse(fs.readFileSync(path.join(base,'image-approval-receipts','tt-fotos-manual-links.json')));
 assert.equal(ledger.items.length,1);assert.equal(ledger.history.length,2);
 assert.equal(ledger.history[1].previousSha256,digest);
 await assert.rejects(()=>moduleUnderTest.deliverManual(base,command),/INBOX_DELIVERY_DISABLED_FOR_MONITOR/);
 await assert.rejects(()=>moduleUnderTest.deliver(base),/INBOX_DELIVERY_DISABLED_FOR_MONITOR/);
 assert(!fs.existsSync(path.join(base,'image-approval-receipts',command+'.json')));
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

test('occupied default panel port automatically falls back without terminating existing listener',async t=>{
 const base=makeFixture(t),first=moduleUnderTest.serve(base,{port:0});
 t.after(()=>new Promise(resolve=>first.close(resolve)));
 if(!first.listening)await new Promise(resolve=>first.once('listening',resolve));
 const occupied=first.address().port;
 const second=moduleUnderTest.serve(base,{port:occupied});
 t.after(()=>new Promise(resolve=>second.close(resolve)));
 if(!second.listening)await new Promise(resolve=>second.once('listening',resolve));
 assert.equal(second.address().port,occupied+1);
 assert.equal((await fetch('http://127.0.0.1:'+occupied+'/api/status')).status,200);
 assert.equal((await fetch('http://127.0.0.1:'+second.address().port+'/api/status')).status,200);
});
test('CLI rescue never invokes deliver even if previous CLI used to',t=>{
 const source=fs.readFileSync(path.join(__dirname,'TTFotosRescate.cjs'),'utf8');
 const start=source.indexOf("if(args.includes('--rescue')){");
 const end=source.indexOf("}else if(args.includes('--capture'))",start);
 assert(start>=0&&end>start);
 assert(!source.slice(start,end).includes('await deliver('));
 assert(source.slice(start,end).includes('LOCAL_CAPTURE_ONLY_NO_IPHONE_DELIVERY'));
});