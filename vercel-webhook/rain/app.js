import {aggregateEnsembleModel,buildConsensus,compactTimeline,detectQuarterHourEvents,detectRainEvents,chooseNextEvent,median,classifyRainHour} from './core.js';
import {estimateTranslation,combineMotionEstimates,projectPointSeries,detectNowcastEvent,nowcastUncertaintyMinutes,wetNear} from './radar-core.js';

const DET_MODELS=[
  {id:'ecmwf_ifs',label:'ECMWF IFS 9 km',family:'ECMWF',weight:1.32},
  {id:'ecmwf_aifs025',label:'ECMWF AIFS',family:'ECMWF',weight:1.05},
  {id:'icon_seamless',label:'DWD ICON',family:'DWD',weight:1.10},
  {id:'gfs_seamless',label:'NOAA GFS',family:'NOAA',weight:.90},
  {id:'meteofrance_seamless',label:'Météo-France',family:'METEOFRANCE',weight:1.00},
  {id:'gem_seamless',label:'CMC GEM',family:'CMC',weight:.75},
  {id:'ukmo_global_deterministic_10km',label:'UKMO Global 10 km',family:'UKMO',weight:1.02},
];
const ENS_MODELS=[
  {id:'ecmwf_ifs_europe_ensemble',label:'ECMWF ENS Europe 9 km',family:'ECMWF',weight:1.30},
  {id:'ecmwf_aifs025_ensemble',label:'ECMWF AIFS ENS',family:'ECMWF',weight:1.00},
  {id:'dwd_icon_eu_eps',label:'ICON-EU EPS',family:'DWD',weight:1.10},
  {id:'ncep_gefs025',label:'NOAA GEFS',family:'NOAA',weight:.90},
  {id:'ukmo_global_ensemble_20km',label:'UKMO MOGREPS-G',family:'UKMO',weight:.95},
  {id:'gem_global_ensemble',label:'CMC GEPS',family:'CMC',weight:.82},
  {id:'bom_access_global_ensemble',label:'BOM ACCESS-GE',family:'BOM',weight:.72},
  {id:'google_weathernext2_ensemble',label:'Google WeatherNext 2',family:'GOOGLE',weight:.92},
];
const FORECAST_TTL=20*60_000;
const RADAR_REFRESH_MS=5*60_000;
const RADAR_FRAMES=5;
const RADAR_ZOOM=7;
const ANALYSIS_SIZE=97;
const MAX_SHIFT=12;

const $=id=>document.getElementById(id);
function readLocal(key,fallback){
  try{const value=JSON.parse(localStorage.getItem(key)||'null');return value??fallback}catch{return fallback}
}
const initialLoc=readLocal('raineta.loc',{name:'Madrid',lat:40.4168,lon:-3.7038,isCurrent:false});
const state={
  loc:{...initialLoc,isCurrent:Boolean(initialLoc.isCurrent)},
  currentLocation:readLocal('raineta.currentLocation',null),
  savedLocations:readLocal('raineta.locations',[]),
  feedback:readLocal('raineta.feedback',[]),
  data:null,nowcast:null,map:null,mapLoaded:false,marker:null,radarLayer:null,frames:[],frameIndex:0,playTimer:null,loading:false,radarLoading:false,lastRadarRefresh:0,lastCompletedAt:null,view:'detail',locationsLoading:false,version:'0.9.0',renameTarget:null,selectedHourIndex:null,radarOffset:0
};

function iso(v){
  if(Number.isFinite(Number(v))) return new Date(Number(v)*1000).toISOString();
  const t=Date.parse(v);return Number.isFinite(t)?new Date(t).toISOString():String(v);
}
function fmtDateTime(v){
  return new Intl.DateTimeFormat('es-ES',{weekday:'short',hour:'2-digit',minute:'2-digit'}).format(new Date(v));
}
function fmtTime(v){return new Intl.DateTimeFormat('es-ES',{hour:'2-digit',minute:'2-digit'}).format(new Date(v))}
function fmtTimeSeconds(v){return new Intl.DateTimeFormat('es-ES',{hour:'2-digit',minute:'2-digit',second:'2-digit'}).format(new Date(v))}
function samePlace(a,b,tolerance=.003){
  return Boolean(a&&b&&Math.abs(Number(a.lat)-Number(b.lat))<=tolerance&&Math.abs(Number(a.lon)-Number(b.lon))<=tolerance);
}
function locationKey(loc){return Number(loc.lat).toFixed(4)+','+Number(loc.lon).toFixed(4)}
function persistLocations(){localStorage.setItem('raineta.locations',JSON.stringify(state.savedLocations))}
function persistFeedback(){localStorage.setItem('raineta.feedback',JSON.stringify(state.feedback.slice(-120)))}
function isSaved(loc=state.loc){return state.savedLocations.some(x=>samePlace(x,loc,.0015))}
function recentFeedbackFor(loc,maxAgeMinutes=12){
  if(!loc)return null;
  const cutoff=Date.now()-maxAgeMinutes*60_000;
  return [...state.feedback].reverse().find(x=>x.time>=cutoff&&samePlace(x,loc,.0015))||null;
}
function recentTruthFor(loc,maxAgeMinutes=12){
  const item=recentFeedbackFor(loc,maxAgeMinutes);
  return item?Boolean(item.raining):null;
}
function currentTruth(maxAgeMinutes=12){
  if(!state.currentLocation||!samePlace(state.loc,state.currentLocation))return null;
  return recentTruthFor(state.currentLocation,maxAgeMinutes);
}
function calibratedRadarThreshold(){
  if(!state.currentLocation)return .22;
  const rows=state.feedback.filter(x=>samePlace(x,state.currentLocation,.0015)&&Number.isFinite(x.radarWetFraction)).slice(-40);
  if(rows.length<5)return .22;
  let best={threshold:.22,score:-1};
  for(let threshold=.08;threshold<=.72;threshold+=.04){
    let correct=0;
    for(const row of rows)if((row.radarWetFraction>=threshold)===Boolean(row.raining))correct++;
    const score=correct/rows.length-Math.abs(threshold-.22)*.03;
    if(score>best.score)best={threshold,score};
  }
  return best.threshold;
}
function until(v){
  const m=Math.round((new Date(v)-Date.now())/60000);
  if(m<=0)return'ahora';
  if(m<60)return m+' min';
  const h=Math.floor(m/60),r=m%60;return h+' h'+(r?' '+r+' min':'');
}
function durationText(start,end){
  if(!start||!end)return'—';
  const m=Math.max(0,Math.round((Date.parse(end)-Date.parse(start))/60000));
  if(m<60)return m+' min';
  const h=Math.floor(m/60),r=m%60;return h+' h'+(r?' '+r+' min':'');
}
function pct(v){return Math.round(Math.max(0,Math.min(1,Number(v)||0))*100)}
function probabilityBand(value){
  const p=Number(value)||0;
  return p>=.85?'p85':p>=.70?'p70':p>=.50?'p50':'p35';
}
const RADAR_PALETTE=[
  {dbz:0,rgba:[130,123,105,73]},
  {dbz:5,rgba:[146,136,113,100]},
  {dbz:10,rgba:[206,192,135,150]},
  {dbz:15,rgba:[136,221,238,255]},
  {dbz:20,rgba:[0,163,224,255]},
  {dbz:25,rgba:[0,119,170,255]},
  {dbz:30,rgba:[0,85,136,255]},
  {dbz:35,rgba:[255,238,0,255]},
  {dbz:40,rgba:[255,170,0,255]},
  {dbz:45,rgba:[255,68,0,255]},
  {dbz:50,rgba:[193,0,0,255]},
  {dbz:55,rgba:[255,170,255,255]},
  {dbz:60,rgba:[255,119,255,255]},
  {dbz:65,rgba:[255,255,255,255]}
];
function radarDbzFromRgba(r,g,b,a){
  if(a<45)return null;
  let best=null,bestDist=Infinity;
  for(const entry of RADAR_PALETTE){
    const [er,eg,eb,ea]=entry.rgba;
    const dist=(r-er)**2+(g-eg)**2+(b-eb)**2+((a-ea)*.65)**2;
    if(dist<bestDist){bestDist=dist;best=entry.dbz}
  }
  return bestDist<7000?best:null;
}
function dbzToRainRate(dbz){
  if(!Number.isFinite(dbz)||dbz<10)return 0;
  const z=10**(dbz/10);
  return Math.min(80,(z/200)**(1/1.6));
}
function cacheKey(){return 'raineta.forecast.'+state.loc.lat.toFixed(2)+','+state.loc.lon.toFixed(2)}
function timeoutFetch(url,ms=9000,opts={}){
  const c=new AbortController(),t=setTimeout(()=>c.abort(),ms);
  return fetch(url,{...opts,signal:c.signal}).finally(()=>clearTimeout(t));
}
async function fetchJson(url,ms=9000){
  const r=await timeoutFetch(url,ms,{headers:{Accept:'application/json'}});
  if(!r.ok)throw new Error('HTTP '+r.status);
  return r.json();
}
async function pool(items,worker,size=3){
  const out=[];
  for(let i=0;i<items.length;i+=size){
    const batch=items.slice(i,i+size);
    out.push(...await Promise.allSettled(batch.map(worker)));
    if(i+size<items.length)await new Promise(r=>setTimeout(r,120));
  }
  return out;
}
function normalizeHourly(hourly={}){
  return {...hourly,time:Array.isArray(hourly.time)?hourly.time.map(iso):[]};
}
async function fetchDet(model){
  const p=new URLSearchParams({
    latitude:String(state.loc.lat),longitude:String(state.loc.lon),hourly:'precipitation',
    forecast_hours:'73',timeformat:'unixtime',timezone:'GMT',models:model.id
  });
  const d=await fetchJson('https://api.open-meteo.com/v1/forecast?'+p,8500);
  const h=normalizeHourly(d.hourly||{});
  return {...model,rows:(h.time||[]).map((time,i)=>({time,precipitation:Number(h.precipitation?.[i])||0}))};
}
async function fetchEns(model){
  const p=new URLSearchParams({
    latitude:String(state.loc.lat),longitude:String(state.loc.lon),hourly:'precipitation',
    forecast_hours:'73',timeformat:'unixtime',timezone:'GMT',models:model.id
  });
  const d=await fetchJson('https://ensemble-api.open-meteo.com/v1/ensemble?'+p,10500);
  const a=aggregateEnsembleModel(normalizeHourly(d.hourly||{}));
  if(!a)throw new Error('sin miembros');
  return {...model,memberCount:a.memberCount,rows:a.rows};
}
async function fetchQuarterHour(){
  const p=new URLSearchParams({
    latitude:String(state.loc.lat),longitude:String(state.loc.lon),
    current:'temperature_2m,precipitation,rain,showers,weather_code,cloud_cover',
    minutely_15:'precipitation',forecast_minutely_15:'32',
    hourly:'temperature_2m,cloud_cover,snowfall,weather_code,precipitation_probability',
    forecast_hours:'73',
    timeformat:'unixtime',timezone:'GMT'
  });
  const d=await fetchJson('https://api.open-meteo.com/v1/forecast?'+p,8000);
  const h=d.minutely_15||{},times=(h.time||[]).map(iso),prec=(h.precipitation||[]).map(v=>Number(v)||0);
  const hourly=d.hourly||{};
  return {
    current:{
      time:d.current?.time?iso(d.current.time):null,
      temperature:Number(d.current?.temperature_2m),
      precipitation:Number(d.current?.precipitation)||0,
      rain:Number(d.current?.rain)||0,
      showers:Number(d.current?.showers)||0,
      weatherCode:Number(d.current?.weather_code),
      cloudCover:Number(d.current?.cloud_cover)
    },
    time:times,precipitation:prec,events:detectQuarterHourEvents(times,prec),
    hourly:{
      time:(hourly.time||[]).map(iso),
      temperature:(hourly.temperature_2m||[]).map(Number),
      cloudCover:(hourly.cloud_cover||[]).map(Number),
      snowfall:(hourly.snowfall||[]).map(Number),
      weatherCode:(hourly.weather_code||[]).map(Number),
      precipitationProbability:(hourly.precipitation_probability||[]).map(Number)
    },
    interpolated:true
  };
}
async function fetchRadarMeta(){
  const d=await fetchJson('https://api.rainviewer.com/public/weather-maps.json',6000);
  return {
    provider:'RainViewer',host:d.host,generated:Number(d.generated)||null,
    frames:(d.radar?.past||[]).slice(-12).map(f=>({time:Number(f.time),path:f.path})),
    attribution:'Weather data by RainViewer'
  };
}
async function fetchOperaMeta(){
  const p=new URLSearchParams({lat:String(state.loc.lat),lon:String(state.loc.lon)});
  const r=await fetch('/api/rain-opera?'+p);
  if(!r.ok)throw new Error('OPERA HTTP '+r.status);
  return r.json();
}
function sourceStatus(defs,settled){
  return defs.map((m,i)=>({id:m.id,label:m.label,ok:settled[i]?.status==='fulfilled',members:settled[i]?.status==='fulfilled'?(settled[i].value.memberCount||null):null,error:settled[i]?.status==='rejected'?String(settled[i].reason?.message||settled[i].reason):null}));
}
async function loadForecast(force=false){
  const k=cacheKey();
  if(!force){
    try{
      const c=JSON.parse(localStorage.getItem(k)||'null');
      if(c&&Date.now()-c.savedAt<FORECAST_TTL&&c.data){return {...c.data,cacheAgeMs:Date.now()-c.savedAt}}
    }catch{}
  }
  const [det,ens,qh,radar,opera]=await Promise.all([
    pool(DET_MODELS,fetchDet,3),pool(ENS_MODELS,fetchEns,2),
    Promise.allSettled([fetchQuarterHour()]),Promise.allSettled([fetchRadarMeta()]),Promise.allSettled([fetchOperaMeta()])
  ]);
  const deterministic=det.filter(x=>x.status==='fulfilled').map(x=>x.value);
  const ensembles=ens.filter(x=>x.status==='fulfilled').map(x=>x.value);
  const quarterHour=qh[0]?.status==='fulfilled'?qh[0].value:null;
  const radarMeta=radar[0]?.status==='fulfilled'?radar[0].value:null;
  const operaMeta=opera[0]?.status==='fulfilled'?opera[0].value:null;
  if(!deterministic.length&&!ensembles.length&&!quarterHour)throw new Error('No responde ninguna fuente de previsión');
  const now=Date.now(),end=now+72*3600_000;
  const consensus=buildConsensus({deterministic,ensembles,nowMs:now}).filter(r=>{
    const t=Date.parse(r.time);return t>=now-3600_000&&t<=end;
  });
  const events=detectRainEvents(consensus);
  const data={
    generatedAt:new Date().toISOString(),
    location:{...state.loc},
    timeline:compactTimeline(consensus,73).map(row=>{
      const h=quarterHour?.hourly||{},idx=(h.time||[]).indexOf(row.time);
      return idx>=0?{
        ...row,
        temperature:Number(h.temperature?.[idx]),
        cloudCover:Number(h.cloudCover?.[idx]),
        snowfall:Number(h.snowfall?.[idx])||0,
        weatherCode:Number(h.weatherCode?.[idx]),
        providerProbability:Number(h.precipitationProbability?.[idx])
      }:row;
    }),
    events,
    nextEvent:chooseNextEvent(events,now),
    quarterHour,
    radar:radarMeta,
    opera:operaMeta,
    sources:{
      deterministic:sourceStatus(DET_MODELS,det),
      ensembles:sourceStatus(ENS_MODELS,ens),
      quarterHour:Boolean(quarterHour),radar:Boolean(radarMeta),opera:Boolean(operaMeta?.ok)
    }
  };
  const all=[...data.sources.deterministic,...data.sources.ensembles];
  data.sources.health={available:all.filter(x=>x.ok).length+(quarterHour?1:0)+(radarMeta?1:0)+(operaMeta?.ok?1:0),total:all.length+3};
  try{localStorage.setItem(k,JSON.stringify({savedAt:Date.now(),data}))}catch{}
  return data;
}

