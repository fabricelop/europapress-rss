'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs');
const source=fs.readFileSync('windows/TTendenciasImageBridge.js','utf8');
const listener=fs.readFileSync('windows/TTendenciasDedicatedListener.ps1','utf8');
const extension=listener.match(/\$tmp = \$ImageBridge \+ "([^\"]+)"/);
assert.ok(extension,'refresh path must be explicit');
assert.equal(extension[1],'.new.js','Node syntax check needs a JavaScript suffix');
const temporary=fs.mkdtempSync(require('node:path').join(require('node:os').tmpdir(),'tt-refresh-test-'));
try{
 const candidate=require('node:path').join(temporary,'TTendenciasImageBridge.js'+extension[1]);
 fs.writeFileSync(candidate,source);
 require('node:child_process').execFileSync(process.execPath,['--check',candidate]);
}finally{fs.rmSync(temporary,{recursive:true,force:true});}
const start=source.indexOf('async function closeFixedTargetById(targetId){');
const end=source.indexOf('\nasync function waitComposer(',start);
const factory=Function('fetch','BASE_CDP','AbortSignal','CDP','console','sleep','targets',source.slice(start,end)+'\nreturn {closeFixedTargetById,waitFixedTargetClosed};');
async function scenario({refused=false,unreachable=false,stuck=false,delayed=false}={}){
 const urls=[],closed=[],other='unrelated-news-tab';let pending=true,polls=0;
 class CDP {async open(){} async call(method,params){assert.equal(method,'Target.closeTarget');closed.push(params.targetId);if(unreachable)throw Error('CDP timeout');return {success:!refused};}close(){}}
 const fetch=async url=>{urls.push(url);if(url.endsWith('/json/version'))return {ok:true,json:async()=>({webSocketDebuggerUrl:'ws://browser'})};assert.equal(url,'http://127.0.0.1:9223/json/close/pinned-trends');if(!stuck&&!delayed)pending=false;return {ok:true,status:200};};
 const helpers=factory(fetch,'http://127.0.0.1:9223',{timeout:()=>({})},CDP,{log(){}},async()=>{},async()=>{polls++;if(delayed&&polls===8)pending=false;return [{id:other,type:'page'},...(pending?[{id:'pinned-trends',type:'page'}]:[])];});
 await helpers.closeFixedTargetById('pinned-trends');
 const result=await helpers.waitFixedTargetClosed('pinned-trends');
 assert.deepEqual(closed,['pinned-trends']);assert(!urls.some(x=>/new|9234|close\/$/.test(x)));assert.ok(polls<=20);
 return {result,urls,polls};
}
(async()=>{
 assert.ok((await scenario({unreachable:true})).result,'HTTP fallback closes exact target after websocket failure');
 assert.ok((await scenario({refused:true})).result,'explicit refusal uses fallback');
 assert.ok((await scenario({delayed:true})).result,'wait for actual disappearance, not just close acknowledgement');
 assert.equal((await scenario({stuck:true})).result,false,'no replacement when the pinned tab remains');
 const main=source.slice(source.indexOf('(async()=>{\n  let cdp;'));
 assert(main.indexOf('TTENDENCIAS_PRE_SUBMIT_FAILED')<main.indexOf('injectPromptIntoChat(cdp,job)'));
 assert.match(source,/stage:"progress",upload_secret:secret/,'progress must authenticate against picked-up secret');
 console.log('PASS exact pinned target, HTTP fallback, delayed close, no duplicate target, pre-submit boundary');
})().catch(e=>{console.error(e);process.exitCode=1});
