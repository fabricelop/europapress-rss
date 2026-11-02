import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { publishApprovedOnce, PublicationBlocked } from '../tools/publish-approved-once.mjs';
const png=Buffer.from([137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1]);
const hash=createHash('sha256').update(png).digest('hex');
const candidate={id:'a'.repeat(64),state:'approved_awaiting_publication',identity:{project:'ttendencias',editorialId:'x-y-z',revision:0,episodeFingerprint:'b'.repeat(64),commandId:'tr-img-cmd',rasterSHA256:hash},editorialText:'Texto vigente'};
candidate.id=createHash('sha256').update(JSON.stringify(candidate.identity)).digest('hex');
const current={id:'x-y-z',project:'ttendencias',revision:0,editorialText:'Texto vigente'};
function harness({state=candidate.state, changeAfter=Infinity, tamperApp=false, tamperSites=false}={}){
 const order=[];let readCount=0;
 const deps={candidateID:candidate.id,
  privateInbox:{list:async()=>[{...candidate,state}],download:async()=>({bytes:png,sha256:hash})},
  editorial:{current:async()=>{order.push('main');return ++readCount>=changeAfter?{...current,editorialText:'Reelaborado'}:current;}},
  app:{publish:async()=>order.push('app.write'),readback:async()=>{order.push('app.read');return {identity:candidate.identity,imageBytes:tamperApp?Buffer.from('other'):png}}},
  sites:{publish:async()=>order.push('sites.write'),readback:async()=>{order.push('sites.read');return {identity:candidate.identity,imageBytes:tamperSites?Buffer.from('other'):png}}},
  receipts:{record:async()=>order.push('receipt')},
 };
 return {deps,order};
}
test('writes only an approved candidate, independently verifies exact PNG in both destinations',async()=>{
 const {deps,order}=harness();
 const result=await publishApprovedOnce(deps);
 assert.equal(result.state,'verified_both_destinations');
 assert.deepEqual(order,['main','app.write','app.read','main','sites.write','sites.read','main','receipt']);
});
test('no approval, no public writes',async()=>{
 const {deps,order}=harness({state:'pending'});
 await assert.rejects(publishApprovedOnce(deps),{code:'NO_EXACT_APPROVAL'});
 assert.deepEqual(order,[]);
});
test('stale identity before writing blocks both destinations',async()=>{
 const {deps,order}=harness({changeAfter:1});
 await assert.rejects(publishApprovedOnce(deps),{code:'EDITORIAL_CHANGED_OR_NOT_READY'});
 assert.deepEqual(order,['main']);
});
test('if editorial is rewritten after app write, never publish to Sites or claim success',async()=>{
 const {deps,order}=harness({changeAfter:2});
 await assert.rejects(publishApprovedOnce(deps),{code:'EDITORIAL_CHANGED_OR_NOT_READY'});
 assert.deepEqual(order,['main','app.write','app.read','main']);
});
test('mismatched bytes in app readback block Sites and any success receipt',async()=>{
 const {deps,order}=harness({tamperApp:true});
 await assert.rejects(publishApprovedOnce(deps),{code:'DESTINATION_READBACK_MISMATCH'});
 assert.deepEqual(order,['main','app.write','app.read']);
});
test('wrong image returned by Sites blocks final verification and success receipt',async()=>{
 const {deps,order}=harness({tamperSites:true});
 await assert.rejects(publishApprovedOnce(deps),{code:'DESTINATION_READBACK_MISMATCH'});
 assert.equal(order.at(-1),'sites.read');
 assert.ok(!order.includes('receipt'));
});
test('bad original or missing authenticated adapter fails closed',async()=>{
 const {deps,order}=harness();deps.privateInbox.download=async()=>({bytes:Buffer.from('fake'),sha256:hash});
 await assert.rejects(publishApprovedOnce(deps),{code:'ORIGINAL_SHA_MISMATCH'});
 assert.deepEqual(order,[]);
 const {deps:other}=harness();delete other.sites;
 await assert.rejects(publishApprovedOnce(other),{code:'INCOMPLETE_PRIVATE_PUBLISHER'});
});

test('mismatched approval key, despite correct media, is never published',async()=>{
 const {deps,order}=harness();deps.privateInbox.list=async()=>[{...candidate,id:candidate.id,identity:{...candidate.identity,commandId:'tr-img-other'}}];
 await assert.rejects(publishApprovedOnce(deps),{code:'NO_EXACT_APPROVAL'});
 assert.deepEqual(order,[]);
});