function radarTileUrl(meta,frame,size=512,zoom=RADAR_ZOOM){
  return meta.host+frame.path+'/'+size+'/'+zoom+'/'+state.loc.lat+'/'+state.loc.lon+'/2/0_0.png';
}
async function imageMask(url){
  const r=await timeoutFetch(url,8500,{mode:'cors',cache:'no-store'});
  if(!r.ok)throw new Error('radar tile '+r.status);
  const blob=await r.blob();
  let bitmap;
  if('createImageBitmap'in window)bitmap=await createImageBitmap(blob);
  else{
    bitmap=await new Promise((resolve,reject)=>{
      const im=new Image();im.crossOrigin='anonymous';const u=URL.createObjectURL(blob);
      im.onload=()=>{URL.revokeObjectURL(u);resolve(im)};im.onerror=e=>{URL.revokeObjectURL(u);reject(e)};im.src=u;
    });
  }
  const canvas=document.createElement('canvas');canvas.width=ANALYSIS_SIZE;canvas.height=ANALYSIS_SIZE;
  const ctx=canvas.getContext('2d',{willReadFrequently:true});ctx.clearRect(0,0,ANALYSIS_SIZE,ANALYSIS_SIZE);
  ctx.imageSmoothingEnabled=false;
  ctx.drawImage(bitmap,0,0,ANALYSIS_SIZE,ANALYSIS_SIZE);
  if(bitmap.close)bitmap.close();
  const d=ctx.getImageData(0,0,ANALYSIS_SIZE,ANALYSIS_SIZE).data,mask=new Uint8Array(ANALYSIS_SIZE*ANALYSIS_SIZE),rateGrid=new Float32Array(ANALYSIS_SIZE*ANALYSIS_SIZE);
  let wet=0;
  for(let i=0,p=0;i<mask.length;i++,p+=4){
    const dbz=radarDbzFromRgba(d[p],d[p+1],d[p+2],d[p+3]);
    const rate=dbzToRainRate(dbz);
    const v=Number.isFinite(dbz)&&dbz>=10?1:0;
    mask[i]=v;rateGrid[i]=rate;wet+=v;
  }
  const density=wet/mask.length;
  if(density>.90)throw new Error('radar mask opaca');
  return{mask,rateGrid,width:ANALYSIS_SIZE,height:ANALYSIS_SIZE,density};
}
function frameStep(frames){
  const d=[];for(let i=1;i<frames.length;i++){const v=(frames[i].time-frames[i-1].time)/60;if(v>0&&v<=30)d.push(v)}
  return median(d)||10;
}
function radarGeo(motion,lat,step){
  const tilePxPerMaskPx=512/ANALYSIS_SIZE;
  const kmPerTilePx=156543.03392*Math.cos(lat*Math.PI/180)/(2**RADAR_ZOOM)/1000;
  const kmPerMaskPx=kmPerTilePx*tilePxPerMaskPx,h=Math.max(1/60,step/60);
  const east=motion.dx*kmPerMaskPx,north=-motion.dy*kmPerMaskPx;
  return{speedKmh:Math.hypot(east,north)/h,bearingDegrees:(Math.atan2(east,north)*180/Math.PI+360)%360};
}
async function computeNowcast(meta){
  if(!meta?.host||!meta.frames?.length)return{status:'no_radar',confidence:0,event:null};
  const frames=meta.frames.slice(-RADAR_FRAMES);
  if(frames.length<3)return{status:'insufficient_frames',confidence:0,event:null};
  const settled=await Promise.allSettled(frames.map(async f=>({...await imageMask(radarTileUrl(meta,f)),time:f.time,path:f.path})));
  const masks=settled.filter(x=>x.status==='fulfilled').map(x=>x.value).sort((a,b)=>a.time-b.time);
  if(masks.length<3)return{status:'insufficient_radar_data',confidence:0,event:null,decodedFrames:masks.length};
  const estimates=[];
  for(let i=1;i<masks.length;i++){
    const m=estimateTranslation(masks[i-1].mask,masks[i].mask,ANALYSIS_SIZE,ANALYSIS_SIZE,{maxShift:MAX_SHIFT});
    if(m)estimates.push(m);
  }
  const motion=combineMotionEstimates(estimates),latest=masks.at(-1),step=frameStep(masks);
  const center=(ANALYSIS_SIZE-1)/2,current=wetNear(latest.mask,ANALYSIS_SIZE,ANALYSIS_SIZE,center,center,0);
  const currentRadarRate=latest.rateGrid?.[Math.round(center)*ANALYSIS_SIZE+Math.round(center)]||0;
  const base={status:'motion_uncertain',confidence:motion?.confidence||0,event:null,rainingNow:current>=.10,currentWetFraction:current,currentRadarRate,radarTime:new Date(latest.time*1000).toISOString(),decodedFrames:masks.length};
  if(!motion||motion.samples<2||motion.confidence<.22)return base;
  const series=projectPointSeries(latest.mask,ANALYSIS_SIZE,ANALYSIS_SIZE,motion,{horizonMinutes:120,sourceStepMinutes:step,outputStepMinutes:5,radius:0,intensityGrid:latest.rateGrid});
  let event=detectNowcastEvent(series,{enterWetFraction:.10,exitWetFraction:.035,minConsecutive:2,stepMinutes:5});
  if(event){
    const t=latest.time*1000;
    event={...event,start:new Date(t+event.startMinute*60_000).toISOString(),end:new Date(t+event.endMinute*60_000).toISOString(),uncertaintyMinutes:nowcastUncertaintyMinutes(motion.confidence,event.startMinute)};
  }
  return{...base,status:'ok',confidence:motion.confidence,event,motion:{...radarGeo(motion,state.loc.lat,step),samples:motion.samples,consistency:motion.consistency},series};
}

