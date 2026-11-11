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
