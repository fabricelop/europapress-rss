import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {normalizeLightningLayer,parseLightningBbox,buildDwdLightningGetMapUrl} from '../lib/rain-lightning.js';
import {buildRainViewerSourceTileUrl,reconstructRadarTileRgba,validateRainViewerFramePath,buildSyntheticFutureField} from '../lib/rain-radar-synthetic.js';
import {selectSpatialForecastTimeIndex,selectSpatialForecastTimeBlend,hybridFutureBlend,futureVisualLabel} from '../rain/model-map-core.js';
import {aggregateEnsembleModel,buildConsensus,detectRainEvents,detectQuarterHourEvents,chooseNextEvent,classifyRainHour,bestDryWindow} from '../rain/core.js';
import {estimateTranslation,combineMotionEstimates,projectPointSeries,estimateLocalFlow,combineLocalFlows,projectPointSeriesFlow,evolutionReliability,detectNowcastEvent,wetNear,valueNear,flowVectorAt,buildRadarProjectionRgba,projectRadarFieldContinuous,evaluateOverlaySourceState,wmsCapabilitiesHasLayer,radarProjectionRenderMode,radarViewportProjectionZoom} from '../rain/radar-core.js';
import {decodeHarmoniePrecipRgba,parseTarEntries} from '../rain/harmonie-core.js';

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


test('local radar flow tracks translating echo',()=>{
  const w=72,h=72,prev=mask(w,h,18,29,12,10),cur=mask(w,h,22,27,12,10);
  const global=estimateTranslation(prev,cur,w,h,{maxShift:8});
  const flow=estimateLocalFlow(prev,cur,w,h,{maxShift:8,grid:5,patchRadius:9});
  assert.ok(global);
  assert.ok(flow);
  assert.ok(flow.coverage>0);
  const series=projectPointSeriesFlow(cur,w,h,flow,global,{horizonMinutes:60,sourceStepMinutes:10,outputStepMinutes:5,radius:2,reliability:.9});
  assert.equal(series.length,13);
  assert.ok(series.every(row=>Number.isFinite(row.probability)));
});

test('evolution reliability penalizes changing echo shape',()=>{
  const w=64,h=64,prev=mask(w,h,14,25,12,10);
  const translated=mask(w,h,18,23,12,10);
  const changed=new Uint8Array(w*h);
  const a=mask(w,h,18,23,5,4),b=mask(w,h,43,8,14,15);
  for(let i=0;i<changed.length;i++)changed[i]=a[i]||b[i]?1:0;
  const motion=combineMotionEstimates([
    estimateTranslation(prev,translated,w,h,{maxShift:8}),
    {...estimateTranslation(prev,translated,w,h,{maxShift:8}),confidence:.8}
  ]);
  const stable=evolutionReliability(prev,translated,w,h,motion);
  const unstable=evolutionReliability(prev,changed,w,h,motion);
  assert.ok(stable.score>unstable.score);
  assert.ok(stable.densityStable>=unstable.densityStable);
});


test('several local flows stabilize the motion field',()=>{
  const w=72,h=72;
  const m0=mask(w,h,14,29,12,10),m1=mask(w,h,18,27,12,10),m2=mask(w,h,22,25,12,10);
  const f1=estimateLocalFlow(m0,m1,w,h,{maxShift:8,grid:5,patchRadius:9});
  const f2=estimateLocalFlow(m1,m2,w,h,{maxShift:8,grid:5,patchRadius:9});
  const combined=combineLocalFlows([f1,f2]);
  assert.ok(combined);
  assert.equal(combined.historySamples,2);
  assert.ok(combined.confidence>0);
});

