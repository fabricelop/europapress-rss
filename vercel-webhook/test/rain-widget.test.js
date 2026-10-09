import test from 'node:test';
import assert from 'node:assert/strict';
import {modelTransition,radarTransition,buildRainWidget} from '../rain/widget-core.js';

const now=Date.parse('2026-10-09T12:00:00Z');
const at=m=>Math.floor((now+m*60000)/1000);
function forecast(values,current=0) {
  return{current:{precipitation:current},minutely_15:{time:values.map((_,i)=>at(i*15)),precipitation:values}};
}
test('model detects onset with 15 minute continuity',()=>{
  const r=modelTransition(forecast([0,0,.16,.18,.20,0,0]),now);
  assert.equal(r.onset,now+30*60000);
});
test('single wet interval is not treated as a confirmed shower',()=>{
  assert.equal(modelTransition(forecast([0,.3,0,0]),now).onset,null);
});
test('model detects end of current rain, requiring two dry intervals',()=>{
  const r=modelTransition(forecast([.2,.2,.1,0,0,0],.2),now);
  assert.equal(r.end,now+45*60000);
});
test('no onset beyond forecast is explicit and never an invented ETA',()=>{
  const r=buildRainWidget(forecast([0,0,0,0]),null,{nowMs:now,lat:40.416,lon:-3.704});
  assert.equal(r.action,'none');
  assert.equal(r.targetAt,null);
  assert.ok(r.summary.includes('Sin inicio'));
});
test('stale radar is rejected',()=>{
  const r=radarTransition({ok:true,ageMinutes:60,nowcast:{status:'ok',confidence:.9,event:{start:new Date(now+5*60000).toISOString()}}},now);
  assert.equal(r.available,false);
});
test('fresh radar onset supersedes interpolated model forecast',()=>{
  const radar={ok:true,ageMinutes:7,observedAt:new Date(now-7*60000).toISOString(),sample:{rateMmH:0,wetFraction:0},
    nowcast:{status:'ok',confidence:.75,reliableHorizonMinutes:35,event:{start:new Date(now+10*60000).toISOString()}}};
  const r=buildRainWidget(forecast([0,0,.2,.2,0]),radar,{nowMs:now,lat:40,lon:-3});
  assert.equal(r.targetAt,new Date(now+10*60000).toISOString());
  assert.equal(r.precisionMinutes,5);
  assert.equal(r.confidence,'media');
});
test('unknown rain end is not guessed',()=>{
  const r=buildRainWidget(forecast([.2,.3,.3,.3],.2),null,{nowMs:now,lat:41,lon:-4});
  assert.equal(r.phase,'raining');assert.equal(r.action,'none');
});
