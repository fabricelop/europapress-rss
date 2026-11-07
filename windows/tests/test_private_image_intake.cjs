const {test}=require('node:test'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const {metadata,episode,send,ENDPOINT}=require('../TTImageApprovalReceiver.cjs');
const sha=x=>crypto.createHash('sha256').update(x).digest('hex');
test('receiver binds command, date, revision and text without generation or legacy association',()=>{const task={target_id:'trend-abc',command_id:'job-abc',revision:0,explanation_sha256:sha('Texto exacto')};const job={target_id:task.target_id,command_id:task.command_id,revision:0,context_snapshot:{explanation:'Texto exacto',explained_at:'2026-11-02T12:00:00Z',name:'Prueba'}};const meta=metadata(task,job);assert.equal(meta.episodeFingerprint,episode(meta));assert.notEqual(meta.episodeFingerprint,episode({...meta,editorialAt:'2026-11-03T12:00:00Z'}));assert.throws(()=>metadata(task,{...job,command_id:'job-otro'}));assert.throws(()=>metadata(task,{...job,context_snapshot:{...job.context_snapshot,explanation:'Otro'}}));});
test('only private original upload is possible; receipt preserves SHA and no approval request',async()=>{const bytes=Buffer.alloc(32);Buffer.from('89504e470d0a1a0a','hex').copy(bytes);let called=0;const result=await send({project:'ttendencias'},bytes,'private-secret',async(url,opts)=>{called++;assert.equal(url,ENDPOINT);assert.equal(opts.headers['X-TT-Ingest-Key'],'private-secret');assert.equal(opts.redirect,'error');const meta=JSON.parse(opts.body.get('metadata'));assert.equal(meta.rasterSHA256,sha(bytes));assert.equal(opts.body.get('image').size,bytes.length);return Response.json({id:'a'.repeat(64),state:'pending'},{status:201})});assert.equal(called,1);assert.equal(result.state,'pending');assert.equal(result.rasterSHA256,sha(bytes));await assert.rejects(send({},Buffer.from('invalid'),'secret',()=>{throw Error('must not call')}));});

test('reused browser target cannot override an exact original conversation URL',()=>{
 const {selectTarget}=require('../TTImageApprovalReceiver.cjs');
 const pages=[{type:'page',id:'fixed',url:'https://chatgpt.com/c/other',webSocketDebuggerUrl:'ws://other'},{type:'page',id:'original',url:'https://chatgpt.com/c/exact',webSocketDebuggerUrl:'ws://exact'}];
 const task={browser_target_id:'fixed',conversation_url:'https://chatgpt.com/c/exact'};
 const chatURL=x=>x?.startsWith('https://chatgpt.com/c/')?x:null;
 assert.equal(selectTarget(pages,task,chatURL).id,'original');
 assert.equal(selectTarget(pages.slice(0,1),task,chatURL),undefined);
 assert.equal(selectTarget(pages,{browser_target_id:'fixed'},chatURL).id,'fixed');
});
test('news receipt identity uses its own original text, date and fingerprint',()=>{
 const task={project:'ttittulares',target_id:'news-abc',command_id:'news-job',revision:1,editorial_sha256:sha(['Texto noticia','Hechos','Remate'].join('\n'))};
 const job={command_id:'news-job',event_id:'news-abc',revision:1,context_snapshot:{tweet_text:'Texto noticia',factual_summary:'Hechos',remate:'Remate',prepared_at:'2026-11-02T12:00:00Z'}};
 const m=metadata(task,job);assert.equal(m.project,'ttittulares');assert.equal(m.editorialId,'news-abc');assert.equal(m.editorialText,'Texto noticia');assert.throws(()=>metadata(task,{...job,revision:2}));
});
for(const [file,name,news] of [['TTendenciasImageBridge.js','holdForWebImageReceipt',false],['TTiTTularesImageBridge.js','holdForHeadlineOriginalReceipt',true]]){
 for(const valid of [true,false])test(file+' private hold accepts only exact revision '+valid,async()=>{
  const vm=require('node:vm'),fs=require('node:fs'),text=fs.readFileSync(require('node:path').join(__dirname,"..",file),'utf8');
  const match=text.match(new RegExp('async function '+name+'\\([^\\n]*\\)\\{[\\s\\S]*?\\n\\}'));assert.ok(match);
  let now=0,remembered=0;
  const hold=vm.runInNewContext('('+match[0]+')',{require:n=>n==='node:fs'?{readFileSync(p){assert.ok(p.includes('image-approval-receipts'));return JSON.stringify({commandId:'job-abc',editorialId:'trend-abc',revision:valid?1:2,rasterSHA256:'a'.repeat(64),id:'b'.repeat(64)})}}:require(n),__dirname,commandId:'job-abc',targetId:'trend-abc',Date:{now:()=>now},sleep:async ms=>{now+=ms},optionalWebHandoff:async()=>{remembered++;return true},console:{log(){}}});
  const result=news?await hold({}, {revision:1},5000):await hold({},null,{revision:1},5000);
  assert.equal(result,valid?'private_original_received':'private_original_pending');assert.ok(remembered>0);
 });
}
test('hundreds of obsolete never-checked jobs cannot starve an active card',()=>{
 const {selectCurrentTasks}=require('../TTImageApprovalReceiver.cjs');const old=Array.from({length:311},(_,i)=>({project:'ttendencias',target_id:'old-'+i,revision:0,command_id:'old-'+i,created_at:'2026-11-02T10:00:00Z'}));const live={project:'ttendencias',target_id:'live',revision:0,command_id:'live-job',created_at:'2026-11-02T22:00:00Z'};
 const selected=selectCurrentTasks([...old,live],{'live-job':{checkedAt:999999}},new Set(['ttendencias:live:0']));
 assert.equal(selected[0],live);
 assert.equal(selected.length,312); // All eligible; the caller filters obsolete IDs first.
 assert.equal(new Set(selected.map(x=>x.command_id)).size,312);
 assert.equal(old.length,311);
});
test('all eligible episodes are attempted without the old eight-item ceiling',()=>{
 const {selectCurrentTasks}=require('../TTImageApprovalReceiver.cjs');
 const current=Array.from({length:32},(_,i)=>({
  project:'ttendencias',target_id:'live-'+i,revision:0,
  command_id:'current-'+i,created_at:'2026-11-06T00:01:00Z'
 }));
 const historical=Array.from({length:17},(_,i)=>({
  project:'ttittulares',target_id:'still-ready-'+i,revision:1,
  command_id:'historical-'+i,created_at:'2026-10-25T10:01:00Z'
 }));
 const active=new Set(current.map(x=>'ttendencias:'+x.target_id+':0'));
 const selection=selectCurrentTasks([...current,...historical],{},active);
 assert.equal(selection.length,49);
 assert.equal(selection.filter(x=>x.command_id.startsWith('current-')).length,32);
 assert.equal(selection.filter(x=>x.command_id.startsWith('historical-')).length,17);
 assert.equal(new Set(selection.map(x=>x.command_id)).size,49);
 // Priority is an ordering choice, never a drop. A previous failure does
 // not remove an eligible command in the next receiver cycle.
 const progress=Object.fromEntries(selection.map(x=>[x.command_id,{checkedAt:Date.now()}]));
 const next=selectCurrentTasks([...current,...historical],progress,active);
 assert.equal(next.length,49);
 assert(next.some(x=>x.command_id==='historical-16'));
});

test('receiver retries only reading exact PNG while ChatGPT hydration or CDP is transient',()=>{
 const fs=require('node:fs'),path=require('node:path');
 const source=fs.readFileSync(path.join(__dirname,'..','TTImageApprovalReceiver.cjs'),'utf8');
 assert.match(source,/const maxProbes=ownedTarget\?12:7/);
 assert.match(source,/source\.rasterProbe\(task\.command_id,true\)/);
 assert.match(source,/CDP_EVALUATION_FAILED/);
 assert.match(source,/capture_requires_sign_in/);
 assert.match(source,/if\(raster\?\.ready/);
 assert.doesNotMatch(source,/Runtime\.navigate/);
 assert.doesNotMatch(source,/Input\.insertText/);
});

test('hidden Windows startup updater validates local hash, backs up, and never kills processes',()=>{
 const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
 const updater=fs.readFileSync(path.join(__dirname,'../Actualizar-Inicio-Oculto-TT.ps1'),'utf8');
 const watchdog=fs.readFileSync(path.join(__dirname,'../TT-LocalWatchdog.ps1'),'utf8');
 const canonical=watchdog.replace(/\r\n/g,'\n').replace(/\n/g,'\r\n');
 const hash=crypto.createHash('sha256').update(canonical,'utf8').digest('hex');
 assert.ok(updater.includes("$expected='"+hash+"'"));
 for(const marker of ['WATCHDOG_LOCAL_VERSION_UNKNOWN','WATCHDOG_REMOTE_SHA_INVALID',
     'WATCHDOG_PARSE_INVALID','WATCHDOG_CHANGED_DURING_INSTALL',
     'WATCHDOG_INSTALLED_SHA_INVALID','TTActualidad hidden startup v2',
     'Startup','Move-Item -LiteralPath $entry.cmd','[IO.File]::Replace(']){
  assert.ok(updater.includes(marker),marker);
 }
 assert.doesNotMatch(updater,/Stop-Process|Stop-ScheduledTask|taskkill|Enable-ScheduledTask|Start-ScheduledTask/);
 assert.match(updater,/if\(\$PreflightOnly\)/);
 assert.match(updater,/script personalizado/);
});

test('relay Chrome recovery is bounded and fails closed after uncertain cleanup',()=>{
 const source=require('node:fs').readFileSync(
  require('node:path').join(__dirname,'../TTImageApprovalReceiver.cjs'),'utf8');
 assert.match(source,/MAX_NEW_RELAY_TABS_PER_CYCLE=1/);
 assert.match(source,/MAX_RELAY_PAGE_TARGETS=6/);
 assert.match(source,/RELAY_RETRY_COOLDOWN_MS=15\*60\*1000/);
 assert.match(source,/newlyOpened>=MAX_NEW_RELAY_TABS_PER_CYCLE/);
 assert.match(source,/pages\.filter\(p=>p\.type==='page'\)\.length>=MAX_RELAY_PAGE_TARGETS/);
 assert.match(source,/relay-cleanup-unconfirmed\.json/);
 assert.match(source,/Target\.closeTarget/);
 assert.match(source,/json\/close/);
 assert.match(source,/RELAY_CLEANUP_UNCONFIRMED/);
 assert.match(source,/RELAY_TAB_BUDGET/);
 assert.match(source,/RELAY_RETRY_COOLDOWN/);
 assert.match(source,/RELAY_OPEN_FAILED/);
});
test('watchdog keeps known hidden startup and does not re-create visible CMD',()=>{
 const source=require('node:fs').readFileSync(
  require('node:path').join(__dirname,'../TT-LocalWatchdog.ps1'),'utf8');
 const section=source.slice(source.indexOf('function EnsureStartup('),source.indexOf('function EnsureChrome{'));
 assert.match(section,/ChangeExtension\(\$Name,'\.vbs'\)/);
 assert.match(section,/TTActualidad hidden startup v2/);
 assert.match(section,/STARTUP CUSTOM CMD PRESERVED/);
 assert.match(section,/STARTUP CUSTOM VBS PRESERVED/);
 assert.match(section,/Move-Item -LiteralPath \$legacy -Destination \$disabled/);
 assert.doesNotMatch(section,/Set-Content -LiteralPath \$path/);
});

test('a retained original stays eligible after 72 hours in both capture watchers',()=>{
 const fs=require('node:fs'),path=require('node:path');
 const now=Date.parse('2026-11-07T14:40:00Z');
 for(const [name,mod] of [
  ['TTendenciasWebImages.cjs',require('../TTendenciasWebImages.cjs')],
  ['TTiTTularesWebImages.cjs',require('../TTiTTularesWebImages.cjs')]]) {
  const original={file:'original.json',task:{target_id:'valid-id',command_id:'cmd-exact',
   status:'waiting',created_at:'2026-10-20T09:00:00Z'}};
  assert.equal(mod.dueTasks([original],now).length,1,name+' must not drop original by age');
  const src=fs.readFileSync(path.join(__dirname,'..',name),'utf8');
  assert.doesNotMatch(src,/status:'expired',reason:'image_not_confirmed_within_72h'/);
  assert.doesNotMatch(src,/status:'needs_review',reason:'original_not_associated_within_72h'/);
 }
});

test('current index excludes closed news and old episodes while retaining exact live revisions',()=>{
 const {activeIdentities}=require('../TTImageApprovalReceiver.cjs');const now=Date.parse('2026-11-03T00:00:00Z');const doc={items:[{id:'live',revision:1,status:'explained',explanation:'Actual',explained_at:'2026-11-02T22:00:00Z'},{id:'old',revision:0,status:'explained',explanation:'Antiguo',explained_at:'2026-10-30T10:00:00Z'}]};assert.deepEqual([...activeIdentities('ttendencias',doc,{items:[]},now)],['ttendencias:live:1']);assert.equal(activeIdentities('ttittulares',{items:[{event_id:'news',revision:1,prepared_at:'2026-11-02T22:00:00Z'}]},{items:[{event_id:'news',status:'published',revision:1}]},now).size,0);
});

test('isolated installer accepts only pinned prior manual-approval bridge versions',()=>{
 const fs=require('node:fs'),path=require('node:path');
 const script=fs.readFileSync(path.join(__dirname,'../Actualizar-Solo-Receptor-Imagenes-TT.ps1'),'utf8');
 const expected={
   TTendencias:[
    '2b20c5ea4075a75b99014b47a60c68b59f3c7499c8fadcd54749d9d640dcf862',
    '190384d1ef7370495b8b33eba6f5b1d132f9e5945c6fff5e2432a3fb72860cab',
    'd8b6e66006d63d478e641ffe8fe1040fad3bec538791147bf40499826a7443bb',
    '3032a4813547cd1cde963a67c28700f0befb5054f5bf4e8e371a42634f9bd8b8',
    '4f2f00db3aa3794e1c293201fc9f32e6f6dcd4cacc27c7742da0db93d9292e3f'],
   TTiTTulares:[
    'da12b28af6e2f667515b851bb44f609148078a2c72d3f9ed9ecf077f19854b80',
    '2bf584a4f266d1ed8c4781b81c27a5e47379c2c94e6802ad51902a99c48c287e',
    '6f1e5e9b390ab04ce068683b2d61535bda441550f419e4c04dc8896d1dabfb19',
    'b163d1a60ceefe75205b81a9e10c002805e3c8bfc52e175068fb080bae22c3ea',
    '7b7bc8d6e4e9a84e47714528df3cbe19e1feae7b11286712dd76d587396f707b']
 };
 for(const list of Object.values(expected))for(const hash of list){
  assert.ok(script.includes("'"+hash+"'"),hash);
 }
 assert.match(script,/\$dependencyHash=Get-CanonicalSourceHash \$dependency/);
 assert.match(script,/if\(\$entry\.Value -notcontains \$dependencyHash\)/);
 assert.match(script,/RECEIVER_DEPENDENCY_UNKNOWN:/);
 assert.match(script,/canonicalSHA256=/);
 assert.match(script,/RECEIVER_DEPENDENCY_EXPORT_MISSING/);
 assert.match(script,/RECEIVER_APPROVAL_PAUSE_MISSING/);
 assert.doesNotMatch(script,/RECEIVER_DEPENDENCY_UNKNOWN:[^\n]*Write-Host/);
});
test('isolated receiver installer updates only exact pinned CJS without disrupting generators',()=>{
 const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
 const script=fs.readFileSync(path.join(__dirname,'../Actualizar-Solo-Receptor-Imagenes-TT.ps1'),'utf8');
 const receiver=fs.readFileSync(path.join(__dirname,'../TTImageApprovalReceiver.cjs'),'utf8');
 const canonical=receiver.replace(/\r\n/g,'\n').replace(/\n/g,'\r\n');
 const sha=crypto.createHash('sha256').update(canonical,'utf8').digest('hex');
 assert.ok(script.includes("$expected='"+sha+"'"),'sha target bound to receiver source');
 for(const marker of ['RECEIVER_UNKNOWN_SHA','RECEIVER_DEPENDENCY_UNKNOWN',
  'RECEIVER_APPROVAL_PAUSE_MISSING','RECEIVER_HIDDEN_TASK_REQUIRED',
  'RECEIVER_DOWNLOAD_SHA_INVALID','RECEIVER_JS_SYNTAX_INVALID',
  'RECEIVER_CHANGED_DURING_STAGE','RECEIVER_REPLACEMENT_SHA_INVALID',
  'MAX_NEW_RELAY_TABS_PER_CYCLE=1','RELAY_CLEANUP_UNCONFIRMED',
  '[IO.File]::Replace($stage,$live','receiver-only-backup-']){
  assert.ok(script.includes(marker),marker);
 }
 assert.doesNotMatch(script,/Wait-ForGeneratorsIdle|Assert-GeneratorsIdle|Stop-Process|Stop-ScheduledTask|taskkill|Enable-ScheduledTask|Start-ScheduledTask/);
 assert.match(script,/\$before=Get-CanonicalSourceHash \$live/);
 assert.match(script,/if\(\$accepted -notcontains \$before\)/);
});

test('installer waits for uninterrupted generator quiet before replacement',()=>{
 const fs=require('node:fs'),path=require('node:path');
 const script=fs.readFileSync(path.join(__dirname,'../Actualizar-Recogida-Privada-TT.ps1'),'utf8');
 const start=script.indexOf('function Wait-ForGeneratorsIdle(');
 const end=script.indexOf('if(-not(Test-Path -LiteralPath $base',start);
 const fn=script.slice(start,end);
 assert.ok(start>0 && end>start);
 assert.match(fn,/\$quietSeconds=20/);
 assert.match(fn,/\$quietSince=\$null/);
 assert.match(fn,/if\(\$busy\.Count\)\{\s*\$quietSince=\$null/);
 assert.match(fn,/if\(\(\$now-\$quietSince\)\.TotalSeconds -ge \$quietSeconds\)\{return\}/);
 assert.match(fn,/Start-Sleep -Seconds 2/);
 assert.doesNotMatch(fn,/if\(-not \$busy\.Count\)\{return\}/);
 assert.match(script,/Wait-ForGeneratorsIdle \$MaxWaitSeconds\s+Assert-GeneratorsIdle/);
 assert.match(script,/\[IO.File\]::Replace\(\$stage,\$live/);
 assert.match(script,/foreach\(\$name in \$written\)/);
});
test('installer SHA pins accept only checked-in UTF-8 content with equivalent line endings',()=>{
 const crypto=require('node:crypto'),fs=require('node:fs'),path=require('node:path');
 const script=fs.readFileSync(path.join(__dirname,'..','Actualizar-Recogida-Privada-TT.ps1'),'utf8');
 assert.match(script,/function Get-CanonicalSourceHash/);
 assert.match(script,/Get-CanonicalSourceHash \$destination/);
 assert.match(script,/Get-CanonicalSourceHash \$stage/);
 assert.match(script,/Get-CanonicalSourceHash \$live/);
 for(const name of ['TTImageApprovalReceiver.cjs','TTendenciasWebImages.cjs','TTiTTularesWebImages.cjs']){
  const source=fs.readFileSync(path.join(__dirname,'..',name),'utf8');
  const canonical=source.replace(/\r\n/g,'\n').replace(/\n/g,'\r\n');
  const hash=crypto.createHash('sha256').update(canonical,'utf8').digest('hex');
  assert.ok(script.includes("'"+name+"'='"+hash+"'"),name+' SHA mismatch');
  const utf8lf=Buffer.from(source.replace(/\r\n/g,'\n'),'utf8');
  assert.equal(crypto.createHash('sha256').update(utf8lf).digest('hex').length,64);
 }
});

test('installer can replace a running inbox receiver atomically without stopping it or disabling tasks',()=>{
 const fs=require('node:fs'),path=require('node:path');
 const text=fs.readFileSync(path.join(__dirname,'..','Actualizar-Recogida-Privada-TT.ps1'),'utf8');
 assert.match(text,/function Wait-ForGeneratorsIdle/);
 assert.match(text,/function Get-BusyGenerators/);
 assert.match(text,/\[IO\.File\]::Replace\(\$stage,\$live,/);
 assert.match(text,/\[IO\.File\]::Replace\(\$restore,\$live,/);
 assert.match(text,/Get-FileHash -LiteralPath \$live/);
 assert.match(text,/MaxWaitSeconds=900/);
 assert.doesNotMatch(text,/Disable-ScheduledTask|Stop-Process|Stop-ScheduledTask|taskkill/i);
 const guard=text.slice(text.indexOf('function Get-BusyGenerators'),text.indexOf('function Assert-GeneratorsIdle'));
 assert.match(guard,/ImageBridge/);
 assert.doesNotMatch(guard,/ImageApprovalReceiver/);
});
