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
 const selected=selectCurrentTasks([...old,live],{'live-job':{checkedAt:999999}},new Set(['ttendencias:live:0']));assert.equal(selected[0],live);assert.equal(selected.length,312);assert.equal(old.length,311);
});
test('all current approvals can be processed in one cycle without an eight-job cap',()=>{
 const {selectCurrentTasks}=require('../TTImageApprovalReceiver.cjs');
 const current=Array.from({length:49},(_,i)=>({
  project:'ttendencias',target_id:'live-'+i,revision:0,
  command_id:'current-'+i,created_at:'2026-11-08T19:00:00Z'
 }));
 const active=new Set(current.map(x=>'ttendencias:'+x.target_id+':0'));
 const selection=selectCurrentTasks(current,{},active);
 assert.equal(selection.length,49);
 assert.equal(new Set(selection.map(x=>x.command_id)).size,49);
 assert.ok(selection.every(x=>active.has('ttendencias:'+x.target_id+':0')));
});

test('current index excludes closed news and old episodes while retaining exact live revisions',()=>{
 const {activeIdentities}=require('../TTImageApprovalReceiver.cjs');const now=Date.parse('2026-11-03T00:00:00Z');const doc={items:[{id:'live',revision:1,status:'explained',explanation:'Actual',explained_at:'2026-11-02T22:00:00Z'},{id:'old',revision:0,status:'explained',explanation:'Antiguo',explained_at:'2026-10-30T10:00:00Z'}]};assert.deepEqual([...activeIdentities('ttendencias',doc,{items:[]},now)],['ttendencias:live:1']);assert.equal(activeIdentities('ttittulares',{items:[{event_id:'news',revision:1,prepared_at:'2026-11-02T22:00:00Z'}]},{items:[{event_id:'news',status:'published',revision:1}]},now).size,0);
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