function automaticRainState(){
  const radarWet=Number(state.nowcast?.currentWetFraction);
  const radarOk=state.nowcast?.status==='ok'||state.nowcast?.status==='motion_uncertain';
  const radarRain=radarOk&&Number.isFinite(radarWet)&&radarWet>=calibratedRadarThreshold();
  const modelP=Number(state.data?.quarterHour?.current?.precipitation)||0;
  const modelRain=modelP>=.1;
  const opera=state.data?.opera,operaRate=Number(opera?.sample?.rateMmH),operaQuality=Number(opera?.sample?.quality);
  const operaFresh=opera?.sample?.ok&&Number(opera?.ageMinutes)<=20&&operaQuality>=.5;
  const operaRain=operaFresh&&operaRate>=.05;
  let raining=radarOk?(radarRain||(modelRain&&radarWet>=.08)):modelRain;
  if(operaRain)raining=true;
  const source=operaFresh?(radarOk?'radar+OPERA+modelo':'OPERA+modelo'):(radarOk?'radar+modelo':'modelo');
  return{raining,source,label:raining?'Llueve ahora':'No llueve ahora'};
}
function currentRainState(){
  const truth=currentTruth();
  if(truth!==null)return{raining:truth,source:'feedback',label:truth?'Llueve ahora':'No llueve ahora'};
  return automaticRainState();
}
function formatCountdownMs(ms){
  const total=Math.max(0,Math.floor(ms/1000));
  const h=Math.floor(total/3600),m=Math.floor((total%3600)/60),s=total%60;
  if(h>0)return h+':'+String(m).padStart(2,'0')+':'+String(s).padStart(2,'0');
  return String(m).padStart(2,'0')+':'+String(s).padStart(2,'0');
}
function quarterHourRateAt(timeMs){
  const qh=state.data?.quarterHour;
  if(!qh?.time?.length)return 0;
  const rows=qh.time.map((time,i)=>({time:Date.parse(time),rate:(Number(qh.precipitation?.[i])||0)*4})).filter(x=>Number.isFinite(x.time));
  if(!rows.length)return 0;
  if(timeMs<=rows[0].time)return rows[0].rate;
  if(timeMs>=rows.at(-1).time)return rows.at(-1).rate;
  for(let i=1;i<rows.length;i++){
    if(timeMs<=rows[i].time){
      const a=rows[i-1],b=rows[i],span=Math.max(1,b.time-a.time),f=(timeMs-a.time)/span;
      return a.rate+(b.rate-a.rate)*f;
    }
  }
  return 0;
}
function intensityLabel(rate){
  if(rate<=0.05)return'Seco';
  if(rate<0.5)return'Llovizna';
  if(rate<2.5)return'Lluvia débil';
  if(rate<7.5)return'Lluvia moderada';
  return'Lluvia fuerte';
}
function compassDirection(degrees){
  if(!Number.isFinite(Number(degrees)))return'';
  const dirs=['N','NE','E','SE','S','SO','O','NO'];
  return dirs[Math.round(((Number(degrees)%360)+360)%360/45)%8];
}
function conditionLabel(row={}){
  const code=Number(row.weatherCode),snow=Number(row.snowfall)||0,rate=Number(row.precipitation)||0;
  const signal=classifyRainHour({probability:(Number(row.probability)||0)/100,expectedPrecipitation:rate});
  if(snow>=.02||[71,73,75,77,85,86].includes(code))return snow>=.5?'Nieve intensa':'Nieve';
  if([95,96,99].includes(code))return'Tormenta';
  if(signal==='wet'||(signal==='possible'&&rate>=.05))return intensityLabel(rate);
  if([45,48].includes(code))return'Niebla';
  const cloud=Number(row.cloudCover);
  if(code===0||Number.isFinite(cloud)&&cloud<20)return'Despejado';
  if([1,2].includes(code)||Number.isFinite(cloud)&&cloud<65)return'Parcialmente nublado';
  return'Nublado';
}
function renderSelectedHour(){
  const row=canonicalTimelineRows()?.[state.selectedHourIndex];
  if(!row){state.selectedHourIndex=null;return false}
  $('nowcastBody').hidden=true;$('selectedBody').hidden=false;$('shortBack').hidden=false;
  $('shortState').textContent=conditionLabel(row);
  $('shortDetail').textContent=fmtDateTime(row.time)+' · previsión horaria multimodelo';
  $('shortEtaLabel').textContent='Hora';
  $('shortCountdown').textContent=fmtTime(row.time);
  $('selTemp').textContent=Number.isFinite(row.temperature)?row.temperature.toFixed(1).replace('.',',')+' °C':'—';
  $('selProb').textContent=(Number(row.probability)||0)+'%';
  $('selRate').textContent=(Number(row.precipitation)||0).toFixed(1).replace('.',',')+' mm/h';
  $('selCloud').textContent=Number.isFinite(row.cloudCover)?Math.round(row.cloudCover)+'%':'—';
  $('selSnow').textContent=(Number(row.snowfall)||0)>0?(Number(row.snowfall)||0).toFixed(1).replace('.',',')+' cm':'0';
  $('selConf').textContent=Number.isFinite(row.confidence)?Math.round(row.confidence)+'%':'—';
  return true;
}
function selectTimelineHour(index){
  state.selectedHourIndex=Number(index);
  renderShortNowcast();renderTimeline();
}
function clearSelectedHour(){
  state.selectedHourIndex=null;
  renderShortNowcast();renderTimeline();
}
function shortPoints(){
  const now=Date.now(),n=state.nowcast,qh=state.data?.quarterHour,ev=chooseDisplayEvent(),rainNow=currentRainState().raining;
  const radarBase=Date.parse(n?.radarTime||''),series=Array.isArray(n?.series)?n.series:[];
  const eventStart=ev?Date.parse(ev.start):Infinity,eventEnd=ev?.end?Date.parse(ev.end):eventStart+45*60_000;
  const points=[];
  for(let i=0;i<=24;i++){
    const time=now+i*5*60_000;
    let radar=null;
    if(Number.isFinite(radarBase)&&series.length){
      radar=series.reduce((best,row)=>{
        const d=Math.abs((radarBase+(Number(row.minute)||0)*60_000)-time);
        return !best||d<best.d?{row,d}:best;
      },null)?.row||null;
    }
    const modelRate=quarterHourRateAt(time);
    const radarRate=Number(radar?.radarRate)||0;
    const radarProb=Number(radar?.probability);
    const wetFraction=Number(radar?.wetFraction)||0;
    const horizon=Math.max(0,(time-now)/60_000),radarWeight=Math.max(.42,.9-horizon*.004);
    const inEvent=Boolean(ev)&&time>=eventStart&&time<=eventEnd;
    const radarWet=wetFraction>=.10&&radarRate>=.03;
    let rate=0;
    if(rainNow&&i===0)rate=Math.max(radarRate,modelRate,Number(n?.currentRadarRate)||0);
    else if(inEvent){
      if(radarWet)rate=radarRate*radarWeight+modelRate*(1-radarWeight);
      else rate=modelRate;
    }
    const modelSignal=modelRate<=.05?0:Math.min(.76,.25+Math.log1p(modelRate)*.24);
    let probability=Number.isFinite(radarProb)?Math.max(radarProb,modelSignal*.5):modelSignal;
    if(!inEvent&&!rainNow)probability=0;
    if(inEvent&&rate>0)probability=Math.max(probability,.35);
    if(i===0){
      const truth=currentTruth();
      if(truth===true){probability=1;rate=Math.max(rate,.1)}
      if(truth===false){probability=0;rate=0}
    }
    points.push({
      time,
      probability:Math.max(0,Math.min(1,probability||0)),
      rate:Math.max(0,rate||0),
      radarRate,
      modelRate,
      wetFraction,
      inEvent,
      wet:rainNow&&i===0 ? rate>.03 : inEvent&&(rate>=.03||radarWet)
    });
  }
  return points;
}
function renderShortNowcast(){
  if(state.selectedHourIndex!==null&&renderSelectedHour())return;
  $('nowcastBody').hidden=false;$('selectedBody').hidden=true;$('shortBack').hidden=true;
  const points=shortPoints(),ev=chooseDisplayEvent(),now=Date.now(),rain=currentRainState();
  const near=ev&&Date.parse(ev.start)<=now+120*60_000;
  const wetPoints=points.filter(p=>p.wet);
  const arrivalPoints=wetPoints.slice(0,Math.min(4,wetPoints.length));
  const arrivalRate=arrivalPoints.length
    ? arrivalPoints.reduce((sum,p)=>sum+p.rate,0)/arrivalPoints.length
    : 0;
  const peakRate=wetPoints.length?Math.max(...wetPoints.map(p=>p.rate)):0;
  const labelRate=rain.raining?Math.max(Number(state.nowcast?.currentRadarRate)||0,arrivalRate):arrivalRate;
  $('shortState').textContent=near||rain.raining?intensityLabel(labelRate):'Seco';
  $('shortDetail').textContent=rain.raining
    ? 'Radar: '+labelRate.toFixed(1)+' mm/h ahora · actualización '+fmtTime(state.nowcast?.radarTime||Date.now())
    : near?'Llegada '+fmtTime(ev.start)+' · '+labelRate.toFixed(1)+' mm/h al inicio · pico ~'+peakRate.toFixed(1)+' mm/h':'Sin lluvia probable en las próximas 2 h';
  $('shortEtaLabel').textContent=rain.raining?'Fin estimado':near?'Empieza en':'Próximo cambio';
  $('shortCountdown').textContent=rain.raining
    ? (ev?.end?formatCountdownMs(Date.parse(ev.end)-now):'—')
    : near?formatCountdownMs(Date.parse(ev.start)-now):'>2 h';
  $('shortWindow').textContent=near
    ? fmtTime(ev.start)+(ev.end?'–'+fmtTime(ev.end):'')+(ev.kind==='radar'?' · '+uncertaintyText(ev):'')
    : 'Ventana corta estable';
  const leadMinutes=near?Math.max(0,(Date.parse(ev.start)-now)/60_000):120;
  const shortConfidence=near?calibratedConfidence(ev.confidence,leadMinutes):null;
  $('shortConfidence').textContent=shortConfidence!=null?pct(shortConfidence)+'%':'—';
  renderRadarSkill();

  const maxRate=Math.max(.35,Math.min(12,Math.max(...points.map(p=>p.rate))));
  $('minuteStrip').innerHTML=points.map((p,i)=>{
    const wet=Boolean(p.wet);
    const band=probabilityBand(p.probability);
    const height=wet?Math.max(8,Math.min(100,8+Math.sqrt(Math.min(p.rate,maxRate)/maxRate)*92)):3;
    return '<div class="minuteCol '+(wet?'wet '+band+' ':'')+(i===0?'now':'')+'" title="'+fmtTime(p.time)+' · prob. '+Math.round(p.probability*100)+'% · intensidad '+p.rate.toFixed(1)+' mm/h"><i class="minuteMark" style="height:'+height+'%"></i></div>';
  }).join('');
  const ticks=[];
  for(let i=0;i<=24;i+=6){
    const left=i/24*100;
    ticks.push('<span class="minuteTick" style="left:'+left+'%">'+fmtTime(points[i].time)+'</span>');
  }
  $('minuteAxis').innerHTML=ticks.join('');
}
function updateLiveCountdown(){
  if(!state.data||state.selectedHourIndex!==null)return;
  const ev=chooseDisplayEvent(),now=Date.now(),truth=currentTruth(),rain=currentRainState();
  if(!ev){
    if($('shortCountdown'))$('shortCountdown').textContent='>2 h';
    return;
  }
  if(truth===false&&Date.parse(ev.start)<=now&&(!ev.end||Date.parse(ev.end)>now))return;
  if($('shortCountdown')){
    const near=Date.parse(ev.start)<=now+120*60_000;
    $('shortCountdown').textContent=rain.raining
      ? (ev.end?formatCountdownMs(Date.parse(ev.end)-now):'—')
      : near?formatCountdownMs(Date.parse(ev.start)-now):'>2 h';
  }
}

