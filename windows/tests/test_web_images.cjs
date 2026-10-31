'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),crypto=require('node:crypto'),vm=require('node:vm');
const {chatURL,sameContext,rasterProbe,conversationProbe,prioritizeOpenConversation}=require('../TTendenciasWebImages.cjs');
test('Only durable ChatGPT conversations are enrolled',()=>{
 assert.equal(chatURL('https://chatgpt.com/c/abc-123?x=1'),'https://chatgpt.com/c/abc-123');
 for(const url of ['https://chatgpt.com/','https://chatgpt.com/images','https://evil.example/c/abc','http://chatgpt.com/c/abc'])assert.equal(chatURL(url),null);
});
test('Target, command, revision and exact explanation must all match',()=>{
 const job={target_id:'tt-123',command_id:'cmd-123',revision:0,context_snapshot:{explanation:'Texto exacto'}};
 const task={target_id:'tt-123',command_id:'cmd-123',revision:0,explanation_sha256:crypto.createHash('sha256').update('Texto exacto').digest('hex')};
 assert.ok(sameContext(task,job));
 for(const changed of [{target_id:'other'},{command_id:'other'},{revision:1},{context_snapshot:{explanation:'Texto nuevo'}}])assert.equal(sameContext(task,{...job,...changed}),false);
});
async function probe({later=false,extra=false,old=false,generating=false}={}){
 const user={innerText:'TTENDENCIAS_IMAGE_JOB_V4 cmd-123 tt-123',compareDocumentPosition:img=>img.old?2:4};
 const image={complete:true,naturalWidth:1536,naturalHeight:1024,currentSrc:'https://asset.example/image.png',alt:'',old};
 let downloads=0;
 const document={querySelectorAll:s=>s.includes('user')?[user,...(later?[{innerText:'another command'}]:[])]:[image,...(extra?[{...image}]:[])],querySelector:()=>generating?{}:null};
 const context={document,Node:{DOCUMENT_POSITION_FOLLOWING:4},Uint8Array,btoa:s=>Buffer.from(s,'binary').toString('base64'),fetch:async()=>{downloads++;return {ok:true,blob:async()=>({type:'image/png',size:15000,arrayBuffer:async()=>new Uint8Array(15000).buffer})};}};
 const result=await vm.runInNewContext(rasterProbe('cmd-123'),context);
 return {result,downloads};
}
test('Reads original raster only after exact last command; ambiguous, older and unfinished images are ignored',async()=>{
 const good=await probe();assert.ok(good.result.ready);assert.equal(good.downloads,1);assert.match(good.result.dataUrl,/^data:image\/png;base64,/);
 for(const input of [{later:true},{extra:true},{old:true},{generating:true}]){const blocked=await probe(input);assert.equal(blocked.result.ready,false);assert.equal(blocked.downloads,0);}
});
test('URL discovery requires this command in the last user turn, not merely the pinned tab URL',()=>{
 const url='https://chatgpt.com/c/abc-123';
 for(const [texts,expected] of [[[],null],[['old command'],null],[['cmd-123','later command'],null],[['old','TTENDENCIAS_IMAGE_JOB_V4 cmd-123 trend-123'],url]]){
  const document={querySelectorAll:()=>texts.map(innerText=>({innerText}))};
  assert.equal(vm.runInNewContext(conversationProbe('cmd-123'),{document,location:{href:url}}),expected);
 }
});
test('the currently open image has priority without starving the remaining fair queue',()=>{
 const old={task:{conversation_url:'https://chatgpt.com/c/old-1'}},fresh={task:{conversation_url:'https://chatgpt.com/c/abc-123'}},other={task:{conversation_url:'https://chatgpt.com/c/old-2'}};
 assert.deepEqual(prioritizeOpenConversation([old,fresh,other],[{type:'page',url:fresh.task.conversation_url}]),[fresh,old,other]);
});
test('newly enrolled command keeps the retained tab window even before its URL is recorded',()=>{
 const old=Array.from({length:40},(_,i)=>({task:{command_id:'old-'+i,conversation_url:null,browser_target_id:'closed-'+i}}));
 const urda={task:{command_id:'urda-command',conversation_url:null,browser_target_id:'pinned-live'}};
 const queue=prioritizeOpenConversation([...old,urda],[{id:'pinned-live',type:'page',url:'https://chatgpt.com/'}]);
 assert.equal(queue[0],urda);
 assert.deepEqual(queue.slice(1),old);
 // A similarly named title or a different browser target is never identity.
 assert.equal(prioritizeOpenConversation([...old,urda],[{id:'other',type:'page',title:'Urda',url:'https://chatgpt.com/'}])[0],old[0]);
});
