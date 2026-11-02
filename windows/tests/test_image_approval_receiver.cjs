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