function radarSkillKey(){return 'raineta.radarSkill.'+locationKey(state.loc)}
function readRadarSkill(){
  return readLocal(radarSkillKey(),{snapshots:[],scores:[]});
}
function writeRadarSkill(data){
  try{localStorage.setItem(radarSkillKey(),JSON.stringify(data))}catch{}
}
function updateRadarValidation(){
  const n=state.nowcast;
  const radarMs=Date.parse(n?.radarTime||'');
  const series=Array.isArray(n?.series)?n.series:[];
  if(!Number.isFinite(radarMs)||!series.length||!Number.isFinite(Number(n?.currentWetFraction)))return;
  const threshold=(state.currentLocation&&samePlace(state.loc,state.currentLocation))?calibratedRadarThreshold():.22;
  const actualWet=Number(n.currentWetFraction)>=threshold;
  const data=readRadarSkill(),targets=[15,30,60,90];
  data.snapshots=Array.isArray(data.snapshots)?data.snapshots:[];
  data.scores=Array.isArray(data.scores)?data.scores:[];
  for(const snap of data.snapshots){
    const age=(radarMs-Number(snap.radarMs))/60_000;
    if(age<8||age>100)continue;
    snap.done=snap.done||{};
    for(const lead of targets){
      if(snap.done[lead]||Math.abs(age-lead)>5.5)continue;
      const point=(snap.points||[]).reduce((best,p)=>{
        const d=Math.abs(Number(p.minute)-lead);
        return !best||d<best.d?{p,d}:best;
      },null)?.p;
      if(!point)continue;
      const predicted=Number(point.probability)>=.30;
      data.scores.push({time:radarMs,lead,correct:predicted===actualWet,predicted,actual:actualWet,probability:Number(point.probability)||0});
      snap.done[lead]=true;
    }
  }
  const duplicate=data.snapshots.some(s=>Number(s.radarMs)===radarMs);
  if(!duplicate){
    data.snapshots.push({
      radarMs,
      points:series.map(p=>({minute:Number(p.minute)||0,probability:Number(p.probability)||0})),
      done:{}
    });
  }
  data.snapshots=data.snapshots.filter(s=>radarMs-Number(s.radarMs)<4*3600_000).slice(-40);
  data.scores=data.scores.slice(-300);
  writeRadarSkill(data);
}
function radarSkillStats(){
  const data=readRadarSkill(),targets=[15,30,60,90],out={};
  for(const lead of targets){
    const rows=(data.scores||[]).filter(x=>Number(x.lead)===lead);
    out[lead]={n:rows.length,accuracy:rows.length?rows.filter(x=>x.correct).length/rows.length:null};
  }
  return out;
}
function calibratedConfidence(raw,leadMinutes){
  const stats=radarSkillStats(),lead=[15,30,60,90].reduce((a,b)=>Math.abs(b-leadMinutes)<Math.abs(a-leadMinutes)?b:a,15);
  const s=stats[lead];
  if(!s||s.n<6||s.accuracy==null)return raw;
  return Math.max(.05,Math.min(.98,.76*raw+.24*s.accuracy));
}
function renderRadarSkill(){
  const stats=radarSkillStats();
  const ready=[15,30,60,90].filter(lead=>stats[lead].n>=3);
  if(!ready.length){
    const n=[15,30,60,90].reduce((sum,lead)=>sum+stats[lead].n,0);
    $('skillText').textContent='Autoevaluación radar: '+(n?'aprendiendo ('+n+' comprobaciones)':'iniciando historial…');
    return;
  }
  $('skillText').textContent='Autoevaluación radar · '+ready.map(lead=>lead+' min '+Math.round(stats[lead].accuracy*100)+'% ('+stats[lead].n+')').join(' · ');
}

function feedbackStats(){
  if(!state.currentLocation)return{count:0,accuracy:null};
  const rows=state.feedback.filter(x=>samePlace(x,state.currentLocation,.0015)).slice(-40);
  if(!rows.length)return{count:0,accuracy:null};
  const evaluable=rows.filter(x=>typeof x.predicted==='boolean');
  const correct=evaluable.filter(x=>x.predicted===Boolean(x.raining)).length;
  return{count:rows.length,accuracy:evaluable.length?correct/evaluable.length:null};
}

