'use strict';
// No browser or network required. Extract the real pre-submit recovery helper
// and evaluate its actual DOM probe in a small fake ChatGPT page.
const fs=require('node:fs');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const path='windows/TTiTTularesImageBridge.js';
const source=fs.readFileSync(path,'utf8');
const start=source.indexOf('async function ensureVisibleComposerBeforeInput(');
const end=source.indexOf('\nasync function inspectChat(',start);
assert(start>=0&&end>start,'missing guarded visible composer preflight');
assert(source.indexOf('await ensureVisibleComposerBeforeInput(cdp);')>end,
  'the real injector must call the preflight before typing');

async function trial({initiallyVisible=false,recoverOnNavigate=false,becomesVisible=false,
                     generating=false,typedDraft='',blocked=false,url='https://chatgpt.com/'}={}){
  let visible=initiallyVisible,evals=0,navigations=0,fronts=0,inserts=0;
  const editor={
    isConnected:true,disabled:false,readOnly:false,
    value:typedDraft,innerText:'',textContent:'',
    getAttribute(){return null},
    closest(){return null},
    getBoundingClientRect(){return {width:visible?420:0,height:visible?70:0}}
  };
  let href=url;
  const probeContext={
    document:{
      title:'ChatGPT',visibilityState:'visible',
      querySelectorAll(selector){
        if(/prompt-textarea|contenteditable|textbox/.test(selector))return [editor];
        return [];
      },
      querySelector(selector){
        if(selector.includes('stop-button'))return generating?{}:null;
        if(selector.includes('password'))return blocked?{}:null;
        return null;
      }
    },
    location:{get href(){return href}},
    getComputedStyle(){return {display:'block',visibility:'visible'}},
    Math,JSON
  };
  const cdp={
    async eval(expr){
      evals++;
      if(becomesVisible&&evals>=2)visible=true;
      return vm.runInNewContext(expr,probeContext,{timeout:500});
    },
    async call(method){
      if(method==='Page.bringToFront'){fronts++;return {}}
      if(method==='Input.insertText'){inserts++;throw Error('The preflight MUST NEVER type')}
      throw Error('Unexpected CDP '+method);
    }
  };
  const factory=new Function('sleep','navigateChatBestEffort','COMPOSER_SELECTOR','console',
    source.slice(start,end)+'\nreturn ensureVisibleComposerBeforeInput;');
  const preflight=factory(async()=>{},
    async()=>{navigations++;href='https://chatgpt.com/';if(recoverOnNavigate)visible=true},
    '#prompt-textarea,[contenteditable="true"][role="textbox"]',
    {log(){}});
  let result,error;
  try{result=await preflight(cdp,{maxPolls:2,delayMs:0})}
  catch(e){error=String(e&&e.message||e)}
  return {result,error,navigations,fronts,evals,inserts};
}

(async()=>{
  const ready=await trial({initiallyVisible:true});
  assert.equal(ready.error,undefined);assert.equal(ready.navigations,0);assert.equal(ready.inserts,0);
  const hydration=await trial({becomesVisible:true});
  assert.equal(hydration.error,undefined);assert.equal(hydration.navigations,0);
  const stale=await trial({recoverOnNavigate:true});
  assert.equal(stale.error,undefined);assert.equal(stale.navigations,1,'only same-target navigation');
  for(const reason of [{generating:true},{typedDraft:'Do not delete this unsent draft'},{blocked:true}]){
    const out=await trial(reason);
    assert.match(out.error,/sesión ocupada o requiere intervención/);
    assert.equal(out.navigations,0,'never navigate away from a generating/draft/blocked page');
    assert.equal(out.inserts,0);
  }
  const foreign=await trial({url:'https://example.test/'});
  assert.match(foreign.error,/ruta ajena/);assert.equal(foreign.navigations,0);
  const invisible=await trial();
  assert.match(invisible.error,/No hay compositor visible utilizable/);
  assert.equal(invisible.navigations,1,'one recovery only, never a loop of tabs');
  assert.equal(invisible.inserts,0);
  console.log('PASS TTiTTulares visible editor hydration, same-tab recovery, no unsafe navigation or input');
})().catch(e=>{console.error(e);process.exitCode=1});
