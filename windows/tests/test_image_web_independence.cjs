'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync('windows/TTendenciasImageBridge.js','utf8');
const boundary=source.slice(source.indexOf('async function optionalWebHandoff('));
async function run({exporter,preflightError=false,verifyError=false}={}){
 const calls=[];
 const cdp={fixedTargetId:'own-target',close(){calls.push('close');}};
 const context={require(){calls.push('web');if(exporter instanceof Error)throw exporter;return exporter;},
  console:{log(){},error(){}},process:{exitCode:0},sleep:async()=>{},commandId:'command-123',targetId:'trend-123',secret:'test-only-secret',
  fetchJob:async()=>({delivery_mode:'launch_only'}),BRIDGE_MODE:'test',
  openFreshDedicatedConversation:async()=>{calls.push('open');if(preflightError)throw Error('composer failed');return cdp;},
  injectPromptIntoChat:async x=>{calls.push('inject');return x;},
  submitVerifiedDraft:async()=>{calls.push('submit');cdp.promptSubmittedAt=1;},
  ensureSubmitted:async x=>{calls.push('verify');if(verifyError)throw Error('ack uncertain');return x;},
  confirmPromptLaunched:async()=>{calls.push('launched');},
  holdForWebImageReceipt:async()=>{calls.push('hold');return 'web_image_done';},
  fail:async()=>{calls.push('failed');},progress:async()=>{}};
 await vm.runInNewContext(boundary,context);
 return {calls,exitCode:context.process.exitCode};
}
test('a missing web module cannot prevent injection, verified send or launched receipt',async()=>{
 const result=await run({exporter:Error('MODULE_NOT_FOUND')});
 assert.deepEqual(result.calls.filter(x=>x!=='web'),['open','inject','submit','verify','launched','hold','close']);
 assert.ok(result.calls.indexOf('web')>result.calls.indexOf('launched'),'web module is never loaded before send/launch');
 assert.equal(result.exitCode,0);
});
test('DPAPI/disk failure in enrollment and conversation discovery cannot fail a generation',async()=>{
 const result=await run({exporter:{enroll(){throw Error('DPAPI unavailable');},async rememberConversation(){throw Error('discovery failed');}}});
 assert.ok(result.calls.includes('launched'));assert.ok(!result.calls.includes('failed'));assert.equal(result.exitCode,0);
});
test('a real pre-submit browser failure remains an error without any prompt or image duplicate',async()=>{
 const result=await run({exporter:{},preflightError:true});
 assert.deepEqual(result.calls,['open','failed']);assert.equal(result.exitCode,1);
});
test('an uncertain result after send still saves the handoff without submitting again',async()=>{
 let enrollments=0;
 const result=await run({verifyError:true,exporter:{async rememberConversation(){enrollments++;return true;}}});
 assert.equal(enrollments,1);assert.equal(result.calls.filter(x=>x==='submit').length,1);assert.ok(result.calls.includes('failed'));
});

test('LAUNCHED waits for independent web receipt; no duplicate prompt or raster capture in bridge',async()=>{
 const result=await run({exporter:{async rememberConversation(){return true;}}});
 assert.equal(result.calls.filter(x=>x==='inject').length,1);
 assert.equal(result.calls.filter(x=>x==='submit').length,1);
 assert.equal(result.calls.filter(x=>x==='hold').length,1);
 assert.ok(result.calls.indexOf('hold')>result.calls.indexOf('launched'));
 assert.ok(result.calls.indexOf('hold')<result.calls.indexOf('close'));
 assert.equal(result.exitCode,0);
});
test('passive publisher can run during own confirmed LAUNCHED only; never with TTiTTulares',()=>{
 const listener=fs.readFileSync('windows/TTendenciasDedicatedListener.ps1','utf8');
 const start=listener.indexOf('function Start-WebImagePublisher {');
 const end=listener.indexOf('\nfunction Start-ImageBridge(',start);
 assert.ok(start>=0&&end>start);
 const gate=listener.slice(start,end);
 assert.match(gate,/TTiTTularesImageBridge/);
 assert.match(gate,/\$lock\.command_id/);
 assert.match(gate,/\$job\.pc_launched_at/);
 assert.match(gate,/\$job\.delivery_mode/);
 assert.match(gate,/\$own\.Count -ne 1/);
});
