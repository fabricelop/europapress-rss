'use strict';
const fs=require('node:fs');
const vm=require('node:vm');
const assert=require('node:assert/strict');
(async()=>{for(const path of ['windows/TTiTTularesImageBridge.js','windows/TTendenciasImageBridge.js']){
  const source=fs.readFileSync(path,'utf8');
  const start=source.indexOf('async function submitVerifiedDraft(cdp,job){');
  const end=source.indexOf('async function findFallbackComposerChat(job){',start);
  assert(start>=0 && end>start,path+' missing immediate submit helper');
  assert(source.includes('await submitVerifiedDraft(cdp,job);'),path+' must invoke immediate submit');
  assert.match(source,/triggeredAt=Number\(cdp\.promptSubmittedAt\|\|0\)/,'must retain triggered timestamp');
  const message='TTITTULARES_IMAGE_JOB_V4 tt-img-test-abcdefg / genera UNA imagen '+ 'hechos '.repeat(45)+'FIN_PROMPT_TEST';
  const submit=new Function('buildMessage','commandId','COMPOSER_SELECTOR',
    source.slice(start,end)+';return submitVerifiedDraft;')(
      ()=>message,'tt-img-test-abcdefg','#prompt-textarea');
  async function trial({draft=message,disabled=false,hidden=false,button=true,form=true}={}){
    let clicks=0,submitCalls=0;
    const c={value:draft,closest:()=>form?frm:null};
    const b={isConnected:true,disabled,click:()=>{clicks++;c.value=''},
      getBoundingClientRect:()=>({width:hidden?0:32,height:hidden?0:32})};
    const frm={querySelectorAll:()=>button?[b]:[],
      requestSubmit(){submitCalls++;c.value=''}};
    const context={
      document:{querySelector:()=>c,querySelectorAll:()=>button?[b]:[]},
      getComputedStyle:()=>({display:'block',visibility:'visible'}),
      location:{href:'https://chatgpt.com/'},
      Set,Math,String,Number
    };
    const cdp={eval:async expression=>vm.runInNewContext(expression,context,{timeout:300}),
      promptSubmittedAt:0};
    const result=await submit(cdp,{});
    return {result,clicks,submitCalls,stamp:cdp.promptSubmittedAt};
  }
  const good=await trial();
  assert.equal(good.result,true,path+': valid prompt should be sent');
  assert.equal(good.clicks,1,'exactly one button click');
  assert.ok(good.stamp>0);
  for(const wrong of ['','tt-img-test-abcdefg truncated','wrong id '+message.slice(60)]){
    const r=await trial({draft:wrong});
    assert.equal(r.result,false,'must reject incomplete or unrelated text');
    assert.equal(r.clicks,0);
    assert.equal(r.submitCalls,0);
  }
  const fallback=await trial({button:false});
  assert.equal(fallback.result,true,'form fallback should work');
  assert.equal(fallback.submitCalls,1);
  const disabledResult=await trial({disabled:true,form:false});
  assert.equal(disabledResult.result,false,'disabled control must not send');
  const hiddenResult=await trial({hidden:true,form:false});
  assert.equal(hiddenResult.result,false,'hidden control must not send');
  console.log('PASS immediate command-scoped submission, single-click, no altered drafts:',path);
}
})().catch(e=>{console.error(e);process.exitCode=1});