function etaRadarHistoryKey(){return 'raineta.radarEtaHistory.'+locationKey(state.loc)}
function readRadarEtaHistory(){return readLocal(etaRadarHistoryKey(),[])}
function writeRadarEtaHistory(rows){
  try{localStorage.setItem(etaRadarHistoryKey(),JSON.stringify(rows.slice(-12)))}catch{}
}
function recordRadarEtaObservation(){
  const n=state.nowcast;
  if(n?.status!=='ok'||!n.event?.start||!n.radarTime)return;
  const radarMs=Date.parse(n.radarTime),startMs=Date.parse(n.event.start),endMs=Date.parse(n.event.end||'');
  if(!Number.isFinite(radarMs)||!Number.isFinite(startMs))return;
  let rows=readRadarEtaHistory().filter(x=>radarMs-Number(x.radarMs)<75*60_000);
  if(rows.some(x=>Number(x.radarMs)===radarMs))return;
  rows.push({
    radarMs,startMs,endMs:Number.isFinite(endMs)?endMs:null,
    confidence:Number(n.confidence)||0,
    uncertainty:Number(n.event.uncertaintyMinutes)||null,
    speed:Number(n.motion?.speedKmh)||null,
    bearing:Number(n.motion?.bearingDegrees)||null
  });
  rows.sort((a,b)=>a.radarMs-b.radarMs);
  writeRadarEtaHistory(rows);
}
function medianNumber(values){
  const a=values.filter(Number.isFinite).sort((x,y)=>x-y);
  if(!a.length)return null;
  const m=Math.floor(a.length/2);
  return a.length%2?a[m]:(a[m-1]+a[m])/2;
}
function stabilizedRadarEvent(){
  const n=state.nowcast,raw=n?.event;
  if(n?.status!=='ok'||!raw?.start)return raw||null;
  const radarMs=Date.parse(n.radarTime||''),rawStart=Date.parse(raw.start),rawEnd=Date.parse(raw.end||'');
  const recent=readRadarEtaHistory()
    .filter(x=>Number.isFinite(Number(x.startMs))&&(!Number.isFinite(radarMs)||radarMs-Number(x.radarMs)<=35*60_000))
    .slice(-3);
  if(!recent.some(x=>Number(x.radarMs)===radarMs)&&Number.isFinite(rawStart)){
    recent.push({radarMs,startMs:rawStart,endMs:Number.isFinite(rawEnd)?rawEnd:null,confidence:Number(n.confidence)||0});
  }
  const rows=recent.slice(-3);
  if(rows.length<2)return {...raw,rawStart:raw.start,stabilizedStart:raw.start,stabilizationSamples:rows.length||1,stabilized:false};
  const stableStartMs=medianNumber(rows.map(x=>Number(x.startMs)));
  const stableEndMs=medianNumber(rows.map(x=>Number(x.endMs)));
  const latestConfidence=Number(n.confidence)||0;
  const lastTwo=rows.slice(-2).map(x=>Number(x.startMs));
  const repeatedShift=lastTwo.length===2&&Math.abs(lastTwo[1]-lastTwo[0])<=8*60_000;
  const trustLatest=latestConfidence>=.80&&repeatedShift;
  const chosenStartMs=trustLatest?rawStart:stableStartMs;
  const chosenEndMs=trustLatest&&Number.isFinite(rawEnd)?rawEnd:stableEndMs;
  const spreadMinutes=Math.max(...rows.map(x=>Math.abs(Number(x.startMs)-chosenStartMs)))/60_000;
  return {
    ...raw,
    start:new Date(chosenStartMs).toISOString(),
    end:Number.isFinite(chosenEndMs)?new Date(chosenEndMs).toISOString():raw.end,
    rawStart:raw.start,
    stabilizedStart:new Date(chosenStartMs).toISOString(),
    stabilizationSamples:rows.length,
    stabilized:Math.abs(rawStart-chosenStartMs)>=60_000,
    stabilizationDeltaMinutes:Math.round((rawStart-chosenStartMs)/60_000),
    uncertaintyMinutes:Math.max(Number(raw.uncertaintyMinutes)||0,Math.round(spreadMinutes))
  };
}
function canonicalEtaHistoryKey(){return 'raineta.canonicalEta.'+locationKey(state.loc)}
function etaTrendText(ev){
  if(!ev?.start)return'';
  const marker=ev.kind==='radar'?(state.nowcast?.radarTime||'radar'):(state.data?.generatedAt||'model');
  let rows=readLocal(canonicalEtaHistoryKey(),[]);
  let current=rows.find(x=>x.marker===marker);
  if(!current){
    current={marker,time:Date.now(),start:Date.parse(ev.start),kind:ev.kind};
    rows.push(current);rows=rows.slice(-10);
    try{localStorage.setItem(canonicalEtaHistoryKey(),JSON.stringify(rows))}catch{}
  }
  const idx=rows.findIndex(x=>x.marker===marker),prev=idx>0?rows[idx-1]:null;
  const parts=[];
  if(ev.kind==='radar'&&ev.event?.stabilizationSamples>=2){
    const s=ev.event;
    if(s.stabilized&&Math.abs(Number(s.stabilizationDeltaMinutes)||0)>=4){
      const sign=s.stabilizationDeltaMinutes>0?'+':'';
      parts.push('ETA estabilizada con '+s.stabilizationSamples+' barridos · último barrido '+sign+s.stabilizationDeltaMinutes+' min frente al consenso reciente');
    }else{
      parts.push('ETA contrastada con '+s.stabilizationSamples+' barridos recientes');
    }
  }
  if(prev&&Number.isFinite(prev.start)){
    const delta=Math.round((Date.parse(ev.start)-Number(prev.start))/60_000);
    if(Math.abs(delta)>=5)parts.push('revisión '+(delta>0?'+':'')+delta+' min desde '+fmtTime(prev.time));
  }
  return parts.join(' · ');
}

function refineWithQuarterHour(event,qh){
  if(!event||!qh?.events?.length)return event;
  const e0=Date.parse(event.start),best=qh.events.map(e=>({...e,dist:Math.abs(Date.parse(e.start)-e0)})).sort((a,b)=>a.dist-b.dist)[0];
  if(!best||best.dist>3*3600_000)return event;
  return{...event,displayStart:best.start,displayEnd:best.end,quarterHourRefined:true};
}
function chooseDisplayEvent(){
  const now=Date.now(),n=state.nowcast,d=state.data,rainNow=currentRainState(),truth=currentTruth();
  if(n?.status==='ok'&&rainNow.raining){
    const stabilized=stabilizedRadarEvent();
    return{kind:truth===true?'observed':'radar',active:true,start:n.radarTime||new Date(now).toISOString(),end:stabilized?.end||n.event?.end||null,confidence:truth===true?1:n.confidence,uncertainty:stabilized?.uncertaintyMinutes||n.event?.uncertaintyMinutes||8,event:stabilized||n.event};
  }
  const radarEvent=stabilizedRadarEvent();
  if(n?.status==='ok'&&radarEvent&&n.confidence>=.30&&Date.parse(radarEvent.start)<=now+125*60_000){
    const active=Date.parse(radarEvent.start)<=now&&truth!==false;
    return{kind:'radar',active,start:radarEvent.start,end:radarEvent.end,confidence:n.confidence,uncertainty:radarEvent.uncertaintyMinutes,event:radarEvent};
  }
  let e=d?.nextEvent||null;if(!e)return null;
  e=refineWithQuarterHour(e,d.quarterHour);
  const start=e.displayStart||e.start,end=e.displayEnd||e.end;
  const active=Date.parse(start)<=now&&Date.parse(end)>now&&truth!==false;
  return{kind:e.quarterHourRefined?'model15':'model',active,start,end,confidence:e.timingConfidence,event:e};
}
function uncertaintyText(ev){
  if(ev.kind==='radar')return'± '+ev.uncertainty+' min';
  const e=ev.event;
  if(e?.startWindow?.earliest&&e?.startWindow?.latest)return fmtTime(e.startWindow.earliest)+'–'+fmtTime(e.startWindow.latest);
  return ev.kind==='model15'?'resolución 15 min':'resolución horaria';
}
function render(){
  const d=state.data,n=state.nowcast,ev=chooseDisplayEvent(),nowState=currentRainState(),truth=currentTruth();
  $('place').textContent=state.loc.name;
  if(!ev){
    $('eta').textContent='Sin lluvia';
    $('summary').textContent='No hay episodio con consenso suficiente en las próximas 72 horas.';
    $('start').textContent='—';$('end').textContent='—';$('conf').textContent='—';$('dur').textContent='—';
  }else{
    if(ev.active){$('heroLabel').textContent='Estado actual';$('eta').innerHTML='Lluvia <span>ahora</span>'}
    else{$('heroLabel').textContent='Próxima lluvia';$('eta').innerHTML='<span>'+fmtTime(ev.start)+'</span>'}
    $('start').textContent=fmtDateTime(ev.start);
    $('end').textContent=ev.end?fmtDateTime(ev.end):'por determinar';
    $('conf').textContent=pct(ev.confidence)+'%';
    $('dur').textContent=durationText(ev.start,ev.end);
    if(truth===false&&Date.parse(ev.start)<=Date.now()&&(!ev.end||Date.parse(ev.end)>Date.now())){
      $('eta').textContent='No llueve ahora';
      $('summary').textContent='Tu observación contradice la señal automática; queda registrada para calibrar la detección local.';
    }else if(ev.kind==='observed'){
      $('summary').textContent='Confirmado por ti en esta ubicación'+(ev.end?' · fin estimado '+fmtTime(ev.end):'')+'.';
    }else if(ev.kind==='radar'){
      const speed=Number(n?.motion?.speedKmh),dir=compassDirection(n?.motion?.bearingDegrees);
      const motion=Number.isFinite(speed)&&speed<220?' · desplazamiento del eco de lluvia '+Math.round(speed)+' km/h'+(dir?' hacia '+dir:''):'';
      if(ev.active){
        $('summary').textContent='Radar: lluvia detectada ahora'+(ev.end?' · fin probable '+fmtTime(ev.end):'')+motion+'.';
      }else{
        $('summary').textContent='Nowcast radar: llegada '+fmtTime(ev.start)+' · '+uncertaintyText(ev)+motion+'.';
      }
    }else if(ev.kind==='model15'){
      $('summary').textContent='Consenso de modelos afinado con guía de 15 min. Esa guía puede ser interpolada en España.';
    }else{
      const w=ev.event?.startWindow;
      $('summary').textContent='Consenso multimodelo'+(w?.earliest?' · ventana de inicio '+fmtTime(w.earliest)+'–'+fmtTime(w.latest):'')+'.';
    }
  }
  const current=d.quarterHour?.current||{};
  $('nowRain').textContent='Ahora: '+nowState.label;
  $('nowRain').classList.toggle('wet',nowState.raining);
  $('tempNow').textContent=Number.isFinite(current.temperature)?current.temperature.toFixed(1).replace('.',',')+' °C':'— °C';
  $('savePlace').textContent=isSaved()?'★ Guardado':'☆ Guardar';
  $('savePlace').hidden=Boolean(state.loc.isCurrent);
  const isCurrent=Boolean(state.currentLocation&&samePlace(state.loc,state.currentLocation));
  $('feedbackCard').hidden=!isCurrent;
  if(isCurrent){
    const stats=feedbackStats(),threshold=Math.round(calibratedRadarThreshold()*100),recent=recentFeedbackFor(state.currentLocation);
    const countLabel=stats.count===1?'1 comprobación':stats.count+' comprobaciones';
    const yesSelected=recent?.raining===true,noSelected=recent?.raining===false;
    $('feedbackYes').classList.toggle('selected',yesSelected);
    $('feedbackNo').classList.toggle('selected',noSelected);
    $('feedbackYes').textContent=(yesSelected?'✓ ':'')+'Sí, está lloviendo';
    $('feedbackNo').textContent=(noSelected?'✓ ':'')+'No llueve';
    $('feedbackStatus').classList.toggle('confirmed',Boolean(recent));
    $('feedbackStatus').textContent=recent
      ? '✓ Registrado a las '+fmtTimeSeconds(recent.time)+': '+(recent.raining?'SÍ LLUEVE':'NO LLUEVE')+'. Se usará para evaluar y calibrar RainETA.'
      : stats.count
        ? 'Registradas '+countLabel+(stats.accuracy!=null?' · acierto provisional '+Math.round(stats.accuracy*100)+'%':'')+' · umbral radar local '+threshold+'%.'
        : 'Tu respuesta queda en este dispositivo y sirve para medir aciertos y calibrar la detección local.';
  }
  $('etaTrend').textContent=etaTrendText(ev);
  const h=d.sources.health;
  $('health').textContent=h.available+' de '+h.total+' capas disponibles · radar '+(n?.status==='ok'?'analizado':n?.status==='motion_uncertain'?'sin movimiento fiable':'degradado');
  $('sourceCount').textContent=h.available+'/'+h.total;
  renderShortNowcast();renderTimeline();renderEvents();renderSources();renderRadar();
  const completed=state.lastCompletedAt||d.generatedAt;
  const radarStamp=n?.radarTime||d.radar?.frames?.at(-1)?.time*1000||null;
  $('updated').textContent='Actualización '+fmtTimeSeconds(completed)+' · modelos '+fmtTime(d.generatedAt)+(radarStamp?' · radar '+fmtTime(radarStamp):'');
  updateLiveCountdown();
}
function canonicalTimelineRows(){
  const base=(state.data?.timeline||[]).map(row=>({...row}));
  if(!base.length||!state.nowcast)return base;
  const now=Date.now(),cutoff=now+120*60_000,points=shortPoints();
  for(const row of base){
    const start=Date.parse(row.time),end=start+60*60_000;
    if(end<=now||start>cutoff)continue;
    const bucket=points.filter(p=>p.time>=Math.max(start,now)&&p.time<Math.min(end,cutoff+5*60_000));
    if(!bucket.length)continue;
    const wet=bucket.filter(p=>p.wet);
    row.canonicalShort=true;
    row.canonicalSignal=wet.length?'wet':'dry';
    row.probability=wet.length?Math.round(Math.max(...wet.map(p=>p.probability))*100):0;
    row.precipitation=wet.length?Math.max(...wet.map(p=>p.rate)):0;
    row.confidence=Math.round((chooseDisplayEvent()?.confidence||0)*100);
  }
  return base;
}
function canonicalEvents(){
  const rows=canonicalTimelineRows();
  const points=rows.map(row=>({
    time:row.time,
    probability:(Number(row.probability)||0)/100,
    expectedPrecipitation:Number(row.precipitation)||0,
    timingConfidence:(Number(row.confidence)||0)/100,
    providerCount:row.independentFamilies||0,
    independentFamilyCount:row.independentFamilies||0
  }));
  return detectRainEvents(points);
}
function eventHourlyRows(event){
  const rows=canonicalTimelineRows();
  const start=Date.parse(event.start),end=Date.parse(event.end);
  return rows.filter(row=>{
    const t=Date.parse(row.time);
    return t<end&&t+60*60_000>start;
  });
}