test('local flow history never mixes different grid coordinates when samples are missing',()=>{
  const f1={coverage:.5,vectors:[
    {x:10,y:10,dx:1,dy:0,confidence:.9},
    {x:20,y:10,dx:5,dy:0,confidence:.9}
  ]};
  const f2={coverage:.25,vectors:[
    {x:20,y:10,dx:5,dy:0,confidence:.8}
  ]};
  const combined=combineLocalFlows([f1,f2]);
  assert.ok(combined);
  const left=combined.vectors.find(v=>v.x===10&&v.y===10);
  const right=combined.vectors.find(v=>v.x===20&&v.y===10);
  assert.ok(left);assert.ok(right);
  assert.equal(left.dx,1);
  assert.equal(right.dx,5);
  assert.equal(right.samples,2);
  assert.equal(left.samples,1);
});


test('AEMET HARMONIE precipitation palette decodes official bins',()=>{
  const dry=decodeHarmoniePrecipRgba(19,49,52,0);
  assert.equal(dry.low,0);assert.equal(dry.high,.5);assert.equal(dry.estimate,0);
  const light=decodeHarmoniePrecipRgba(176,224,230,255);
  assert.equal(light.low,.5);assert.equal(light.high,1);assert.equal(light.estimate,.75);
  const moderate=decodeHarmoniePrecipRgba(0,204,128,255);
  assert.equal(moderate.low,2);assert.equal(moderate.high,5);assert.equal(moderate.estimate,3.5);
});

test('AEMET HARMONIE TAR parser locates file payloads safely',()=>{
  const tar=Buffer.alloc(2048);
  const name='down_2026-10-07T18:00:00+00:00_61_1HH.tif';
  tar.write(name,0,'utf8');
  const payload=Buffer.from('abcde');
  const sizeOct=payload.length.toString(8).padStart(11,'0')+'\0';
  tar.write(sizeOct,124,'ascii');
  payload.copy(tar,512);
  const entries=parseTarEntries(tar);
  assert.equal(entries.length,1);
  assert.equal(entries[0].name,name);
  assert.equal(entries[0].size,5);
  assert.equal(tar.subarray(entries[0].start,entries[0].end).toString(),'abcde');
});


test('future radar projection keeps dry background fully transparent',()=>{
  const mask=new Uint8Array([0,1,1,0]);
  const rates=new Float32Array([9,1.2,0,7]);
  const out=buildRadarProjectionRgba(mask,rates,2,2,()=>[10,20,30,210]);
  assert.deepEqual(Array.from(out.rgba.filter((_,i)=>i%4===3)),[0,210,0,0]);
  assert.equal(out.alphaPixels,1);
  assert.equal(out.wetPixels,1);
  assert.equal(out.opaqueFraction,.25);
});

test('sparse future radar cannot become an opaque rectangle',()=>{
  const w=20,h=20,mask=new Uint8Array(w*h),rates=new Float32Array(w*h);
  mask[199]=1;rates[199]=4.5;
  const out=buildRadarProjectionRgba(mask,rates,w,h,()=>[100,150,220,255]);
  assert.equal(out.alphaPixels,1);
  assert.ok(out.opaqueFraction<.01);
  for(let i=0;i<out.rgba.length;i+=4){
    if(i===199*4)continue;
    assert.equal(out.rgba[i+3],0);
  }
});

test('lightning overlay never reports active before source verification',()=>{
  assert.equal(evaluateOverlaySourceState({enabled:true,context:true,verified:false,loaded:2,errors:0}),'unverified');
  assert.equal(evaluateOverlaySourceState({enabled:true,context:true,verified:false,loaded:0,errors:1}),'error');
  assert.equal(evaluateOverlaySourceState({enabled:true,context:true,verified:true,loaded:1,errors:0}),'active');
});


test('RainETA CSP allows DWD lightning capabilities and WMS images',()=>{
  const config=JSON.parse(readFileSync(new URL('../vercel.json',import.meta.url),'utf8'));
  const rain=config.headers.find(row=>row.source==='/rain/(.*)');
  const csp=rain?.headers?.find(row=>row.key==='Content-Security-Policy')?.value||'';
  assert.match(csp,/connect-src[^;]*https:\/\/maps\.dwd\.de/);
  assert.match(csp,/img-src[^;]*https:\/\/maps\.dwd\.de/);
});


