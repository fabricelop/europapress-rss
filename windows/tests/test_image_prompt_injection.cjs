'use strict';
const fs=require('node:fs'),assert=require('node:assert/strict');
const paths=['windows/TTiTTularesImageBridge.js','windows/TTendenciasImageBridge.js'];

async function runOne(path){
 const source=fs.readFileSync(path,'utf8');
 // Same safe ImageGen contract in both projects: generate and retain the
 // original, but leave association/publication to a later manual decision.
 if(path.includes('TTiTTularesImageBridge')){
   const begin=source.indexOf('function buildMessage(job){');
   const finish=source.indexOf('const BRIDGE_MODE=',begin);
   assert.ok(begin>=0&&finish>begin,'headline message builder missing');
   const make=new Function('commandId','targetId',source.slice(begin,finish)+';return buildMessage;')(
     'tt-img-test-1234567890','1234567890');
   const common={target_name:'Noticia de prueba',context_snapshot:{
     tweet_text:'Resumen factual verificado',remate:'Remate editorial',
     factual_summary:'Dato contrastado',image_style:'Gag visual limpio',image_style_name:'comic'}};
   const gag=make(common);
   assert.match(gag,/Usa ImageGen AHORA y genera UNA SOLA imagen GAG IA/);
   assert.match(gag,/Genera exactamente UNA imagen y conserva su original en ChatGPT Images/);
   assert.match(gag,/la revisión editorial es independiente/);
   assert.doesNotMatch(gag,/No proceses otra noticia ni descargues, captures, subas ni persistas/);
   const rigor=make({...common,editorial_image_mode:'rigor'});
   assert.match(rigor,/Genera y conserva el original en ChatGPT Images/);
   assert.match(rigor,/sin asociación, aprobación ni publicación automática/);
 }else{
   assert.match(source,/APROBACIÓN MANUAL OBLIGATORIA: genera y conserva solo el original/);
 }
 const start=source.indexOf('async function injectPromptIntoChat(cdp,job){');
 const stop=source.indexOf('async function submitVerifiedDraft(cdp,job){',start);
 assert(start>0&&stop>start,path+': missing injector');
 const factory=new Function('buildMessage','domImageCandidates','sleep','COMPOSER_SELECTOR','commandId','submitVerifiedDraft','ensureVisibleComposerBeforeInput',
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
    async()=>{},'#prompt-textarea','abcdefghijklmnop',async()=>{calls.atomic++;return atomic},async()=>true);
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