function renderTimeline(){
  const a=canonicalTimelineRows();
  const maxIntensity=Math.max(.25,Math.min(6,Math.max(...a.map(x=>Number(x.precipitation)||0))));
  $('timeline').innerHTML=a.map((x,index)=>{
    const probability=(Number(x.probability)||0)/100,precipitation=Number(x.precipitation)||0;
    const signal=x.canonicalSignal||classifyRainHour({probability,expectedPrecipitation:precipitation});
    const band=probabilityBand(probability);
    const cls=signal==='wet'?band:signal==='possible'?band+' possible':'dry';
    const height=signal==='wet'
      ?Math.max(8,Math.round(10+Math.sqrt(Math.min(precipitation,maxIntensity)/maxIntensity)*90))
      :signal==='possible'?Math.max(5,Math.min(18,Math.round(5+precipitation/maxIntensity*20))):0;
    const selected=state.selectedHourIndex===index?' selected':'';
    return '<button type="button" class="bar '+cls+selected+'" data-hour-index="'+index+'" style="height:'+height+'%" aria-label="'+fmtDateTime(x.time)+'" title="'+fmtDateTime(x.time)+' · prob. '+x.probability+'% · intensidad '+precipitation.toFixed(1)+' mm/h"></button>';
  }).join('');
  $('timeline').querySelectorAll('[data-hour-index]').forEach(el=>el.onclick=()=>selectTimelineHour(el.dataset.hourIndex));
  const ticks=[],lines=[];
  for(let i=0;i<a.length;i++){
    const dt=new Date(a[i].time),hour=dt.getHours();
    if(i===0||hour%6===0){
      const left=a.length>1?i/(a.length-1)*100:0;
      const day=(i===0||hour===0)?new Intl.DateTimeFormat('es-ES',{weekday:'short'}).format(dt).replace('.',''):'';
      ticks.push('<span class="tick" style="left:'+left+'%"><b>'+String(hour).padStart(2,'0')+'</b>'+(day?'<span class="tickDay">'+day+'</span>':'')+'</span>');
    }
    if(i>0&&hour===0){
      const left=i/(a.length-1)*100;
      lines.push('<i class="dayLine" style="left:'+left+'%"></i>');
    }
  }
  $('timelineAxis').innerHTML=lines.join('')+ticks.join('');
}

function renderEvents(){
  const now=Date.now();
  const events=canonicalEvents().filter(e=>Date.parse(e.end)>now).slice(0,8);
  $('events').innerHTML=events.map((e,index)=>{
    const dur=Math.max(1,Math.round((Date.parse(e.end)-Date.parse(e.start))/3600_000));
    const total=Number(e.totalExpectedPrecipitation||0),peak=Number(e.maxExpectedPrecipitation||0);
    const avgProb=pct(e.averageProbability??e.peakProbability),maxProb=pct(e.peakProbability);
    const families=e.independentFamilyCount||e.providerCount||0;
    const next=events[index+1],dryHours=next?Math.max(0,(Date.parse(next.start)-Date.parse(e.end))/3600_000):null;
    const after=dryHours!=null&&dryHours>=1?' · después ~'+Math.round(dryHours)+' h secas':'';
    const hourly=eventHourlyRows(e).map(row=>{
      const hour=String(new Date(row.time).getHours()).padStart(2,'0')+' h';
      const label=conditionLabel(row);
      const prob=Math.round(Number(row.probability)||0)+'%';
      const rate=(Number(row.precipitation)||0).toFixed(1).replace('.',',')+' mm/h';
      return '<div class="eventHour"><b>'+hour+'</b><span>'+label+'</span><span class="ehProb">'+prob+'</span><span class="ehRate">'+rate+'</span></div>';
    }).join('');
    return '<div class="event"><div><strong>'+fmtDateTime(e.start)+' → '+fmtTime(e.end)+'</strong>'+
      '<small>'+dur+' h · '+(e.character||'variable')+' · '+total.toFixed(1)+' mm estimados</small>'+
      '<small>pico '+peak.toFixed(1)+' mm/h · prob. media '+avgProb+'% · máx. '+maxProb+'% · '+families+' familias'+after+'</small></div>'+
      '<div class="prob">'+maxProb+'%</div><div class="eventHours">'+hourly+'</div></div>';
  }).join('')||'<div class="status">Sin episodios relevantes.</div>';
}