test('DWD workspace capabilities accept local or namespace-qualified layer names',()=>{
  assert.equal(wmsCapabilitiesHasLayer('<Layer><Name>Accumulated_Flash_Geometry</Name></Layer>','dwd:Accumulated_Flash_Geometry'),true);
  assert.equal(wmsCapabilitiesHasLayer('<Layer><Name>dwd:NCEW_EU</Name></Layer>','dwd:NCEW_EU'),true);
  assert.equal(wmsCapabilitiesHasLayer('<Layer><Name>Other</Name></Layer>','dwd:NCEW_EU'),false);
});


test('future radar MapLibre path uses generated image source, never CanvasSource',()=>{
  const app=readFileSync(new URL('../rain/app.js',import.meta.url),'utf8');
  assert.match(app,/type:'image',url:imageUrl,coordinates/);
  assert.doesNotMatch(app,/raineta-radar-projection'\s*,\s*\{type:'canvas'/);
  assert.match(app,/canvas\.toDataURL\('image\/png'\)/);
});

test('RainETA lightning proxy only accepts known DWD layers and sane WebMercator bbox',()=>{
  assert.equal(normalizeLightningLayer('Accumulated_Flash_Geometry'),'dwd:Accumulated_Flash_Geometry');
  assert.equal(normalizeLightningLayer('dwd:NCEW_EU'),'dwd:NCEW_EU');
  assert.throws(()=>normalizeLightningLayer('dwd:AnythingElse'),/layer_not_allowed/);
  assert.deepEqual(parseLightningBbox('-1000,-2000,3000,4000'),[-1000,-2000,3000,4000]);
  assert.throws(()=>parseLightningBbox('0,0,0,1'),/invalid_bbox/);
  const url=buildDwdLightningGetMapUrl({layer:'dwd:NCEW_EU',bbox:'-1000,-2000,3000,4000'});
  assert.match(url,/maps\.dwd\.de\/geoserver\/dwd\/wms/);
  assert.match(url,/layers=dwd%3ANCEW_EU/);
});

test('RainETA lightning browser path is same-origin proxy only',()=>{
  const app=readFileSync(new URL('../rain/app.js',import.meta.url),'utf8');
  assert.match(app,/const LIGHTNING_PROXY_URL='\/api\/rain-lightning'/);
  assert.doesNotMatch(app,/const LIGHTNING_WMS_URL='https:\/\/maps\.dwd\.de/);
});


test('radar +1 keeps decoded field by persistence when motion guidance is uncertain',()=>{
  assert.equal(radarProjectionRenderMode({minutes:1,fieldAvailable:true,guidanceOk:false,horizon:0,continuityMinutes:3}),'persistence');
  assert.equal(radarProjectionRenderMode({minutes:3,fieldAvailable:true,guidanceOk:false,horizon:0,continuityMinutes:3}),'persistence');
  assert.equal(radarProjectionRenderMode({minutes:4,fieldAvailable:true,guidanceOk:false,horizon:0,continuityMinutes:3}),'none');
});

test('radar uses local flow when guidance is reliable and never needs persistence',()=>{
  assert.equal(radarProjectionRenderMode({minutes:1,fieldAvailable:true,guidanceOk:true,horizon:30,continuityMinutes:3}),'flow');
  assert.equal(radarProjectionRenderMode({minutes:20,fieldAvailable:true,guidanceOk:true,horizon:30,continuityMinutes:3}),'flow');
  assert.equal(radarProjectionRenderMode({minutes:31,fieldAvailable:true,guidanceOk:true,horizon:30,continuityMinutes:3}),'none');
});


test('continuous nowcast retains projectionField and never removes the old radar before the replacement is ready',()=>{
  const app=readFileSync(new URL('../rain/app.js',import.meta.url),'utf8');
  assert.match(app,/const base=\{[^\n]*projectionField\};/);
  assert.match(app,/projectRadarFieldContinuous\(field,guidance\?\.flow,minutes/);
  const start=app.indexOf('async function showProjectedRadar');
  const end=app.indexOf('function showRadarOffset',start);
  const fn=app.slice(start,end);
  const add=fn.indexOf("state.map.addSource(incoming,{type:'image',url:imageUrl,coordinates})");
  const wait=fn.indexOf("await waitForRasterSources([incoming],token,2200)",add);
  const swap=fn.indexOf("animateRadarSwap(incoming,opacity,token,170,minutes)",wait);
  assert.ok(add>=0&&wait>add&&swap>wait);
  assert.doesNotMatch(fn.slice(add,swap),/clearRadarVisual\(\)/);
});
test('lightning mode desaturates radar precipitation to grayscale',()=>{
  const app=readFileSync(new URL('../rain/app.js',import.meta.url),'utf8');
  assert.match(app,/setPaintProperty\(id,'raster-saturation',gray\?-1:0\)/);
  assert.match(app,/state\.lightningEnabled&&lightningContextVisible\(\)\?-1:0/);
});


test('radar viewport zoom expands enough to cover a wide map',()=>{
  assert.equal(radarViewportProjectionZoom(7,800,330,{minZoom:3,maxZoom:7,tileDisplaySize:512}),6);
  assert.equal(radarViewportProjectionZoom(5,800,330,{minZoom:3,maxZoom:7,tileDisplaySize:512}),4);
  assert.equal(radarViewportProjectionZoom(4,1200,700,{minZoom:3,maxZoom:7,tileDisplaySize:512}),3);
});

test('future radar samples the current map view instead of state.loc',()=>{
  const app=readFileSync(new URL('../rain/app.js',import.meta.url),'utf8');
  assert.match(app,/async function radarViewportNowcast\(meta\)/);
  assert.match(app,/const center=state\.map\.getCenter\(\),zoom=radarProjectionZoom\(\)/);
  assert.match(app,/radarViewTileUrl\(meta,frame,center,zoom\)/);
  assert.match(app,/radarImageCoordinates\(field\.centerLat,field\.centerLon,field\.displayZoom\)/);
});

test('synthetic XYZ future follows pan and zoom without rebuilding the source',()=>{
  const app=readFileSync(new URL('../rain/app.js',import.meta.url),'utf8');
  assert.match(app,/state\.map\.on\('moveend'/);
  assert.match(app,/Synthetic XYZ radar follows pan\/zoom without rebuilding the source/);
  const start=app.indexOf("state.map.on('moveend'");
  const end=app.indexOf('});',start);
  assert.doesNotMatch(app.slice(start,end+3),/showProjectedRadar\(/);
});

test('viewport projection bitmap cache is keyed by center and zoom',()=>{
  const app=readFileSync(new URL('../rain/app.js',import.meta.url),'utf8');
  assert.match(app,/Number\(field\.centerLat\?\?state\.loc\.lat\)\.toFixed\(3\)/);
  assert.match(app,/Number\(field\.displayZoom\?\?RADAR_ZOOM\)/);
});


test('synthetic radar tile URL is fixed to RainViewer Universal Blue unsmoothed source',()=>{
  const url=buildRainViewerSourceTileUrl({frame:'/v2/radar/abcdef123456',z:5,x:16,y:11});
  assert.equal(url,'https://tilecache.rainviewer.com/v2/radar/abcdef123456/256/5/16/11/2/0_0.png');
  assert.equal(validateRainViewerFramePath('/v2/radar/abcdef123456'),'/v2/radar/abcdef123456');
  assert.throws(()=>validateRainViewerFramePath('https://evil.example/x'),/invalid_frame/);
});

test('synthetic radar decoder keeps only measurable radar pixels transparent elsewhere',()=>{
  const raw=Uint8Array.from([
    0,0,0,0,
    206,192,135,150,
    0,163,224,255,
    130,123,105,73
  ]);
  const out=reconstructRadarTileRgba(raw,2,2,4);
  assert.equal(out.sourceAlphaPixels,3);
  assert.equal(out.wetPixels,2);
  assert.deepEqual(Array.from(out.rgba.filter((_,i)=>i%4===3)),[0,150,255,0]);
});


test('future radar uses one shared georeferenced viewport field instead of per-tile XYZ advection',()=>{
  const app=readFileSync(new URL('../rain/app.js',import.meta.url),'utf8');
  const start=app.indexOf('async function showProjectedRadar');
  const end=app.indexOf('function showRadarOffset',start);
  const fn=app.slice(start,end);
  assert.match(fn,/radarViewportNowcast\(r\)/);
  assert.match(fn,/type:'image',url:imageUrl,coordinates/);
  assert.match(fn,/projectedRadarOpacity\(minutes,true,horizon\)/);
  assert.doesNotMatch(app,/syntheticRadarTileTemplate/);
  assert.doesNotMatch(app,/SYNTHETIC_RADAR_TILE_URL/);
});

test('continuous future radar keeps a single motion field across the whole visible mosaic',()=>{
  const app=readFileSync(new URL('../rain/app.js',import.meta.url),'utf8');
  const start=app.indexOf('async function showProjectedRadar');
  const end=app.indexOf('function showRadarOffset',start);
  const fn=app.slice(start,end);
  assert.match(fn,/const view=await radarViewportNowcast\(r\)/);
  assert.match(fn,/drawLocalRadarProjection\(r,latest,minutes,guidance,token,mode,field\)/);
  assert.match(fn,/coordinates=radarImageCoordinates\(field\.centerLat,field\.centerLon,field\.displayZoom\)/);
  assert.doesNotMatch(fn,/\{z\}/);
  assert.doesNotMatch(fn,/\{x\}/);
  assert.doesNotMatch(fn,/\{y\}/);
});

test('continuous future radar switches to native model when the shared field is no longer reliable',()=>{
  const app=readFileSync(new URL('../rain/app.js',import.meta.url),'utf8');
  const start=app.indexOf('async function showProjectedRadar');
  const end=app.indexOf('function showRadarOffset',start);
  const fn=app.slice(start,end);
  assert.match(fn,/if\(Number\(minutes\)>0&&\(mode==='none'\|\|Number\(minutes\)>horizon\)\)/);
  assert.match(fn,/ensureFutureModelLayer\(minutes,projectedAt\)/);
  assert.match(fn,/fadeOutRadarDisplay\(token,190,minutes\)/);
});
test('moving synthetic echo survives +10 with local flow',()=>{
  const w=96,h=96;
  const field=(ox,oy)=>{
    const mask=new Uint8Array(w*h),rateGrid=new Float32Array(w*h);
    for(let y=oy;y<oy+18;y++)for(let x=ox;x<ox+22;x++){const i=y*w+x;mask[i]=1;rateGrid[i]=6}
    return{mask,rateGrid,width:w,height:h,wetPixels:18*22};
  };
  const fields=[field(20,36),field(23,35),field(26,34),field(29,33)];
  const out=buildSyntheticFutureField(fields,[1000,1600,2200,2800],10,{persistenceMinutes:5});
  assert.equal(out.status,'flow');
  assert.ok(out.field.mask.reduce((s,v)=>s+(v?1:0),0)>100);
  assert.ok(out.flowVectors>=5);
  assert.ok(out.horizon>=10);
});

test('uncertain synthetic future never invents rigid motion',()=>{
  const w=32,h=32,mask=new Uint8Array(w*h),rateGrid=new Float32Array(w*h);
  mask[10*w+10]=1;rateGrid[10*w+10]=2;
  const field={mask,rateGrid,width:w,height:h,wetPixels:1};
  assert.equal(buildSyntheticFutureField([field,field,field],[0,600,1200],4,{persistenceMinutes:5}).status,'short_persistence');
  assert.equal(buildSyntheticFutureField([field,field,field],[0,600,1200],8,{persistenceMinutes:5}).status,'uncertain');
});


test('shared continuous advection crosses horizontal and vertical tile boundaries without artificial cuts',()=>{
  const w=128,h=128,boundary=64;
  const mask=new Uint8Array(w*h),rateGrid=new Float32Array(w*h);
  for(let y=44;y<=84;y++)for(let x=44;x<=84;x++){
    const i=y*w+x;mask[i]=1;rateGrid[i]=6;
  }
  const vectors=[];
  for(const y of [24,64,104])for(const x of [24,64,104]){
    vectors.push({x,y,dx:4+(x-64)/160,dy:3+(y-64)/200,confidence:.92});
  }
  const flow={vectors,confidence:.92,coverage:1};
  const out=projectRadarFieldContinuous({mask,rateGrid,width:w,height:h},flow,10,{sourceStepMinutes:10});
  let verticalWet=0,horizontalWet=0;
  for(let y=48;y<=90;y++)verticalWet+=out.mask[y*w+boundary]?1:0;
  for(let x=48;x<=90;x++)horizontalWet+=out.mask[boundary*w+x]?1:0;
  assert.ok(verticalWet>20,'vertical logical tile boundary must stay wet through the crossing echo');
  assert.ok(horizontalWet>20,'horizontal logical tile boundary must stay wet through the crossing echo');
  for(let y=52;y<=84;y++){
    assert.ok(out.mask[y*w+boundary-1]||out.mask[y*w+boundary]||out.mask[y*w+boundary+1],'no vertical seam gap');
  }
  for(let x=52;x<=84;x++){
    assert.ok(out.mask[(boundary-1)*w+x]||out.mask[boundary*w+x]||out.mask[(boundary+1)*w+x],'no horizontal seam gap');
  }
});

test('shared flow interpolation stays continuous across a former tile edge even when source vectors differ',()=>{
  const flow={vectors:[
    {x:40,y:40,dx:2,dy:1,confidence:.9},
    {x:88,y:40,dx:7,dy:3,confidence:.9},
    {x:40,y:88,dx:3,dy:2,confidence:.9},
    {x:88,y:88,dx:8,dy:4,confidence:.9}
  ],confidence:.9,coverage:1};
  const left=flowVectorAt(flow,63,64),right=flowVectorAt(flow,65,64);
  assert.ok(Math.abs(left.dx-right.dx)<1);
  assert.ok(Math.abs(left.dy-right.dy)<1);
});

test('lightning verifies in background and first tap does not force revalidation',()=>{
  const app=readFileSync(new URL('../rain/app.js',import.meta.url),'utf8');
  assert.match(app,/verifyLightningSource\(false\);/);
  const start=app.indexOf('async function toggleLightning');
  const end=app.indexOf('function removeRadarLayer',start);
  const fn=app.slice(start,end);
  assert.match(fn,/await verifyLightningSource\(false\)/);
  assert.doesNotMatch(fn,/lightningLoaded\.clear\(\)/);
  assert.doesNotMatch(fn,/verifyLightningSource\(true\)/);
});


test('future visual keeps only one persistent source around the handoff',()=>{
  assert.deepEqual(hybridFutureBlend(15,15),{radarOpacity:.76,modelOpacity:0,mode:'radar',handoffMinutes:15});
  assert.deepEqual(hybridFutureBlend(16,15),{radarOpacity:0,modelOpacity:.78,mode:'model',handoffMinutes:15});
  assert.equal(hybridFutureBlend(24,30).mode,'radar');
  assert.equal(hybridFutureBlend(31,30).mode,'model');
});

test('spatial model time interpolates continuously between forecast steps',()=>{
  const times=['2026-10-08T06:00Z','2026-10-08T07:00Z','2026-10-08T08:00Z'];
  assert.equal(selectSpatialForecastTimeIndex(times,Date.parse('2026-10-08T06:10Z')),1);
  const blend=selectSpatialForecastTimeBlend(times,Date.parse('2026-10-08T06:30Z'));
  assert.equal(blend.fromIndex,0);
  assert.equal(blend.toIndex,1);
  assert.equal(blend.fraction,.5);
  const exact=selectSpatialForecastTimeBlend(times,Date.parse('2026-10-08T07:00Z'));
  assert.equal(exact.toIndex,1);
  assert.equal(exact.fraction,1);
});

test('lightning behavior remains on the verified preload path',()=>{
  const app=readFileSync(new URL('../rain/app.js',import.meta.url),'utf8');
  assert.match(app,/verifyLightningSource\(false\);\s*warmFutureModelMap\(\);/);
  assert.match(app,/const LIGHTNING_WMS_LAYERS=\[/);
  assert.match(app,/dwd:Accumulated_Flash_Geometry/);
  assert.match(app,/dwd:NCEW_EU/);
});



test('radar slider keeps fixed AHORA and hides reliability when no future horizon exists',()=>{
  const html=readFileSync(new URL('../rain/index.html',import.meta.url),'utf8');
  const app=readFileSync(new URL('../rain/app.js',import.meta.url),'utf8');
  assert.match(html,/id="radarNowMarker"/);
  assert.match(html,/<em>AHORA<\/em>/);
  assert.match(html,/\.radarNowMarker\{z-index:3/);
  assert.match(app,/function updateRadarReferenceMarkers\(/);
  assert.match(app,/hasReliableFuture=reliable>=10/);
  assert.match(app,/\$\('radarNowMarker'\)\.style\.display=''/);
  assert.match(app,/\$\('radarReliableMarker'\)\.style\.display='none'/);
  assert.match(app,/sin horizonte fiable/);
});

test('future radar swaps with double buffer and waits for the continuous incoming image',()=>{
  const app=readFileSync(new URL('../rain/app.js',import.meta.url),'utf8');
  assert.match(app,/raineta-radar-projection-a/);
  assert.match(app,/raineta-radar-projection-b/);
  assert.match(app,/function animateRadarSwap\(/);
  assert.match(app,/requestAnimationFrame\(step\)/);
  const start=app.indexOf('async function showProjectedRadar');
  const end=app.indexOf('function showRadarOffset',start);
  const fn=app.slice(start,end);
  assert.match(fn,/await waitForRasterSources\(\[incoming\],token,2200\)/);
  assert.match(fn,/animateRadarSwap\(incoming,opacity,token,170,minutes\)/);
});

test('model-only future waits for native model tiles before fading radar away',()=>{
  const app=readFileSync(new URL('../rain/app.js',import.meta.url),'utf8');
  const start=app.indexOf('async function showProjectedRadar');
  const end=app.indexOf('function showRadarOffset',start);
  const fn=app.slice(start,end);
  assert.match(fn,/Number\(minutes\)>0&&\(mode==='none'\|\|Number\(minutes\)>horizon\)/);
  assert.match(fn,/const info=await ensureFutureModelLayer\(minutes,projectedAt\)/);
  assert.match(fn,/await waitForRasterSources\(info\.layerIds,token,4500\)/);
  assert.match(fn,/fadeOutRadarDisplay\(token,190,minutes\)/);
});
test('future model uses native Open-Meteo ICON frames without custom warping',()=>{
  const app=readFileSync(new URL('../rain/app.js',import.meta.url),'utf8');
  assert.match(app,/maplibregl\.addProtocol\('om',module\.omProtocol\)/);
  assert.match(app,/const url='om:\/\/'\+OPENMETEO_SPATIAL_LAYER\+'\?time_step=valid_times_'\+frame\.index/);
  assert.doesNotMatch(app,/raineta-model:\/\//);
  assert.doesNotMatch(app,/estimateModelTileLocalFlow/);
  assert.doesNotMatch(app,/modelLocalPatchDisplacement/);
  assert.doesNotMatch(app,/const patch=48/);
});

test('model display reports the actual native frame time',()=>{
  const app=readFileSync(new URL('../rain/app.js',import.meta.url),'utf8');
  assert.match(app,/function nativeModelFrame\(projectedAt\)/);
  assert.match(app,/PREVISIÓN MODELO · frame /);
  assert.match(app,/ICON-EU · frame nativo /);
  assert.match(app,/sin deformación ni movimiento inventado/);
});

test('model playback advances between native valid times instead of fake minute frames',()=>{
  const app=readFileSync(new URL('../rain/app.js',import.meta.url),'utf8');
  assert.match(app,/function nextNativeModelOffset\(current\)/);
  assert.match(app,/function previousNativeModelOffset\(current\)/);
  assert.match(app,/current>=visualModelHandoffMinutes\(\)\s*\?nextNativeModelOffset\(current\)/);
  assert.match(app,/current>visualModelHandoffMinutes\(\)\)next=previousNativeModelOffset\(current\)/);
});

test('future playback waits for a painted frame instead of racing at 100 ms',()=>{
  const app=readFileSync(new URL('../rain/app.js',import.meta.url),'utf8');
  assert.doesNotMatch(app,/RADAR_FUTURE_TICK_MS=100/);
  assert.match(app,/async function waitForRadarDisplayed\(offset,timeoutMs=RADAR_FRAME_READY_TIMEOUT_MS\)/);
  assert.match(app,/const painted=await waitForRadarDisplayed\(next\)/);
  assert.match(app,/state\.radarDisplayedOffset=value/);
  assert.match(app,/markRadarDisplayed\(displayOffset,token\)/);
});

test('arrival playback is also frame-ready driven',()=>{
  const app=readFileSync(new URL('../rain/app.js',import.meta.url),'utf8');
  const start=app.indexOf('function playRadarUntilRain');
  const end=app.indexOf('function renderRadar',start);
  const fn=app.slice(start,end);
  assert.match(fn,/const tick=async\(\)=>/);
  assert.match(fn,/await waitForRadarDisplayed\(next\)/);
  assert.doesNotMatch(fn,/setInterval\(/);
  assert.doesNotMatch(fn,/tickMs=100/);
});

test('returning to observed radar invalidates pending future renders',()=>{
  const app=readFileSync(new URL('../rain/app.js',import.meta.url),'utf8');
  const start=app.indexOf('function showObservedRadar');
  const end=app.indexOf('function projectedRadarOpacity',start);
  const fn=app.slice(start,end);
  assert.match(fn,/const token=\+\+state\.radarProjectionToken/);
  assert.match(fn,/markRadarDisplayed\(offsetMinutes,token\)/);
});



test('radar to model handoff follows the same displayed spatial reliability horizon',()=>{
  const app=readFileSync(new URL('../rain/app.js',import.meta.url),'utf8');
  assert.match(app,/function displayedRadarReliableHorizon\(\)/);
  assert.match(app,/if\(guidance\)return guidance\.ok\?Math\.max\(0,Math\.round\(Number\(guidance\.horizon\)\|\|0\)\):0/);
  assert.match(app,/function visualModelHandoffMinutes\(\)/);
  assert.match(app,/Math\.min\(60,displayedRadarReliableHorizon\(\)\)/);
  const start=app.indexOf('async function showProjectedRadar');
  const end=app.indexOf('function showRadarOffset',start);
  const fn=app.slice(start,end);
  assert.doesNotMatch(fn,/RADAR \+ MODELO/);
});

test('visual radar handoff has no forced minimum when the continuous field is unreliable',()=>{
  assert.deepEqual(hybridFutureBlend(1,0),{radarOpacity:0,modelOpacity:.78,mode:'model',handoffMinutes:0});
  assert.deepEqual(hybridFutureBlend(20,30),{radarOpacity:.76,modelOpacity:0,mode:'radar',handoffMinutes:30});
  assert.deepEqual(hybridFutureBlend(31,30),{radarOpacity:0,modelOpacity:.78,mode:'model',handoffMinutes:30});
});
