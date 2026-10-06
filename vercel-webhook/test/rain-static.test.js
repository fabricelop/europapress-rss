import test from 'node:test';
import assert from 'node:assert/strict';
import {aggregateEnsembleModel,buildConsensus,detectRainEvents,detectQuarterHourEvents,chooseNextEvent,classifyRainHour,bestDryWindow} from '../rain/core.js';
import {estimateTranslation,combineMotionEstimates,projectPointSeries,detectNowcastEvent,wetNear,valueNear} from '../rain/radar-core.js';

function mask(w,h,x0,y0,ww=7,hh=7){const a=new Uint8Array(w*h);for(let y=y0;y<y0+hh;y++)for(let x=x0;x<x0+ww;x++)if(x>=0&&x<w&&y>=0&&y<h)a[y*w+x]=1;return a}

test('ensemble derives wet probability',()=>{
 const a=aggregateEnsembleModel({time:['2026-10-06T10:00:00Z'],precipitation_member00:[0],precipitation_member01:[.2],precipitation_member02:[1],precipitation_member03:[.05]});
 assert.equal(a.memberCount,4);assert.equal(a.rows[0].probability,.5);
});
test('consensus gives ensembles more influence after 24h',()=>{
 const time='2026-10-08T10:00:00Z';
 const r=buildConsensus({nowMs:Date.parse('2026-10-06T00:00:00Z'),deterministic:[{weight:1,rows:[{time,precipitation:0}]}],ensembles:[{weight:1,rows:[{time,probability:.9,median:.4}]}]});
 assert.ok(r[0].probability>.65);
});
test('event detection and next active event',()=>{
 const base=Date.parse('2026-10-06T10:00:00Z');
 const p=[.1,.7,.65,.1].map((probability,i)=>({time:new Date(base+i*3600e3).toISOString(),probability,expectedPrecipitation:probability>.4?.3:0,timingConfidence:.8,providerCount:7}));
 const e=detectRainEvents(p);assert.equal(e.length,1);assert.equal(chooseNextEvent(e,base+90*60e3),e[0]);
});
test('quarter hour event',()=>{const t=[0,1,2,3].map(i=>new Date(Date.parse('2026-10-06T10:00:00Z')+i*15*60e3).toISOString());const e=detectQuarterHourEvents(t,[0,.04,.2,0]);assert.equal(e.length,1)});
test('radar translation and projected arrival',()=>{
 const w=64,h=64,m=estimateTranslation(mask(w,h,14,26,12,9),mask(w,h,18,24,12,9),w,h,{maxShift:8});
 assert.equal(m.dx,4);assert.equal(m.dy,-2);
 const c=combineMotionEstimates([m,{...m,dx:4,dy:-2,confidence:.8},{...m,dx:3,dy:-2,confidence:.7}]);assert.ok(c.confidence>.5);
 const s=projectPointSeries(mask(80,80,19,35,10,10),80,80,{dx:5,dy:0,confidence:.9},{horizonMinutes:60,sourceStepMinutes:10,outputStepMinutes:5,radius:2});
 assert.ok(detectNowcastEvent(s,{enterWetFraction:.1,exitWetFraction:.05,minConsecutive:1}));
});
test('wetNear distinguishes dry/wet',()=>{const m=mask(20,20,8,8,4,4);assert.equal(wetNear(m,20,20,2,2,1),0);assert.ok(wetNear(m,20,20,9,9,1)>.5)});

test('confidence is capped at long horizons and counts independent families',()=>{
 const time='2026-10-08T12:00:00Z';
 const r=buildConsensus({
   nowMs:Date.parse('2026-10-06T00:00:00Z'),
   deterministic:[
     {id:'ifs',family:'ECMWF',weight:1,rows:[{time,precipitation:.5}]},
     {id:'icon',family:'DWD',weight:1,rows:[{time,precipitation:.5}]}
   ],
   ensembles:[
     {id:'ens',family:'ECMWF',weight:1,rows:[{time,probability:1,median:.5}]},
     {id:'eps',family:'DWD',weight:1,rows:[{time,probability:1,median:.5}]}
   ]
 });
 assert.equal(r[0].independentFamilyCount,2);
 assert.ok(r[0].timingConfidence<=.68);
});

test('marginal probabilities do not become continuous rain',()=>{
  const base=Date.parse('2026-10-06T10:00:00Z');
  const points=Array.from({length:12},(_,i)=>({
    time:new Date(base+i*3600e3).toISOString(),
    probability:.38,
    expectedPrecipitation:.04,
    timingConfidence:.6,
    providerCount:8,
    independentFamilyCount:6
  }));
  assert.equal(detectRainEvents(points).length,0);
});

test('projected radar intensity follows motion',()=>{
  const w=40,h=40,m=mask(w,h,10,18,6,5),rates=new Float32Array(w*h);
  for(let y=18;y<23;y++)for(let x=10;x<16;x++)rates[y*w+x]=2.4;
  assert.equal(valueNear(rates,w,h,2,2,0),0);
  assert.ok(valueNear(rates,w,h,12,20,1)>2);
  const series=projectPointSeries(m,w,h,{dx:4,dy:0,confidence:.9},{horizonMinutes:40,sourceStepMinutes:10,outputStepMinutes:5,radius:0,intensityGrid:rates});
  assert.ok(series.some(row=>row.radarRate>2));
});

test('low amount high-ish probability is possible, not continuous rain',()=>{
  assert.equal(classifyRainHour({probability:.62,expectedPrecipitation:.018}),'possible');
  assert.equal(classifyRainHour({probability:.70,expectedPrecipitation:.01}),'dry');
});

test('rain events split across a weak dry window',()=>{
  const base=Date.parse('2026-10-06T10:00:00Z');
  const vals=[
    [.72,.18],[.76,.24],[.68,.14],
    [.42,.02],[.34,.01],
    [.71,.16],[.66,.11]
  ];
  const points=vals.map(([probability,expectedPrecipitation],i)=>({
    time:new Date(base+i*3600e3).toISOString(),
    probability,expectedPrecipitation,timingConfidence:.75,providerCount:8,independentFamilyCount:6
  }));
  const events=detectRainEvents(points);
  assert.equal(events.length,2);
  assert.equal(events[0].durationHours,3);
  assert.equal(events[1].durationHours,2);
  assert.ok(events[0].totalExpectedPrecipitation>.5);
});


test('best dry window finds the longest practical gap',()=>{
  const now=Date.parse('2026-10-06T10:00:00Z'),end=now+12*3600e3;
  const events=[
    {start:new Date(now+60*60e3).toISOString(),end:new Date(now+120*60e3).toISOString()},
    {start:new Date(now+5*3600e3).toISOString(),end:new Date(now+6*3600e3).toISOString()}
  ];
  const dry=bestDryWindow(events,now,end);
  assert.equal(dry.start,now+6*3600e3);
  assert.equal(dry.end,end);
  assert.equal(dry.minutes,360);
});