function renderSources(){
  const list=[
    {label:'EUMETNET OPERA',ok:Boolean(state.data.sources.opera),detail:state.data.opera?.ok
      ? 'RATE '+(state.data.opera.resolutionKm||2)+' km / 5 min · '+fmtTime(state.data.opera.observedAt)+(state.data.opera.sample?.ok?' · '+Number(state.data.opera.sample.rateMmH||0).toFixed(1)+' mm/h':'')
      : 'backend sin compuesto reciente'},
    {label:'Radar RainViewer',ok:Boolean(state.data.radar),detail:state.nowcast?.status==='ok'?'movimiento + intensidad dBZ':state.nowcast?.status||'solo mapa'},
    {label:'Guía 15 min',ok:state.data.sources.quarterHour,detail:'modelo/interpolación'},
    ...state.data.sources.deterministic.map(x=>({label:x.label,ok:x.ok,detail:'determinista'})),
    ...state.data.sources.ensembles.map(x=>({label:x.label,ok:x.ok,detail:x.members?x.members+' miembros':'ensemble'}))
  ];
  $('sources').innerHTML=list.map(x=>'<div class="source"><span>'+x.label+'<small>'+x.detail+'</small></span><i class="'+(x.ok?'ok':'bad')+'">'+(x.ok?'OK':'—')+'</i></div>').join('');
}
function locationGeoJSON(){
  return {type:'FeatureCollection',features:[{type:'Feature',geometry:{type:'Point',coordinates:[state.loc.lon,state.loc.lat]},properties:{}}]};
}
function initMap(){
  if(state.map||!window.maplibregl)return;
  state.map=new maplibregl.Map({
    container:'map',
    style:'https://tiles.openfreemap.org/styles/fiord',
    center:[state.loc.lon,state.loc.lat],
    zoom:7,
    minZoom:4,
    maxZoom:12,
    attributionControl:false
  });
  state.map.addControl(new maplibregl.NavigationControl({showCompass:false}),'bottom-right');
  state.map.addControl(new maplibregl.AttributionControl({compact:true,customAttribution:'© OpenFreeMap · © OpenStreetMap contributors'}));
  state.map.on('load',()=>{
    state.mapLoaded=true;
    state.map.addSource('raineta-location',{type:'geojson',data:locationGeoJSON()});
    state.map.addLayer({
      id:'raineta-location',
      type:'circle',
      source:'raineta-location',
      paint:{
        'circle-radius':6,
        'circle-color':'#4fc6ff',
        'circle-stroke-color':'#ffffff',
        'circle-stroke-width':2
      }
    });
    showRadarOffset(state.radarOffset);
  });
}
function updateMapLocation(){
  if(!state.map||!state.mapLoaded)return;
  state.map.jumpTo({center:[state.loc.lon,state.loc.lat]});
  const src=state.map.getSource('raineta-location');
  if(src?.setData)src.setData(locationGeoJSON());
}
function removeRadarLayer(id){
  if(!state.map||!state.mapLoaded)return;
  if(state.map.getLayer(id))state.map.removeLayer(id);
  if(state.map.getSource(id))state.map.removeSource(id);
}
function clearRadarVisual(){
  removeRadarLayer('raineta-radar');
  removeRadarLayer('raineta-radar-projection');
}
function projectionCoordinates(minutes){
  const motion=state.nowcast?.motion;
  const lat=Number(state.loc.lat),lon=Number(state.loc.lon);
  const speed=Math.max(0,Number(motion?.speedKmh)||0),bearing=(Number(motion?.bearingDegrees)||0)*Math.PI/180;
  const distance=speed*Math.max(0,minutes)/60;
  const north=distance*Math.cos(bearing),east=distance*Math.sin(bearing);
  const shiftedLat=lat+north/111.32;
  const shiftedLon=lon+east/(111.32*Math.max(.25,Math.cos(lat*Math.PI/180)));
  const metresPerPx=156543.03392*Math.cos(lat*Math.PI/180)/(2**RADAR_ZOOM);
  const spanKm=metresPerPx*512/1000;
  const halfLat=spanKm/111.32/2;
  const halfLon=spanKm/(111.32*Math.max(.25,Math.cos(lat*Math.PI/180)))/2;
  return[
    [shiftedLon-halfLon,shiftedLat+halfLat],
    [shiftedLon+halfLon,shiftedLat+halfLat],
    [shiftedLon+halfLon,shiftedLat-halfLat],
    [shiftedLon-halfLon,shiftedLat-halfLat]
  ];
}
function nearestObservedFrame(offsetMinutes){
  const latest=state.frames.at(-1);if(!latest)return null;
  const target=latest.time+Number(offsetMinutes)*60;
  return state.frames.reduce((best,f)=>Math.abs(f.time-target)<Math.abs(best.time-target)?f:best,state.frames[0]);
}
function showObservedRadar(offsetMinutes){
  const r=state.data?.radar,f=nearestObservedFrame(offsetMinutes);if(!r||!f||!state.mapLoaded)return;
  clearRadarVisual();
  state.map.addSource('raineta-radar',{
    type:'raster',
    tiles:[r.host+f.path+'/256/{z}/{x}/{y}/2/1_1.png'],
    tileSize:256,maxzoom:7,attribution:'Weather data by RainViewer'
  });
  const before=state.map.getLayer('raineta-location')?'raineta-location':undefined;
  state.map.addLayer({id:'raineta-radar',type:'raster',source:'raineta-radar',paint:{'raster-opacity':.76,'raster-fade-duration':0}},before);
  const latest=state.frames.at(-1),delta=Math.round((f.time-latest.time)/60);
  $('radarTime').textContent=fmtTime(f.time*1000);
  $('radarPosition').textContent=delta<0?'Observado '+Math.abs(delta)+' min antes · '+fmtTime(f.time*1000):'Último radar observado · '+fmtTime(f.time*1000);
  $('radarMotion').textContent='Imagen observada real de RainViewer. Desliza a la derecha de AHORA para ver la proyección.';
}
function showProjectedRadar(minutes){
  const r=state.data?.radar,latest=state.frames.at(-1),motion=state.nowcast?.motion;
  if(!r||!latest||!state.mapLoaded)return;
  if(!motion||state.nowcast?.status!=='ok'||Number(state.nowcast?.confidence)<.22){
    showObservedRadar(0);
    $('radarPosition').textContent='Proyección no disponible con suficiente fiabilidad';
    $('radarMotion').textContent='Se mantiene el último radar observado hasta que el movimiento del eco sea estable.';
    return;
  }
  clearRadarVisual();
  const url=radarTileUrl(r,latest,512,RADAR_ZOOM);
  state.map.addSource('raineta-radar-projection',{type:'image',url,coordinates:projectionCoordinates(minutes)});
  const before=state.map.getLayer('raineta-location')?'raineta-location':undefined;
  state.map.addLayer({id:'raineta-radar-projection',type:'raster',source:'raineta-radar-projection',paint:{'raster-opacity':.76,'raster-fade-duration':0}},before);
  const speed=Math.round(Number(motion.speedKmh)||0),dir=compassDirection(motion.bearingDegrees);
  $('radarTime').textContent='+'+minutes+' min';
  $('radarPosition').textContent='Proyección +'+minutes+' min · ~'+fmtTime(Date.now()+minutes*60_000);
  $('radarMotion').textContent='Extrapolación del último eco: desplazamiento de la precipitación '+speed+' km/h'+(dir?' hacia '+dir:'')+' · confianza '+pct(state.nowcast.confidence)+'%. No es una observación futura.';
}
function showRadarOffset(offset=state.radarOffset){
  state.radarOffset=Math.max(Number($('frame')?.min)||-90,Math.min(120,Number(offset)||0));
  if($('frame'))$('frame').value=state.radarOffset;
  if(state.radarOffset<=0)showObservedRadar(state.radarOffset);
  else showProjectedRadar(state.radarOffset);
}
function renderRadar(){
  initMap();if(!state.map)return;
  updateMapLocation();
  const r=state.data.radar;if(!r?.frames?.length){$('radarTime').textContent='sin radar';return}
  state.frames=r.frames.slice(-12);
  const latest=state.frames.at(-1),oldest=state.frames[0];
  const availablePast=Math.max(5,Math.round((latest.time-oldest.time)/60/5)*5);
  $('frame').min=String(-availablePast);$('frame').max='120';$('frame').step='5';
  $('radarPastLabel').textContent='−'+availablePast+' min';
  state.radarOffset=Math.max(-availablePast,Math.min(120,state.radarOffset||0));
  $('frame').value=state.radarOffset;
  if(state.mapLoaded)showRadarOffset(state.radarOffset);
}

async function refreshRadar(){
  if(state.radarLoading||!state.data)return;
  state.radarLoading=true;
  try{
    const radar=await fetchRadarMeta();
    const sources={...state.data.sources,radar:true};
    const all=[...(sources.deterministic||[]),...(sources.ensembles||[])];
    sources.health={available:all.filter(x=>x.ok).length+(sources.quarterHour?1:0)+1+(sources.opera?1:0),total:all.length+3};
    state.data={...state.data,radar,sources};
    state.nowcast=await computeNowcast(radar).catch(e=>({status:'radar_analysis_failed',confidence:0,event:null,error:String(e?.message||e)}));
    recordRadarEtaObservation();
    updateRadarValidation();
    state.lastRadarRefresh=Date.now();
    state.lastCompletedAt=new Date().toISOString();
    render();
  }catch(e){
    if(state.nowcast)state.nowcast={...state.nowcast,refreshError:String(e?.message||e)};
  }finally{state.radarLoading=false}
}

async function load(force=false){
  if(state.loading)return;state.loading=true;
  $('eta').textContent='Calculando…';$('summary').textContent='Fusionando radar, modelos y ensembles.';
  try{
    state.data=await loadForecast(force);
    state.nowcast=await computeNowcast(state.data.radar).catch(e=>({status:'radar_analysis_failed',confidence:0,event:null,error:String(e?.message||e)}));
    recordRadarEtaObservation();
    updateRadarValidation();
    state.lastRadarRefresh=Date.now();
    state.lastCompletedAt=new Date().toISOString();
    render();
  }catch(e){
    $('eta').textContent='Sin datos';$('summary').textContent=String(e?.message||e);
  }finally{state.loading=false}
}
function setLocation(loc){
  const next={name:loc.name||'Ubicación',lat:Number(loc.lat),lon:Number(loc.lon),isCurrent:Boolean(loc.isCurrent)};
  state.loc=next;
  if(next.isCurrent){
    state.currentLocation={...next};
    localStorage.setItem('raineta.currentLocation',JSON.stringify(state.currentLocation));
  }
  localStorage.setItem('raineta.loc',JSON.stringify(state.loc));state.frameIndex=0;state.radarOffset=0;state.selectedHourIndex=null;
  $('dlg').close();showDetail();load(true);
}
async function searchPlace(){
  const q=$('q').value.trim();if(q.length<2)return;
  $('results').textContent='Buscando…';
  try{
    const p=new URLSearchParams({name:q,count:'8',language:'es',format:'json'});
    const d=await fetchJson('https://geocoding-api.open-meteo.com/v1/search?'+p,7000);
    $('results').textContent='';
    const ranked=[...(d.results||[])].sort((a,b)=>{
      const aes=String(a.country_code||'').toUpperCase()==='ES'?0:1;
      const bes=String(b.country_code||'').toUpperCase()==='ES'?0:1;
      return aes-bes;
    });
    for(const x of ranked){
      const b=document.createElement('button');
      b.textContent=x.name+(x.admin1?' · '+x.admin1:'')+(x.country?' · '+x.country:'');
      b.onclick=()=>setLocation({name:x.name,lat:x.latitude,lon:x.longitude,isCurrent:false});
      $('results').appendChild(b);
    }
    if(!$('results').children.length)$('results').textContent='Sin resultados';
  }catch{$('results').textContent='No se pudo buscar'}
}

