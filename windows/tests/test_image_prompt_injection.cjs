'use strict';
const fs=require('node:fs'),assert=require('node:assert/strict');
const paths=['windows/TTiTTularesImageBridge.js','windows/TTendenciasImageBridge.js'];

async function runOne(path){
 const source=fs.readFileSync(path,'utf8');
 const start=source.indexOf('async function injectPromptIntoChat(cdp,job){');
 const stop=source.indexOf('async function submitVerifiedDraft(cdp,job){',start);
 assert(start>0&&stop>start,path+': missing injector');
 const factory=new Function('buildMessage','domImageCandidates','sleep','COMPOSER_SELECTOR','commandId','submitVerifiedDraft',
    source.slice(start,stop)+';return injectPromptIntoChat;');
 async function trial(validations,{noEditor=false,atomic=false}={}){
  const calls={insert:0,send:0,checked:0,front:0,atomic:0};
  const cdp={
   async eval(expr){
    if(expr.includes('const elements=[...document.querySelectorAll('))
     return {ok:!noEditor,found:noEditor?0:1,tag:'DIV',url:'https://chatgpt.com/'};
    if(expr.includes('generating:!!document.querySelector'))return {generating:false};
    if(expr.includes('return {ok:document.activeElement===c}'))return {ok:true};
    if(expr.includes('return {ok:!!c&&t.includes(')){
     const ok=validations[calls.checked++]??false;
     return {ok,len:ok?200:0,url:'https://chatgpt.com/'};
    }
    throw Error('Unknown CDP expression in test');
   },
   async call(method,params){
    if(method==='Input.insertText'){
      calls.insert++; assert.match(params.text,/IMAGE_JOB_V4/);
    }else if(method==='Page.bringToFront')calls.front++;
    else if(method.includes('send'))calls.send++;
    else throw Error('Unrecognized method '+method);
   }
  };
  const inject=factory(()=> 'IMAGE_JOB_V4 test abcdefghijklmnop',async()=>[],
    async()=>{},'#prompt-textarea','abcdefghijklmnop',async()=>{calls.atomic++;return atomic});
  let error=null;
  try{await inject(cdp,{})}catch(e){error=e}
  return {...calls,error};
 }
 const first=await trial([true]);
 assert.equal(first.error,null,path+': simple prompt fails');
 assert.equal(first.insert,1);
 assert.equal(first.atomic,1,'must try in-page atomic submit before separate verification');
 const sent=await trial([], {atomic:true});
 assert.equal(sent.error,null,'atomic verification+click should succeed');
 assert.equal(sent.insert,1);
 assert.equal(sent.checked,0,'a second verification after atomic click must not run');
 assert.equal(sent.atomic,1);
 const repaired=await trial([false,true]);
 assert.equal(repaired.error,null,path+': transient prompt not recovered');
 assert.equal(repaired.insert,2);
 const failed=await trial([false,false]);
 assert.match(String(failed.error),/Fallback no pudo escribir/);
 assert.equal(failed.insert,2);
 assert.equal(failed.send,0,'No incomplete prompt must be sent');
 const invisible=await trial([true],{noEditor:true});
 assert.match(String(invisible.error),/No hay compositor visible/);
 assert.equal(invisible.insert,0);
 assert.match(source,/if\(!launchOnly\)throw Error\("legacy_raster_mode_disabled_request_launch_only_job"\)/);
 console.log('PASS visible composer, retry, idempotent no-send, launch-only:',path);
}
(async()=>{for(const path of paths)await runOne(path)})().catch(e=>{console.error(e);process.exitCode=1});
