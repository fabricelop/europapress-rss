'use strict';
const assert=require('node:assert/strict');
const fs=require('node:fs');
const paths=['windows/TTiTTularesImageBridge.js','windows/TTendenciasImageBridge.js'];

for(const path of paths){
  const source=fs.readFileSync(path,'utf8');
  const start=source.indexOf('function submissionEvidence(');
  const end=source.indexOf('\nasync function ensureSubmitted(',start);
  assert(start>=0 && end>start,path+': missing submission evidence helper');
  const helper=Function(source.slice(start,end)+'\nreturn submissionEvidence;')();
  const defaults={triggeredAt:1000,promptWasVerified:true,preexistingGenerating:false,now:1900};
  const state={url:'https://chatgpt.com/',composerMarker:false,submitted:false,generating:true,commandOutsideComposer:false};
  // This is the observed live failure on 2026-10-19: generating true but
  // inConversation=false because a new/temporary chat is not at /c/.
  assert.equal(helper({...state,inConversation:false},defaults),'post-send-generation');
  assert.equal(helper({...state,url:'https://chatgpt.com/images'},defaults),'post-send-generation');
  assert.equal(helper({...state,url:'https://chatgpt.com/c/id',inConversation:true},defaults),'post-send-generation');
  assert.equal(helper({...state,generating:false,commandOutsideComposer:true},defaults),'command-outside-composer');
  assert.equal(helper({...state,submitted:true},{...defaults,promptWasVerified:false}),'user-turn');
  assert.equal(helper(state,{...defaults,triggeredAt:0}),'','no click means no proof');
  assert.equal(helper(state,{...defaults,now:1200}),'','click transition too recent');
  assert.equal(helper(state,{...defaults,promptWasVerified:false}),'','unverified prompt');
  assert.equal(helper(state,{...defaults,preexistingGenerating:true}),'','stale generation');
  assert.equal(helper({...state,composerMarker:true},defaults),'','draft still unsent');
  assert.equal(helper({...state,url:'https://evil.example/'},defaults),'','not a ChatGPT page');
  assert.equal(helper({...state,generating:false,commandOutsideComposer:false},defaults),'','no send evidence');
  assert.match(source,/cdp\.promptWasVerified=true/,'prompt verification must be stored');
  assert.match(source,/cdp\.preexistingGenerating=/,'must check generation baseline');
  assert.match(source,/const evidence=submissionEvidence\(st,/,'must use evidence helper');
  assert.match(source,/const composerMarker=editors\.some\(c=>read\(c\)\.includes\(command\)\)/,'must inspect all editors, not first empty editor');
  console.log('PASS command-scoped generation detection on ChatGPT routes:',path);
}
