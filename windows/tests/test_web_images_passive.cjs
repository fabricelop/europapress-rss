'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),crypto=require('node:crypto');
const source=fs.readFileSync('windows/TTendenciasWebImages.cjs','utf8');
const TEXT='TT#5 Contexto factual de esta tendencia.',COMMAND='command-passive-123',URL='https://chatgpt.com/c/abc-123';
const hash=crypto.createHash('sha256').update(TEXT).digest('hex');
async function run({existing=true,matching=true,replaced=false}={}){
 const methods=[],uploads=[];
 const job={target_id:'trend-passive',command_id:COMMAND,revision:0,status:'LAUNCHED',context_snapshot:{explanation:TEXT}};
 const task={target_id:job.target_id,command_id:COMMAND,revision:0,explanation_sha256:hash,conversation_url:replaced?null:URL,browser_target_id:'former-generator-target',secret_dpapi:'encrypted-test-secret'};
 const page={id:'existing-generator-target',type:'page',url:URL,webSocketDebuggerUrl:'ws://existing-generator-target'};
 const fetch=async(url,options={})=>{
  url=String(url);
  if(url.includes(':9234'))throw Error('relay offline');
  let doc;
  if(url.includes('image-runs/jobs/'))doc=job;
  else if(url.includes('web-image-contract'))doc={web_image_receipt:2};
  else if(url.endsWith('/json/version'))doc={webSocketDebuggerUrl:'ws://generator-browser'};
  else if(url.endsWith('/json/list'))doc=existing?[page]:[{...page,url:'https://chatgpt.com/c/other'}];
  else if(url.includes('telegram-manual-explained'))doc={items:[{id:job.target_id,revision:0,explanation:TEXT}]};
  else if(url.endsWith('/api/ttendencias-run')){uploads.push(JSON.parse(options.body));doc={status:'DONE',sha256:'a'.repeat(64),image_path:'trends/generated-images/trend-passive.png'};}
  else throw Error('unexpected HTTP '+url);
  return {ok:true,status:200,json:async()=>doc};
 };
 class WebSocket {
  constructor(url){assert.equal(url,'ws://existing-generator-target','must not attach to browser or another tab');this.handlers={};queueMicrotask(()=>this.handlers.open());}
  addEventListener(name,fn){this.handlers[name]=fn;}
  send(text){const request=JSON.parse(text);methods.push(request.method);assert.equal(request.method,'Runtime.evaluate');
   const value=request.params.expression.includes('const matched=')?
    {url:matching?URL:null,reason:matching?'matched':'last_user_command_differs'}:
    matching?{ready:true,dataUrl:'data:image/png;base64,TEST',width:1536,height:864}:{ready:false,reason:'command_not_in_conversation'};
   queueMicrotask(()=>this.handlers.message({data:JSON.stringify({id:request.id,result:{result:{value}}})}));
  }
  close(){}
 }
 const module={exports:{}};
 vm.runInNewContext(source,{module,exports:module.exports,__dirname:'/unused-test',require:Object.assign(name=>name==='node:child_process'?{execFileSync:()=> 'decrypted-test-secret'}:
  name==='node:fs'&&replaced?{...fs,readFileSync:(file,...args)=>String(file).endsWith('ttendencias-image-tab.json')?JSON.stringify({target_id:page.id}):fs.readFileSync(file,...args)}:require(name),{main:null}),
  process:{platform:'win32'},fetch,WebSocket,AbortSignal,URL:global.URL,console,
  setTimeout:(fn,ms)=>setTimeout(fn,Math.min(ms,10)),clearTimeout});
 const result=await module.exports.consume(task);
 return {result,methods,uploads};
}
test('without relay or an existing exact conversation, waits without creating/navigating any generator tab',async()=>{
 const {result,methods,uploads}=await run({existing:false});
 assert.equal(result.reason,'awaiting_relay_or_existing_conversation');assert.deepEqual(methods,[]);assert.equal(uploads.length,0);
});
test('existing generator conversation is inspected read-only and its original raster is uploaded with exact identity',async()=>{
 const {result,methods,uploads}=await run();
 assert.equal(result.reason,'upload_accepted_awaiting_main_confirmation');
 assert.deepEqual(methods,['Runtime.evaluate']);assert.equal(uploads.length,1);
 assert.equal(uploads[0].task,'web_image_upload');assert.equal(uploads[0].command_id,COMMAND);assert.equal(uploads[0].context_explanation_sha256,hash);
});
test('a reused generator tab with a different command never uploads or navigates',async()=>{
 const {result,methods,uploads}=await run({matching:false});
 assert.equal(result.reason,'command_not_in_conversation');assert.deepEqual(methods,['Runtime.evaluate']);assert.equal(uploads.length,0);
});
test('after producer replaces its pinned target, delivery finds only that owned replacement and proves the exact command before upload',async()=>{
 const {result,methods,uploads}=await run({replaced:true});
 assert.equal(result.reason,'upload_accepted_awaiting_main_confirmation');
 assert.deepEqual(methods,['Runtime.evaluate','Runtime.evaluate']);assert.equal(uploads.length,1);
 assert.equal(uploads[0].command_id,COMMAND);
 const wrong=await run({replaced:true,matching:false});
 assert.equal(wrong.result.reason,'awaiting_command_conversation:last_user_command_differs');assert.equal(wrong.uploads.length,0);
});
