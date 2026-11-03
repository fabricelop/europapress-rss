const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),vm=require('node:vm');
for(const [file,prefix] of [['TTendenciasWebImages.cjs','TTENDENCIAS'],['TTiTTularesWebImages.cjs','TTITTULARES']]){
 const source=fs.readFileSync(__dirname+'/../'+file,'utf8');
 const section=source.slice(source.indexOf('function userTurns()'),source.indexOf('function sameContext('));
 const rasterProbe=vm.runInNewContext(section+';rasterProbe');
 const run=async({legacy=false,later=false,ambiguous=false,wrong=false}={})=>{
  const user={innerText:prefix+'_IMAGE_JOB_V4 '+(wrong?'wrong':'job-exact')+' record',contains:x=>false,compareDocumentPosition:x=>x.order>1?4:2};
  const next={innerText:'Another user request',contains:x=>false,compareDocumentPosition:x=>x.order>3?4:2};
  const image=order=>({order,complete:true,naturalWidth:1536,naturalHeight:1024,alt:'Generated illustration',src:'original',compareDocumentPosition:x=>x===next&&order<3?4:2});
  const images=[image(2),...(ambiguous?[image(2.5)]:[]),...(later?[image(4)]:[])];
  const document={querySelector:()=>null,querySelectorAll:s=>s==='img'?images:((legacy&&s.includes('data-message-author-role'))||(!legacy&&s.includes('[data-user-message-bubble="true"]'))?[user,...(later?[next]:[])]:[])};
  let fetched=0;const value=await vm.runInNewContext(rasterProbe('job-exact'),{document,Node:{DOCUMENT_POSITION_FOLLOWING:4},Uint8Array,btoa:s=>Buffer.from(s,'binary').toString('base64'),fetch:async()=>{fetched++;return{ok:true,blob:async()=>({type:'image/png',size:12000,arrayBuffer:async()=>new ArrayBuffer(12000)})}}});return{value,fetched};
 };
 test(file+' accepts observed user bubble and original',async()=>assert.equal((await run()).value.ready,true));
 test(file+' retains legacy user markup',async()=>assert.equal((await run({legacy:true})).value.ready,true));
 test(file+' rejects wrong command without fetching',async()=>{const r=await run({wrong:true});assert.equal(r.value.ready,false);assert.equal(r.fetched,0)});
 test(file+' rejects ambiguous originals',async()=>{const r=await run({ambiguous:true});assert.equal(r.value.reason,'ambiguous_or_missing_raster');assert.equal(r.fetched,0)});
 test(file+' never captures later user image',async()=>{const r=await run({later:true});if(prefix==='TTENDENCIAS'){assert.equal(r.value.reason,'later_user_turn');assert.equal(r.fetched,0)}else{assert.equal(r.value.ready,true);assert.equal(r.fetched,1)}});
 test(file+' preserves two actual bubbles despite four nested controls',()=>{
  const controls=Array.from({length:4},(_,i)=>({tagName:i%2?'DIV':'BUTTON',innerText:'',contains:()=>false}));
  const bubbles=[0,1].map((i)=>({innerText:prefix+'_IMAGE_JOB_V4 '+(i?'job-exact':'older-job')+' record',contains:x=>controls.slice(i*2,i*2+2).includes(x)}));
  const all=[bubbles[0],...controls.slice(0,2),bubbles[1],...controls.slice(2)];
  const document={querySelectorAll:s=>s==='[data-user-message-bubble="true"]'?bubbles:all};
  const code=section.slice(0,section.indexOf('function rasterProbe('));
  // Reproduce the old bug from the real diagnostic: four children, no commands.
  assert.deepEqual(all.filter(el=>!all.some(other=>other!==el&&el.contains(other))),controls);
  const users=vm.runInNewContext(code+';userTurns()',{document});
  assert.equal(users.length,2);assert.equal(users[1],bubbles[1]);
  const begin=source.indexOf('function conversationProbe('),end=source.indexOf('\nfunction ',begin+1);
  const expression=vm.runInNewContext(code+'\n'+source.slice(begin,end)+';conversationProbe("job-exact",true)');
  const result=vm.runInNewContext(expression,{document,location:{href:'https://chatgpt.com/c/exact'}});
  assert.equal(result.url,'https://chatgpt.com/c/exact');assert.equal(result.reason,'matched');
 });
}
