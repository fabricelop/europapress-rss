const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),vm=require('node:vm'),crypto=require('node:crypto');
const source=fs.readFileSync(path.join(__dirname,'../TTImageApprovalReceiver.cjs'),'utf8');
for(const project of ['ttittulares','ttendencias'])test(project+' recovers exact closed conversation only in private relay and returns pending receipt',async()=>{
 const base=fs.mkdtempSync(path.join(os.tmpdir(),'tt-intake-test-'));
 try{
 const sha=x=>crypto.createHash('sha256').update(x).digest('hex'),news=project==='ttittulares',text='Texto exacto',at=new Date(Date.now()-3600000).toISOString();
 const task={project,target_id:'topic-abc',command_id:'job-abc',revision:1,status:'waiting',secret_dpapi:'encrypted',conversation_url:'https://chatgpt.com/c/exact',browser_target_id:'reused',created_at:at,explanation_sha256:sha(text),editorial_sha256:sha([text,'Hechos','Remate'].join('\n'))};
 fs.mkdirSync(path.join(base,project+'-web-images'));fs.writeFileSync(path.join(base,project+'-web-images/job.json'),JSON.stringify(task));
 for(const file of ['TTendenciasWebImages.cjs','TTiTTularesWebImages.cjs'])fs.writeFileSync(path.join(base,file),"return {status:'waiting',reason:'manual_approval_required'}");
 const job={target_id:task.target_id,command_id:task.command_id,revision:1,context_snapshot:news?{tweet_text:text,factual_summary:'Hechos',remate:'Remate',prepared_at:at}:{explanation:text,explained_at:at}};
 const chatURL=url=>url?.startsWith('https://chatgpt.com/c/')?url:null;
 const reader={chatURL,async readImageJob(){return job},async readEditorialState(){return {items:news?[{event_id:task.target_id,revision:1,prepared_at:at}]:[{id:task.target_id,revision:1,status:'explained',explanation:text,explained_at:at}]}},async discoverConversation(){return null},rasterProbe(){return 'read-exact-job'}};
 let created=0,closed=0,uploads=0;
 const bytes=Buffer.alloc(32);Buffer.from('89504e470d0a1a0a','hex').copy(bytes);
 const FakeCDP=class{async open(){}close(){}async call(method,args){if(method==='Target.createTarget'){assert.equal(args.url,task.conversation_url);assert.equal(args.background,true);created++;return {targetId:'owned'}}if(method==='Target.closeTarget'){closed++;return {}}throw Error('Unexpected CDP mutation '+method)}async evaluate(expression){assert.equal(expression,'read-exact-job');return {ready:true,dataUrl:'data:image/png;base64,'+bytes.toString('base64')}}};
 const start=source.indexOf('class CDP{'),end=source.indexOf('function unprotect(');
 const code=source.slice(0,start)+'const CDP=FakeCDP;\n'+source.slice(end);
 const sandbox={module:{exports:{}},require:n=>n==='node:child_process'?{execFileSync:()=> 'private-secret'}:n.endsWith('WebImages.cjs')?reader:require(n),process:{platform:'win32',pid:process.pid,kill:process.kill.bind(process)},__dirname:base,FakeCDP,Buffer,FormData,Blob,AbortSignal,Date,console:{log(){},error(){}},setTimeout,clearTimeout,fetch:async(url,opts)=>{
  if(url.includes('site-top30-current.json'))return Response.json({items:[{
   editorial_id:task.target_id,revision:task.revision,explanation:text}]});
  if(url.includes('decisions.json'))return Response.json({items:[]});
  if(url==='http://127.0.0.1:9234/json/version')return Response.json({webSocketDebuggerUrl:'ws://relay'});
  if(url.includes('/json/list'))return Response.json(created?[{id:'owned',type:'page',url:task.conversation_url,webSocketDebuggerUrl:'ws://owned'}]:[]);
  if(url.includes('/api/image-inbox/v1/images/ingest')){uploads++;assert.equal(opts.headers['X-TT-Ingest-Key'],'private-secret');assert.equal(JSON.parse(opts.body.get('metadata')).editorialId,task.target_id);return Response.json({id:'a'.repeat(64),state:'pending'})}
  throw Error('Unexpected URL '+url);
 }};
 vm.runInNewContext(code,sandbox);await sandbox.module.exports.once(base);
 assert.equal(created,1);assert.equal(closed,1);assert.equal(uploads,1);
 const receipt=JSON.parse(fs.readFileSync(path.join(base,'image-approval-receipts/job-abc.json'),'utf8'));assert.equal(receipt.state,'pending');assert.equal(receipt.editorialId,task.target_id);
 }finally{fs.rmSync(base,{recursive:true,force:true})}
});
