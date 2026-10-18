'use strict';
const fs=require('node:fs');
const assert=require('node:assert/strict');
const paths=['windows/TTiTTularesImageBridge.js','windows/TTendenciasImageBridge.js'];
async function testOne(path){
 const src=fs.readFileSync(path,'utf8');
 const begin=src.indexOf('async function prepareReusableConversation(cdp){');
 const end=src.indexOf('async function openFreshDedicatedConversation(){',begin);
 assert.ok(begin>=0&&end>begin,`${path}: missing SPA helper`);
 const factory=Function('sleep','waitComposer','navigateChatBestEffort','COMPOSER_SELECTOR',src.slice(begin,end)+'\nreturn prepareReusableConversation;');
 async function scenario({url,composer=true,canClick=true}){
  let href=url,clicks=0,navigations=0,waited=0;
  const cdp={async eval(expression){
   if(expression.includes("document.querySelectorAll('a,button')")){
    clicks++;
    if(canClick)href='https://chatgpt.com/';
    return canClick;
   }
   return {url:href,composer};
  }};
  const prepare=factory(async()=>{},async()=>{waited++;return {url:href,composer};},async()=>{navigations++;href='https://chatgpt.com/';},'#prompt-textarea');
  await prepare(cdp);
  return {clicks,navigations,waited,href};
 }
 let r=await scenario({url:'https://chatgpt.com/'});
 assert.equal(r.navigations,0,`${path}: home should not reload`);
 assert.equal(r.waited,1);
 r=await scenario({url:'https://chatgpt.com/c/existing-conversation'});
 assert.equal(r.navigations,0,`${path}: conversation should use SPA`);
 assert.equal(r.clicks,1);
 r=await scenario({url:'https://chatgpt.com/c/existing-conversation',canClick:false});
 assert.equal(r.navigations,1,`${path}: failed SPA must navigate`);
 r=await scenario({url:'https://chatgpt.com/%20https://chatgpt.com/'});
 assert.equal(r.navigations,1,`${path}: malformed URL must navigate`);
 r=await scenario({url:'about:blank',composer:false});
 assert.equal(r.navigations,1,`${path}: blank startup must navigate`);
 console.log('PASS SPA reuse/invalid URL/fallback:',path);
}
(async()=>{for(const p of paths)await testOne(p)})().catch(e=>{console.error(e);process.exitCode=1});
