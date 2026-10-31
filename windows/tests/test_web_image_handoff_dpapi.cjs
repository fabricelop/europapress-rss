'use strict';
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),assert=require('node:assert/strict');
(async()=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'tt-durable-web-'));
 try{
  fs.copyFileSync(path.join(__dirname,'../TTendenciasWebImages.cjs'),path.join(root,'helper.cjs'));
  const helper=require(path.join(root,'helper.cjs'));
  const job={target_id:'trend-test',command_id:'cmd-pending',revision:0,context_snapshot:{explanation:'Texto exacto'}};
  const input={startPublisher:false,job,targetId:job.target_id,commandId:job.command_id,browserTargetId:'own-pinned-target',secret:'private-test-'+require('node:crypto').randomBytes(32).toString('hex')};
  helper.enroll(input);
  const file=path.join(root,'ttendencias-web-images/cmd-pending.json');
  const pending=JSON.parse(fs.readFileSync(file,'utf8'));
  assert.equal(pending.conversation_url,null);assert.equal(pending.status,'waiting');assert.ok(pending.secret_dpapi);assert.ok(!fs.readFileSync(file,'utf8').includes(input.secret));
  const original=global.fetch,originalWS=global.WebSocket;let proven=false;
  global.fetch=async url=>{assert.equal(url,'http://127.0.0.1:9223/json/list');return {ok:true,json:async()=>[{id:'foreign',url:'https://chatgpt.com/c/fff'},{id:input.browserTargetId,url:'https://chatgpt.com/c/abc-123',webSocketDebuggerUrl:'ws://own-target'}]};};
  global.WebSocket=class {
   constructor(url){assert.equal(url,'ws://own-target');this.handlers={};queueMicrotask(()=>this.handlers.open());}
   addEventListener(name,fn){this.handlers[name]=fn;}
   send(text){const m=JSON.parse(text);assert.equal(m.method,'Runtime.evaluate');assert.ok(m.params.expression.includes(input.commandId));queueMicrotask(()=>this.handlers.message({data:JSON.stringify({id:m.id,result:{result:{value:proven?'https://chatgpt.com/c/abc-123':null}}})}));}
   close(){}
  };
  try{
   assert.equal(await helper.rememberConversation(input),false);
   assert.equal(JSON.parse(fs.readFileSync(file,'utf8')).conversation_url,null,'stale pinned URL is not enrolled');
   proven=true;assert.equal(await helper.rememberConversation(input),true);
  }finally{global.fetch=original;global.WebSocket=originalWS;}
  const linked=JSON.parse(fs.readFileSync(file,'utf8'));
  assert.equal(linked.conversation_url,'https://chatgpt.com/c/abc-123');assert.equal(linked.secret_dpapi,pending.secret_dpapi);
  helper.enroll({...input,conversationUrl:'https://chatgpt.com/c/fff'});
  assert.equal(JSON.parse(fs.readFileSync(file,'utf8')).conversation_url,linked.conversation_url,'immutable once identified');
  console.log('PASS durable pre-send encrypted handoff and exact-target URL discovery');
 }finally{fs.rmSync(root,{recursive:true,force:true});}
})().catch(e=>{console.error(e);process.exitCode=1});