function recordFeedback(raining){
  if(!state.currentLocation||!samePlace(state.loc,state.currentLocation))return;
  const auto=automaticRainState(),now=Date.now();
  const row={
    time:now,
    lat:state.currentLocation.lat,lon:state.currentLocation.lon,
    raining:Boolean(raining),predicted:Boolean(auto.raining),
    radarWetFraction:Number.isFinite(Number(state.nowcast?.currentWetFraction))?Number(state.nowcast.currentWetFraction):null,
    modelPrecip:Number(state.data?.quarterHour?.current?.precipitation)||0,
    threshold:calibratedRadarThreshold()
  };
  const last=state.feedback.at(-1);
  if(last&&samePlace(last,row,.0015)&&now-last.time<90_000)state.feedback[state.feedback.length-1]=row;
  else state.feedback.push(row);
  state.feedback=state.feedback.slice(-120);persistFeedback();
  try{navigator.vibrate?.(25)}catch{}
  render();
}
function toggleSavedLocation(){
  if(state.loc.isCurrent)return;
  const idx=state.savedLocations.findIndex(x=>samePlace(x,state.loc,.0015));
  if(idx>=0)state.savedLocations.splice(idx,1);
  else state.savedLocations.push({name:state.loc.name,lat:state.loc.lat,lon:state.loc.lon,isCurrent:false});
  persistLocations();render();
}
async function fetchQuickSummary(loc){
  const p=new URLSearchParams({
    latitude:String(loc.lat),longitude:String(loc.lon),
    current:'temperature_2m,precipitation,rain,showers',
    minutely_15:'precipitation',forecast_minutely_15:'16',
    timeformat:'unixtime',timezone:'GMT'
  });
  const d=await fetchJson('https://api.open-meteo.com/v1/forecast?'+p,8000);
  const time=(d.minutely_15?.time||[]).map(iso),prec=(d.minutely_15?.precipitation||[]).map(v=>Number(v)||0);
  const events=detectQuarterHourEvents(time,prec),next=events.find(e=>Date.parse(e.end)>Date.now())||null;
  const precipitation=Number(d.current?.precipitation)||0;
  return{
    location:loc,
    temperature:Number(d.current?.temperature_2m),
    raining:precipitation>=.1,
    precipitation,
    next
  };
}
function allLocations(){
  const out=[];
  if(state.currentLocation)out.push({...state.currentLocation,isCurrent:true,name:'Mi ubicación'});
  for(const loc of state.savedLocations)if(!out.some(x=>samePlace(x,loc,.0015)))out.push({...loc,isCurrent:false});
  return out;
}
function openRenameLocation(loc){
  state.renameTarget=loc;
  $('renameInput').value=loc.name||'';
  $('renameDlg').showModal();
  setTimeout(()=>$('renameInput').select(),50);
}
function saveRenameLocation(){
  const target=state.renameTarget,name=$('renameInput').value.trim();
  if(!target||!name)return;
  const item=state.savedLocations.find(x=>samePlace(x,target,.0015));
  if(item)item.name=name;
  if(samePlace(state.loc,target,.0015)){state.loc.name=name;localStorage.setItem('raineta.loc',JSON.stringify(state.loc))}
  persistLocations();state.renameTarget=null;$('renameDlg').close();renderLocationsSummary(true);
}
function deleteSavedLocation(loc){
  if(!confirm('¿Eliminar '+loc.name+' de Mis lugares?'))return;
  state.savedLocations=state.savedLocations.filter(x=>!samePlace(x,loc,.0015));
  persistLocations();renderLocationsSummary(true);
}

async function renderLocationsSummary(force=false){
  if(state.locationsLoading)return;
  state.locationsLoading=true;
  const holder=$('locationCards'),locations=allLocations();
  holder.innerHTML=locations.length?'<div class="status">Actualizando '+locations.length+' lugares…</div>':'<div class="status">Todavía no tienes lugares. Usa “Añadir lugar” o guarda uno desde su detalle.</div>';
  if(!locations.length){$('locationsUpdated').textContent=fmtTimeSeconds(Date.now());state.locationsLoading=false;return}
  const settled=await Promise.allSettled(locations.map(fetchQuickSummary));
  holder.innerHTML='';
  settled.forEach((result,index)=>{
    const loc=locations[index],card=document.createElement('div');card.className='locationCard';
    const left=document.createElement('button');left.className='openLoc';
    const right=document.createElement('div');
    if(result.status==='fulfilled'){
      const s=result.value,truth=loc.isCurrent?recentTruthFor(loc):null;
      const raining=truth===null?s.raining:truth;
      const next=s.next&&!raining?(Date.parse(s.next.start)>Date.now()?' · lluvia '+until(s.next.start):''):'';
      const source=truth===null?(raining?'Precipitación detectada':'Sin precipitación ahora'):(raining?'Confirmado: llueve':'Confirmado: no llueve');
      left.innerHTML='<strong>'+loc.name+(loc.isCurrent?' · GPS':'')+'</strong><small>'+source+next+'</small>';
      right.innerHTML='<div class="locNow '+(raining?'wet':'')+'">'+(raining?'LLUEVE':'NO LLUEVE')+'</div><div class="locTemp">'+(Number.isFinite(s.temperature)?s.temperature.toFixed(1).replace('.',',')+' °C':'—')+'</div>';
    }else{
      left.innerHTML='<strong>'+loc.name+(loc.isCurrent?' · GPS':'')+'</strong><small>No se pudieron actualizar los datos</small>';
      right.innerHTML='<div class="locNow">—</div>';
    }
    left.onclick=()=>setLocation(loc);
    if(!loc.isCurrent){
      const actions=document.createElement('div');actions.className='locActions';
      const rename=document.createElement('button');rename.className='locAction';rename.textContent='✎ Renombrar';rename.title='Renombrar';
      rename.onclick=e=>{e.stopPropagation();openRenameLocation(loc)};
      const remove=document.createElement('button');remove.className='locAction danger';remove.textContent='🗑 Eliminar';remove.title='Eliminar';
      remove.onclick=e=>{e.stopPropagation();deleteSavedLocation(loc)};
      actions.append(rename,remove);right.appendChild(actions);
    }
    card.append(left,right);holder.appendChild(card);
  });
  $('locationsUpdated').textContent=fmtTimeSeconds(Date.now());
  state.locationsLoading=false;
}
function showDetail(){
  state.view='detail';$('detailView').hidden=false;$('locationsView').hidden=true;$('place').hidden=false;$('viewToggle').textContent='☷';
}
function showLocations(){
  state.view='locations';$('detailView').hidden=true;$('locationsView').hidden=false;$('place').hidden=true;$('viewToggle').textContent='←';renderLocationsSummary();
}

$('place').onclick=()=>$('dlg').showModal();
$('close').onclick=()=>$('dlg').close();
$('viewToggle').onclick=()=>state.view==='locations'?showDetail():showLocations();
$('refresh').onclick=()=>state.view==='locations'?renderLocationsSummary(true):load(true);
$('savePlace').onclick=toggleSavedLocation;
$('feedbackYes').onclick=()=>recordFeedback(true);
$('feedbackNo').onclick=()=>recordFeedback(false);
$('addLocation').onclick=()=>$('dlg').showModal();
$('renameCancel').onclick=()=>{state.renameTarget=null;$('renameDlg').close()};
$('renameSave').onclick=saveRenameLocation;
$('renameInput').onkeydown=e=>{if(e.key==='Enter')saveRenameLocation()};
$('shortBack').onclick=clearSelectedHour;
$('search').onclick=searchPlace;
$('q').onkeydown=e=>{if(e.key==='Enter')searchPlace()};
$('geo').onclick=()=>{
  if(!navigator.geolocation){$('results').textContent='Geolocalización no disponible';return}
  $('results').textContent='Obteniendo ubicación…';
  navigator.geolocation.getCurrentPosition(
    p=>setLocation({name:'Mi ubicación',lat:Number(p.coords.latitude.toFixed(5)),lon:Number(p.coords.longitude.toFixed(5)),isCurrent:true}),
    e=>$('results').textContent=e.message,
    {enableHighAccuracy:true,timeout:15000,maximumAge:60000}
  );
};
$('frame').oninput=function(){showRadarOffset(Number(this.value))};
$('radarNow').onclick=function(){
  if(state.playTimer){clearInterval(state.playTimer);state.playTimer=null;$('play').textContent='▶'}
  $('frame').value='0';showRadarOffset(0);
};
$('play').onclick=function(){
  if(state.playTimer){clearInterval(state.playTimer);state.playTimer=null;this.textContent='▶';return}
  if(!state.frames.length)return;
  const slider=$('frame');if(Number(slider.value)>=Number(slider.max))slider.value=slider.min;
  this.textContent='❚❚';
  state.playTimer=setInterval(()=>{
    let next=Number(slider.value)+5;
    if(next>Number(slider.max))next=Number(slider.min);
    slider.value=next;showRadarOffset(next);
  },700);
};
if('serviceWorker'in navigator){
  navigator.serviceWorker.register('/rain/sw.js',{updateViaCache:'none'}).then(reg=>{
    reg.update().catch(()=>{});
  }).catch(()=>{});
}
document.addEventListener('visibilitychange',()=>{
  if(document.visibilityState==='visible'&&Date.now()-state.lastRadarRefresh>RADAR_REFRESH_MS)refreshRadar();
});
setInterval(()=>{if(document.visibilityState==='visible')refreshRadar()},RADAR_REFRESH_MS);
setInterval(()=>{if(document.visibilityState==='visible'&&state.data)updateLiveCountdown()},1000);
load();
