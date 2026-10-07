import {aggregateEnsembleModel,buildConsensus,compactTimeline,detectQuarterHourEvents,detectRainEvents,chooseNextEvent,median,percentile,classifyRainHour,bestDryWindow} from './core.js';
import {estimateTranslation,combineMotionEstimates,projectPointSeries,estimateLocalFlow,combineLocalFlows,projectPointSeriesFlow,evolutionReliability,detectNowcastEvent,nowcastUncertaintyMinutes,wetNear} from './radar-core.js';

const DET_MODELS=[
  {id:'aemet_harmonie_arome',label:'AEMET HARMONIE-AROME 2,5 km',family:'AEMET',weight:1.48,provider:'rain-harmonie',metaDomains:[]},
  {id:'ecmwf_ifs',label:'ECMWF IFS 9 km',family:'ECMWF',weight:1.32,metaDomains:['ecmwf_ifs025']},
  {id:'ecmwf_aifs025',label:'ECMWF AIFS',family:'ECMWF',weight:1.05,metaDomains:['ecmwf_aifs025']},
  {id:'icon_seamless',label:'DWD ICON',family:'DWD',weight:1.10,metaDomains:['dwd_icon_eu','dwd_icon']},
  {id:'gfs_seamless',label:'NOAA GFS',family:'NOAA',weight:.90,metaDomains:['ncep_gfs013','ncep_gfs025']},
  {id:'meteofrance_seamless',label:'Météo-France',family:'METEOFRANCE',weight:1.00,metaDomains:['meteofrance_arpege_europe','meteofrance_arpege_world025']},
  {id:'gem_seamless',label:'CMC GEM',family:'CMC',weight:.75,metaDomains:['cmc_gem_gdps']},
  {id:'ukmo_global_deterministic_10km',label:'UKMO Global 10 km',family:'UKMO',weight:1.02,metaDomains:['ukmo_global_deterministic_10km']},
];
const ENS_MODELS=[
  // Open-Meteo currently omits exact update metadata for the native Europe IFS ensemble; keep it usable with freshness=unknown instead of guessing.
  {id:'ecmwf_ifs_europe_ensemble',label:'ECMWF ENS Europe 9 km',family:'ECMWF',weight:1.30,metaDomains:[]},
  {id:'ecmwf_aifs025_ensemble',label:'ECMWF AIFS ENS',family:'ECMWF',weight:1.00,metaDomains:['ecmwf_aifs025_ensemble']},
  {id:'dwd_icon_eu_eps',label:'ICON-EU EPS',family:'DWD',weight:1.10,metaDomains:['dwd_icon_eu_eps']},
  {id:'ncep_gefs025',label:'NOAA GEFS',family:'NOAA',weight:.90,metaDomains:['ncep_gefs025']},
  {id:'ukmo_global_ensemble_20km',label:'UKMO MOGREPS-G',family:'UKMO',weight:.95,metaDomains:['ukmo_global_ensemble_20km']},
  {id:'gem_global_ensemble',label:'CMC GEPS',family:'CMC',weight:.82,metaDomains:['cmc_gem_geps']},
  {id:'bom_access_global_ensemble',label:'BOM ACCESS-GE',family:'BOM',weight:.72,metaDomains:['bom_access_global_ensemble']},
  {id:'google_weathernext2_ensemble',label:'Google WeatherNext 2',family:'GOOGLE',weight:.92,metaDomains:['google_weathernext2_ensemble']},
];
const FORECAST_TTL=20*60_000;
const FORECAST_PROPAGATION_TTL=5*60_000;
const FORECAST_FALLBACK_MAX_AGE=90*60_000;
const RADAR_REFRESH_MS=5*60_000;
const CANONICAL_RADAR_THRESHOLD=.22;
const RADAR_FRAMES=6;
const RADAR_ZOOM=7;
const ANALYSIS_SIZE=97;
const MAX_SHIFT=12;
const MAX_RADAR_ADVECTION_KMH=180;
const RADAR_PROJECTION_MIN_CONFIDENCE=.30;
const RADAR_PROJECTION_MIN_EVOLUTION=.30;
const SHORT_HORIZON_MINUTES=180;
const RADAR_VISUAL_HORIZON_MINUTES=240;
const RADAR_PAST_HORIZON_MINUTES=240;
const RADAR_FRAME_ARCHIVE_KEY='raineta.radar.frames.v1';
const RADAR_STALE_MINUTES=20;
const OPERA_STALE_MINUTES=30;
const AEMET_RADAR_STALE_MINUTES=30;
const OPERA_SURFACE_STALE_MINUTES=20;
const MODEL_META_GRACE_SECONDS=20*60;
const MODEL_META_PROPAGATION_SECONDS=10*60;
const HARMONIE_EXPECTED_UPDATE_MINUTES=360;
const HARMONIE_STALE_GRACE_MINUTES=180;
const RADAR_PAST_FRAME_MS=600;
const RADAR_FUTURE_TICK_MS=100;
const APP_VERSION='0.17.27';
const FORECAST_CACHE_SCHEMA='consensus-v16';
const FORECAST_CACHE_COMPATIBLE_VERSIONS=[];

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
  data:null,nowcast:null,map:null,mapLoaded:false,marker:null,radarLayer:null,frames:[],frameIndex:0,playTimer:null,playMode:null,loading:false,radarLoading:false,lastRadarRefresh:0,lastCompletedAt:null,view:'detail',locationsLoading:false,version:APP_VERSION,renameTarget:null,selectedHourIndex:null,radarOffset:0,timelineHours:[24,48,72].includes(Number(readLocal('raineta.timelineHours',24)))?Number(readLocal('raineta.timelineHours',24)):24
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
function forecastCoords(loc=state.loc){
  return{
    lat:Math.round(Number(loc.lat)*1000)/1000,
    lon:Math.round(Number(loc.lon)*1000)/1000
  };
}
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
function currentTruth(maxAgeMinutes=4){
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
function timeMs(v){
  if(v instanceof Date)return v.getTime();
  if(typeof v==='number'&&Number.isFinite(v))return v;
  const t=Date.parse(v);return Number.isFinite(t)?t:NaN;
}
function durationText(start,end){
  if(start==null||end==null)return'—';
  const a=timeMs(start),b=timeMs(end);
  if(!Number.isFinite(a)||!Number.isFinite(b))return'—';
  const m=Math.max(0,Math.round((b-a)/60000));
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
function cacheKey(){const p=forecastCoords();return 'raineta.forecast.'+p.lat.toFixed(3)+','+p.lon.toFixed(3)}
function readForecastCache(){
  try{
    const c=JSON.parse(localStorage.getItem(cacheKey())||'null');
    if(!c||!c.data?.week)return null;
    const compatible=c.cacheSchema===FORECAST_CACHE_SCHEMA||FORECAST_CACHE_COMPATIBLE_VERSIONS.includes(c.version);
    if(!compatible)return null;
    const ageMs=Date.now()-Number(c.savedAt);
    if(!Number.isFinite(ageMs)||ageMs<0)return null;
    return{...c,ageMs};
  }catch{return null}
}
function fallbackConfidenceCap(ageMs){
  const minutes=Math.max(0,Number(ageMs)||0)/60_000;
  return minutes<=45?.55:minutes<=70?.45:.35;
}
function degradedForecastFromCache(cached,reason='fuentes de previsión no disponibles'){
  if(!cached||cached.ageMs>FORECAST_FALLBACK_MAX_AGE)return null;
  const data=JSON.parse(JSON.stringify(cached.data)),cap=fallbackConfidenceCap(cached.ageMs);
  data.timeline=(data.timeline||[]).map(row=>({...row,confidence:Math.min(Number(row.confidence)||0,Math.round(cap*100))}));
  data.events=(data.events||[]).map(event=>({...event,timingConfidence:Math.min(Number(event.timingConfidence)||0,cap)}));
  data.nextEvent=chooseNextEvent(data.events||[],Date.now());
  const markFallback=rows=>(rows||[]).map(source=>({...source,ok:false,fallback:true,error:'sin actualización en vivo'}));
  data.sources=data.sources||{};
  data.sources.deterministic=markFallback(data.sources.deterministic);
  data.sources.ensembles=markFallback(data.sources.ensembles);
  data.sources.quarterHour=false;
  data.sources.radar=radarFreshness(data.radar).ok;
  data.sources.opera=operaFreshness(data.opera).ok;
  data.sources.aemetRadar=aemetRadarFreshness(data.aemetRadar).ok;
  const all=[...(data.sources.deterministic||[]),...(data.sources.ensembles||[])];
  data.sources.health={
    available:(data.sources.radar?1:0)+(data.sources.opera?1:0)+(data.sources.aemetRadar?1:0),
    total:all.length+4
  };
  return{
    ...data,
    cacheAgeMs:cached.ageMs,
    degradedForecast:true,
    degradedReason:reason,
    degradedCacheAgeMs:cached.ageMs,
    degradedConfidenceCap:cap
  };
}
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
function evaluateModelMeta(domain,meta,nowSeconds=Date.now()/1000){
  const initialisation=Number(meta?.last_run_initialisation_time);
  const availability=Number(meta?.last_run_availability_time);
  const interval=Number(meta?.update_interval_seconds);
  if(!Number.isFinite(availability)||!Number.isFinite(interval)||interval<=0)return null;
  const delaySeconds=nowSeconds-(availability+interval);
  const availabilityAgeSeconds=nowSeconds-availability;
  return{
    domain,
    stale:delaySeconds>MODEL_META_GRACE_SECONDS,
    propagating:availabilityAgeSeconds>=0&&availabilityAgeSeconds<MODEL_META_PROPAGATION_SECONDS,
    availabilityAgeMinutes:Number.isFinite(availabilityAgeSeconds)?Math.max(0,Math.round(availabilityAgeSeconds/60)):null,
    delayMinutes:Math.max(0,Math.round(delaySeconds/60)),
    initialisedAt:Number.isFinite(initialisation)?new Date(initialisation*1000).toISOString():null,
    availableAt:new Date(availability*1000).toISOString(),
    updateIntervalMinutes:Math.round(interval/60)
  };
}
async function fetchModelFreshness(model){
  if(model.provider==='rain-harmonie'){
    return{
      status:'unknown',
      domain:'aemet_harmonie_pb',
      updateIntervalMinutes:HARMONIE_EXPECTED_UPDATE_MINUTES,
      reason:'frescura pendiente de validar con sourceGeneratedAt de la descarga oficial'
    };
  }
  const domains=Array.isArray(model.metaDomains)?model.metaDomains.filter(Boolean):[];
  if(!domains.length)return{status:'unknown',reason:'sin metadata exacta para este producto'};
  const results=await Promise.allSettled(domains.map(async domain=>{
    const meta=await fetchJson('https://api.open-meteo.com/data/'+domain+'/static/meta.json',3200);
    return evaluateModelMeta(domain,meta);
  }));
  const evaluated=results.filter(x=>x.status==='fulfilled'&&x.value).map(x=>x.value);
  const fresh=evaluated.filter(x=>!x.stale).sort((a,b)=>{
    if(Boolean(a.propagating)!==Boolean(b.propagating))return a.propagating?1:-1;
    return Date.parse(b.availableAt)-Date.parse(a.availableAt);
  });
  if(fresh.length){
    const best=fresh[0];
    return{status:best.propagating?'propagating':'fresh',...best,checkedDomains:domains.length};
  }
  if(evaluated.length===domains.length&&evaluated.length){
    const leastLate=[...evaluated].sort((a,b)=>a.delayMinutes-b.delayMinutes)[0];
    return{status:'stale',...leastLate,checkedDomains:domains.length};
  }
  return{status:'unknown',reason:'metadata parcial/no disponible',checkedDomains:domains.length};
}
async function fetchDet(model){
  if(model.provider==='rain-harmonie'){
    const point=forecastCoords(),p=new URLSearchParams({
      lat:String(point.lat),lon:String(point.lon),hours:'48'
    });
    const d=await fetchJson('/api/rain-harmonie?'+p,35_000);
    if(!d?.ok||!Array.isArray(d.rows)||!d.rows.length)throw new Error(d?.error||'AEMET HARMONIE sin datos');
    return{
      ...model,
      rows:d.rows
        .filter(row=>row?.time)
        .map(row=>({time:row.time,precipitation:Math.max(0,Number(row.precipitation)||0)})),
      sourceMeta:{
        resolutionKm:Number(d.resolutionKm)||2.5,
        temporalResolutionMinutes:Number(d.temporalResolutionMinutes)||60,
        sourceGeneratedAt:d.sourceGeneratedAt||null,
        fetchedAt:d.fetchedAt||null
      },
      spatialRows:d.rows
    };
  }
  const p=new URLSearchParams({
    latitude:String(forecastCoords().lat),longitude:String(forecastCoords().lon),hourly:'precipitation',
    forecast_hours:'73',timeformat:'unixtime',timezone:'GMT',models:model.id
  });
  const d=await fetchJson('https://api.open-meteo.com/v1/forecast?'+p,8500);
  const h=normalizeHourly(d.hourly||{});
  return {...model,rows:(h.time||[]).map((time,i)=>({time,precipitation:Number(h.precipitation?.[i])||0}))};
}
async function fetchEns(model){
  const p=new URLSearchParams({
    latitude:String(forecastCoords().lat),longitude:String(forecastCoords().lon),hourly:'precipitation',
    forecast_hours:'73',timeformat:'unixtime',timezone:'GMT',models:model.id
  });
  const d=await fetchJson('https://ensemble-api.open-meteo.com/v1/ensemble?'+p,10500);
  const a=aggregateEnsembleModel(normalizeHourly(d.hourly||{}));
  if(!a)throw new Error('sin miembros');
  return {...model,memberCount:a.memberCount,rows:a.rows,onset:a.onset};
}
async function fetchQuarterHour(){
  const p=new URLSearchParams({
    latitude:String(forecastCoords().lat),longitude:String(forecastCoords().lon),
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
async function fetchWeekForecast(){
  const point=forecastCoords(),p=new URLSearchParams({
    latitude:String(point.lat),longitude:String(point.lon),
    hourly:'precipitation_probability,precipitation,weather_code',
    forecast_days:'8',timeformat:'unixtime',timezone:'auto'
  });
  const d=await fetchJson('https://api.open-meteo.com/v1/forecast?'+p,8000);
  const h=d.hourly||{},offset=Number(d.utc_offset_seconds)||0;
  const times=h.time||[],prob=h.precipitation_probability||[],prec=h.precipitation||[],codes=h.weather_code||[];
  return{
    timezone:d.timezone||null,
    utcOffsetSeconds:offset,
    rows:times.map((t,i)=>({
      unix:Number(t),
      probability:Number(prob[i])||0,
      precipitation:Number(prec[i])||0,
      weatherCode:Number(codes[i])
    })).filter(r=>Number.isFinite(r.unix))
  };
}
function readRadarFrameArchive(){
  try{
    const rows=JSON.parse(localStorage.getItem(RADAR_FRAME_ARCHIVE_KEY)||'[]');
    return Array.isArray(rows)?rows.filter(row=>Number.isFinite(Number(row?.time))&&row?.path):[];
  }catch{return[]}
}
function mergeRadarFrameArchive(host,freshFrames=[]){
  const fresh=freshFrames
    .map(f=>({time:Number(f.time),path:f.path,host:host||f.host||null}))
    .filter(f=>Number.isFinite(f.time)&&f.path);
  const latest=fresh.at(-1)?.time||Math.floor(Date.now()/1000);
  const cutoff=latest-RADAR_PAST_HORIZON_MINUTES*60;
  const byTime=new Map();
  for(const row of [...readRadarFrameArchive(),...fresh]){
    const time=Number(row?.time);
    if(!Number.isFinite(time)||time<cutoff||time>latest+60||!row?.path)continue;
    byTime.set(time,{time,path:row.path,host:row.host||host||null});
  }
  const merged=[...byTime.values()].sort((a,b)=>a.time-b.time);
  try{localStorage.setItem(RADAR_FRAME_ARCHIVE_KEY,JSON.stringify(merged.slice(-80)))}catch{}
  return merged;
}
async function fetchRadarMeta(){
  const d=await fetchJson('https://api.rainviewer.com/public/weather-maps.json',6000);
  const fresh=(d.radar?.past||[]).map(f=>({time:Number(f.time),path:f.path,host:d.host}));
  const frames=mergeRadarFrameArchive(d.host,fresh);
  return {
    provider:'RainViewer',host:d.host,generated:Number(d.generated)||null,
    frames,
    freshFrameCount:fresh.length,
    archiveExtended:Boolean(frames.length&&fresh.length&&frames[0].time<fresh[0].time),
    attribution:'Weather data by RainViewer'
  };
}
function radarFreshness(meta,maxAgeMinutes=RADAR_STALE_MINUTES){
  const latest=meta?.frames?.at?.(-1);
  const latestMs=Number(latest?.time)*1000;
  const ageMinutes=Number.isFinite(latestMs)?Math.max(0,(Date.now()-latestMs)/60_000):Infinity;
  return{ok:Boolean(meta?.host&&latest&&ageMinutes<=maxAgeMinutes),ageMinutes,latestTime:Number(latest?.time)||null};
}
function operaFreshness(meta,maxAgeMinutes=OPERA_STALE_MINUTES){
  const ageMinutes=Number(meta?.ageMinutes);
  return{ok:Boolean(meta?.ok&&Number.isFinite(ageMinutes)&&ageMinutes<=maxAgeMinutes),ageMinutes};
}
async function fetchAemetRadarMeta(){
  const point=forecastCoords(),p=new URLSearchParams({lat:String(point.lat),lon:String(point.lon),motion:'1'});
  const r=await fetch('/api/rain-aemet-radar?'+p);
  if(!r.ok)throw new Error('AEMET radar HTTP '+r.status);
  const d=await r.json();
  if(!d?.ok)throw new Error(d?.error||'AEMET radar sin datos');
  return{
    ...d,
    frames:(d.frames||[]).map(frame=>({
      ...frame,
      time:Math.round(Date.parse(frame.time)/1000)
    })).filter(frame=>Number.isFinite(frame.time))
  };
}
function aemetRadarFreshness(meta,maxAgeMinutes=AEMET_RADAR_STALE_MINUTES){
  const ageMinutes=Number(meta?.ageMinutes);
  return{ok:Boolean(meta?.ok&&meta?.frames?.length&&Number.isFinite(ageMinutes)&&ageMinutes<=maxAgeMinutes),ageMinutes};
}

async function fetchOperaMeta(){
  const point=forecastCoords(),p=new URLSearchParams({lat:String(point.lat),lon:String(point.lon),motion:'1'});
  const r=await fetch('/api/rain-opera?'+p);
  if(!r.ok)throw new Error('OPERA HTTP '+r.status);
  return r.json();
}
function harmonieFetchedFreshness(model,fetchedValue,baseFreshness={}){
  if(model?.provider!=='rain-harmonie')return baseFreshness||{status:'unknown'};
  const generatedAt=fetchedValue?.sourceMeta?.sourceGeneratedAt;
  const generatedMs=Date.parse(generatedAt||'');
  if(!Number.isFinite(generatedMs)){
    return{
      ...baseFreshness,status:'unknown',domain:'aemet_harmonie_pb',
      reason:'sourceGeneratedAt no disponible en la descarga oficial',
      updateIntervalMinutes:HARMONIE_EXPECTED_UPDATE_MINUTES
    };
  }
  const ageMinutes=Math.max(0,(Date.now()-generatedMs)/60_000);
  const stale=ageMinutes>HARMONIE_EXPECTED_UPDATE_MINUTES+HARMONIE_STALE_GRACE_MINUTES;
  return{
    ...baseFreshness,
    status:stale?'stale':'fresh',
    stale,
    domain:'aemet_harmonie_pb',
    availableAt:new Date(generatedMs).toISOString(),
    availabilityAgeMinutes:Math.round(ageMinutes),
    delayMinutes:Math.max(0,Math.round(ageMinutes-HARMONIE_EXPECTED_UPDATE_MINUTES)),
    updateIntervalMinutes:HARMONIE_EXPECTED_UPDATE_MINUTES,
    reason:stale?'pasada AEMET HARMONIE demasiado antigua':'frescura validada con sourceGeneratedAt oficial'
  };
}
function effectiveFreshness(defs,settled,freshness,index){
  const base=freshness[index]?.status==='fulfilled'
    ? freshness[index].value
    : {status:'unknown',reason:'metadata no consultada'};
  const model=defs?.[index],value=settled[index]?.status==='fulfilled'?settled[index].value:null;
  return harmonieFetchedFreshness(model,value,base);
}
function sourceStatus(defs,settled,freshnessSettled=[]){
  return defs.map((m,i)=>{
    const fetched=settled[i]?.status==='fulfilled';
    const freshness=effectiveFreshness(defs,settled,freshnessSettled,i);
    const stale=freshness?.status==='stale';
    return{
      id:m.id,label:m.label,family:m.family||m.id,
      ok:Boolean(fetched&&!stale),fetched,stale,
      freshnessStatus:freshness?.status||'unknown',
      freshnessReason:freshness?.reason||null,
      propagating:freshness?.status==='propagating',
      availabilityAgeMinutes:Number.isFinite(Number(freshness?.availabilityAgeMinutes))?Number(freshness.availabilityAgeMinutes):null,
      initialisedAt:freshness?.initialisedAt||null,
      availableAt:freshness?.availableAt||null,
      delayMinutes:Number.isFinite(Number(freshness?.delayMinutes))?Number(freshness.delayMinutes):null,
      updateIntervalMinutes:Number.isFinite(Number(freshness?.updateIntervalMinutes))?Number(freshness.updateIntervalMinutes):null,
      metaDomain:freshness?.domain||null,
      members:fetched?(settled[i].value.memberCount||null):null,
      error:settled[i]?.status==='rejected'?String(settled[i].reason?.message||settled[i].reason):stale?'modelo desactualizado':null
    };
  });
}
function usableForecast(defs,settled,freshness,index){
  return settled[index]?.status==='fulfilled'&&effectiveFreshness(defs,settled,freshness,index)?.status!=='stale';
}
function modelPropagationState(detSettled,ensSettled,detFreshness,ensFreshness){
  const byFamily=new Map();
  const collect=(defs,settled,freshness)=>{
    defs.forEach((model,i)=>{
      if(!usableForecast(defs,settled,freshness,i))return;
      const status=effectiveFreshness(defs,settled,freshness,i)?.status||'unknown';
      const family=model.family||model.id;
      const arr=byFamily.get(family)||[];
      arr.push(status);byFamily.set(family,arr);
    });
  };
  collect(DET_MODELS,detSettled,detFreshness);
  collect(ENS_MODELS,ensSettled,ensFreshness);
  let propagatingFamilies=0,unknownFamilies=0;
  for(const statuses of byFamily.values()){
    if(statuses.includes('fresh'))continue;
    if(statuses.includes('propagating')){propagatingFamilies++;continue}
    if(statuses.every(status=>status==='unknown'))unknownFamilies++;
  }
  const totalFamilies=byFamily.size;
  const propagatingShare=totalFamilies?propagatingFamilies/totalFamilies:0;
  const unknownShare=totalFamilies?unknownFamilies/totalFamilies:0;
  const propagationPenalty=Math.min(.08,.08*propagatingShare);
  const metadataPenalty=unknownShare<=.25?0:Math.min(.06,.08*(unknownShare-.25));
  const confidencePenalty=Math.min(.12,propagationPenalty+metadataPenalty);
  return{
    propagatingFamilies,unknownFamilies,totalFamilies,
    propagatingShare,unknownShare,propagationPenalty,metadataPenalty,confidencePenalty
  };
}
function ensembleArrivalGuidance(ensembles=[],nowMs=Date.now()){
  const usable=(ensembles||[]).filter(model=>{
    const onset=model?.onset,medianMs=Date.parse(onset?.median||'');
    return onset&&Number(onset.fraction)>=.20&&Number.isFinite(medianMs)&&medianMs>=nowMs-60*60_000&&medianMs<=nowMs+18*60*60_000;
  });
  if(!usable.length)return null;
  const byFamily=new Map();
  for(const model of usable){
    const family=model.family||model.id||model.label;
    const arr=byFamily.get(family)||[];
    arr.push(model);byFamily.set(family,arr);
  }
  const families=[];
  for(const [family,models] of byFamily){
    const medians=models.map(m=>Date.parse(m.onset?.median||'')).filter(Number.isFinite);
    const p20s=models.map(m=>Date.parse(m.onset?.p20||'')).filter(Number.isFinite);
    const p80s=models.map(m=>Date.parse(m.onset?.p80||'')).filter(Number.isFinite);
    const fractions=models.map(m=>Number(m.onset?.fraction)).filter(Number.isFinite);
    if(!medians.length)continue;
    families.push({
      family,
      median:median(medians),
      p20:median(p20s.length?p20s:medians),
      p80:median(p80s.length?p80s:medians),
      support:fractions.length?fractions.reduce((a,b)=>a+b,0)/fractions.length:0
    });
  }
  if(!families.length)return null;
  const starts=families.map(x=>x.median),medianStart=median(starts);
  const between=Math.max(0,(percentile(starts,.80)-percentile(starts,.20))/60_000);
  const internal=families.map(x=>Math.max(0,(x.p80-x.p20)/60_000)).filter(Number.isFinite);
  const internalSpread=internal.length?median(internal):60;
  const spreadMinutes=Math.max(30,Math.round(Math.max(between,internalSpread)));
  const support=families.reduce((sum,x)=>sum+x.support,0)/families.length;
  const familyFactor=Math.min(1,families.length/5);
  const sharpness=Math.max(0,Math.min(1,1-(spreadMinutes-30)/210));
  const confidence=Math.max(.18,Math.min(.92,.34*support+.34*familyFactor+.32*sharpness));
  return{
    median:new Date(medianStart).toISOString(),
    earliest:new Date(medianStart-spreadMinutes*60_000/2).toISOString(),
    latest:new Date(medianStart+spreadMinutes*60_000/2).toISOString(),
    spreadMinutes,
    support,
    confidence,
    families:families.length,
    familyDetails:families.map(x=>({family:x.family,support:Number(x.support.toFixed(3)),median:new Date(x.median).toISOString()}))
  };
}

async function loadForecast(force=false){
  const k=cacheKey(),cached=readForecastCache();
  const cacheTtl=cached?.data?.sources?.propagation?.propagatingFamilies?FORECAST_PROPAGATION_TTL:FORECAST_TTL;
  if(!force&&cached&&cached.ageMs<cacheTtl)return {...cached.data,cacheAgeMs:cached.ageMs};
  const [det,ens,qh,radar,opera,aemetRadar,week,detFreshness,ensFreshness]=await Promise.all([
    pool(DET_MODELS,fetchDet,3),pool(ENS_MODELS,fetchEns,2),
    Promise.allSettled([fetchQuarterHour()]),Promise.allSettled([fetchRadarMeta()]),Promise.allSettled([fetchOperaMeta()]),
    Promise.allSettled([fetchAemetRadarMeta()]),
    Promise.allSettled([fetchWeekForecast()]),
    Promise.allSettled(DET_MODELS.map(fetchModelFreshness)),
    Promise.allSettled(ENS_MODELS.map(fetchModelFreshness))
  ]);
  const deterministic=det.map((x,i)=>usableForecast(DET_MODELS,det,detFreshness,i)?x.value:null).filter(Boolean);
  const ensembles=ens.map((x,i)=>usableForecast(ENS_MODELS,ens,ensFreshness,i)?x.value:null).filter(Boolean);
  const quarterHour=qh[0]?.status==='fulfilled'?qh[0].value:null;
  const radarMeta=radar[0]?.status==='fulfilled'?radar[0].value:null;
  const operaMeta=opera[0]?.status==='fulfilled'?opera[0].value:null;
  const aemetRadarMeta=aemetRadar[0]?.status==='fulfilled'?aemetRadar[0].value:null;
  const weekForecast=week[0]?.status==='fulfilled'?week[0].value:null;
  if(!deterministic.length&&!ensembles.length&&!quarterHour){
    const fallback=degradedForecastFromCache(cached,'ninguna fuente de previsión respondió');
    if(fallback)return fallback;
    throw new Error('No responde ninguna fuente de previsión');
  }
  const now=Date.now(),end=now+72*3600_000;
  const propagation=modelPropagationState(det,ens,detFreshness,ensFreshness);
  const consensus=buildConsensus({deterministic,ensembles,nowMs:now}).filter(r=>{
    const t=Date.parse(r.time);return t>=now-3600_000&&t<=end;
  }).map(row=>propagation.confidencePenalty>0
    ? {...row,timingConfidence:Math.max(0,(Number(row.timingConfidence)||0)-propagation.confidencePenalty)}
    : row);
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
    arrivalGuidance:ensembleArrivalGuidance(ensembles,now),
    quarterHour,
    radar:radarMeta,
    opera:operaMeta,
    aemetRadar:aemetRadarMeta,
    week:weekForecast,
    sources:{
      deterministic:sourceStatus(DET_MODELS,det,detFreshness),
      ensembles:sourceStatus(ENS_MODELS,ens,ensFreshness),
      quarterHour:Boolean(quarterHour),radar:radarFreshness(radarMeta).ok,opera:operaFreshness(operaMeta).ok,
      aemetRadar:aemetRadarFreshness(aemetRadarMeta).ok,
      propagation
    }
  };
  const all=[...data.sources.deterministic,...data.sources.ensembles];
  data.sources.health={available:all.filter(x=>x.ok).length+(data.sources.quarterHour?1:0)+(data.sources.radar?1:0)+(data.sources.opera?1:0)+(data.sources.aemetRadar?1:0),total:all.length+4};
  try{localStorage.setItem(k,JSON.stringify({version:APP_VERSION,cacheSchema:FORECAST_CACHE_SCHEMA,savedAt:Date.now(),data}))}catch{}
  return data;
}

function radarFrameHost(meta,frame){return frame?.host||meta?.host||''}
function radarTileUrl(meta,frame,size=512,zoom=RADAR_ZOOM){
  const point=forecastCoords();return radarFrameHost(meta,frame)+frame.path+'/'+size+'/'+zoom+'/'+point.lat+'/'+point.lon+'/2/0_0.png';
}
function radarDisplayImageUrl(meta,frame,size=512,zoom=RADAR_ZOOM){
  const point=forecastCoords();return radarFrameHost(meta,frame)+frame.path+'/'+size+'/'+zoom+'/'+point.lat+'/'+point.lon+'/2/1_1.png';
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
function centralLocalMotion(localFlow,lat,step){
  if(!localFlow?.vectors?.length)return null;
  const center=(ANALYSIS_SIZE-1)/2;
  let wx=0,dx=0,dy=0,confidence=0;
  for(const v of localFlow.vectors){
    const distance=Math.hypot(Number(v.x)-center,Number(v.y)-center);
    const weight=Math.max(.02,Number(v.confidence)||0)/(1+distance/18);
    wx+=weight;dx+=Number(v.dx)*weight;dy+=Number(v.dy)*weight;confidence+=(Number(v.confidence)||0)*weight;
  }
  if(!wx)return null;
  return{...radarGeo({dx:dx/wx,dy:dy/wx},lat,step),confidence:confidence/wx,coverage:Number(localFlow.coverage)||0};
}
async function computeNowcast(meta){
  if(!meta?.host||!meta.frames?.length)return{status:'no_radar',confidence:0,event:null};
  const freshness=radarFreshness(meta);
  if(!freshness.ok)return{status:'stale_radar',confidence:0,event:null,radarTime:freshness.latestTime?new Date(freshness.latestTime*1000).toISOString():null,radarAgeMinutes:freshness.ageMinutes};
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
  const rawMotion=combineMotionEstimates(estimates),latest=masks.at(-1),previous=masks.at(-2),step=frameStep(masks);
  const motionGeo=rawMotion?radarGeo(rawMotion,state.loc.lat,step):null;
  const motionPlausible=Boolean(rawMotion&&Number.isFinite(Number(motionGeo?.speedKmh))&&Number(motionGeo.speedKmh)<=MAX_RADAR_ADVECTION_KMH);
  const motion=motionPlausible?rawMotion:null;
  const center=(ANALYSIS_SIZE-1)/2,current=wetNear(latest.mask,ANALYSIS_SIZE,ANALYSIS_SIZE,center,center,0);
  const currentRadarRate=latest.rateGrid?.[Math.round(center)*ANALYSIS_SIZE+Math.round(center)]||0;
  const localFlows=[];
  if(motion){
    for(let i=Math.max(1,masks.length-3);i<masks.length;i++){
      const flow=estimateLocalFlow(masks[i-1].mask,masks[i].mask,ANALYSIS_SIZE,ANALYSIS_SIZE,{maxShift:Math.min(9,MAX_SHIFT),grid:5,patchRadius:9});
      if(flow)localFlows.push(flow);
    }
  }
  const localFlow=combineLocalFlows(localFlows);
  const evolution=motion?evolutionReliability(previous.mask,latest.mask,ANALYSIS_SIZE,ANALYSIS_SIZE,motion):{score:0,overlap:0,densityStable:0};
  const confidence=Math.max(0,Math.min(.98,(motion?.confidence||0)*(.72+.28*evolution.score)));
  const reliableHorizonMinutes=Math.round(25+55*Math.max(0,Math.min(1,evolution.score*.7+confidence*.3)));
  const base={status:'motion_uncertain',confidence,event:null,rainingNow:current>=.10,currentWetFraction:current,currentRadarRate,radarTime:new Date(latest.time*1000).toISOString(),decodedFrames:masks.length,evolution,reliableHorizonMinutes,localFlowCoverage:Number(localFlow?.coverage)||0,rejectedMotionSpeedKmh:!motionPlausible&&motionGeo?Number(motionGeo.speedKmh):null};
  if(!motion||motion.samples<2||confidence<.20)return base;
  const series=localFlow
    ? projectPointSeriesFlow(latest.mask,ANALYSIS_SIZE,ANALYSIS_SIZE,localFlow,motion,{horizonMinutes:RADAR_VISUAL_HORIZON_MINUTES,sourceStepMinutes:step,outputStepMinutes:5,radius:1,intensityGrid:latest.rateGrid,reliability:evolution.score})
    : projectPointSeries(latest.mask,ANALYSIS_SIZE,ANALYSIS_SIZE,motion,{horizonMinutes:RADAR_VISUAL_HORIZON_MINUTES,sourceStepMinutes:step,outputStepMinutes:5,radius:1,intensityGrid:latest.rateGrid});
  let event=detectNowcastEvent(series,{enterWetFraction:.10,exitWetFraction:.035,minConsecutive:2,stepMinutes:5});
  if(event){
    const t=latest.time*1000;
    event={...event,start:new Date(t+event.startMinute*60_000).toISOString(),end:new Date(t+event.endMinute*60_000).toISOString(),uncertaintyMinutes:nowcastUncertaintyMinutes(confidence,event.startMinute)};
  }
  const localMotion=centralLocalMotion(localFlow,state.loc.lat,step);
  return{...base,status:'ok',confidence,event,motion:{
    ...motionGeo,
    samples:motion.samples,consistency:motion.consistency,localFlow:Boolean(localFlow),
    localSpeedKmh:Number(localMotion?.speedKmh)||null,
    localBearingDegrees:Number(localMotion?.bearingDegrees)||null,
    localFlowConfidence:Number(localMotion?.confidence)||0,
    localFlowCoverage:Number(localMotion?.coverage)||0
  },series};
}

function automaticRainState(){
  const now=Date.now(),n=state.nowcast;
  const radarWet=Number(n?.currentWetFraction),radarRate=Number(n?.currentRadarRate)||0;
  const radarAge=now-Date.parse(n?.radarTime||'');
  const radarFresh=(n?.status==='ok'||n?.status==='motion_uncertain')&&Number.isFinite(radarAge)&&radarAge<=12*60_000;
  const radarRain=radarFresh&&Number.isFinite(radarWet)&&radarWet>=CANONICAL_RADAR_THRESHOLD&&radarRate>=.08;
  const radarStrong=radarRain&&radarRate>=2.5&&radarWet>=CANONICAL_RADAR_THRESHOLD;
  const opera=state.data?.opera,operaRate=Number(opera?.sample?.rateMmH)||0,operaQuality=Number(opera?.sample?.quality);
  const operaFresh=Boolean(opera?.sample?.ok&&operaFreshness(opera,OPERA_SURFACE_STALE_MINUTES).ok&&operaQuality>=.5);
  const operaRain=operaFresh&&operaRate>=.05,operaStrong=operaRain&&operaRate>=2.5;
  const aemet=state.data?.aemetRadar,aemetRate=Number(aemet?.sample?.rateMmH)||0,aemetWet=Number(aemet?.sample?.wetFraction);
  const aemetFresh=aemetRadarFreshness(aemet,20).ok;
  const aemetRain=Boolean(aemetFresh&&Number.isFinite(aemetWet)&&aemetWet>=.20&&aemetRate>=.05);
  const aemetStrong=aemetRain&&aemetRate>=2.5;
  const wetSignals=[radarRain,operaRain,aemetRain].filter(Boolean).length;
  const strongSignals=[radarStrong,operaStrong,aemetStrong].filter(Boolean).length;
  const raining=wetSignals>=2||strongSignals>=1;
  const possible=!raining&&wetSignals===1;
  const source=wetSignals>=2?'consenso de radares'
    : radarStrong?'RainViewer fuerte'
      : operaStrong?'OPERA fuerte'
        : aemetStrong?'AEMET fuerte'
          : possible?'señal radar no confirmada'
            :'sin señal superficial';
  const label=raining?'Lluvia ahora':possible?'Señal de lluvia no confirmada':'Tiempo estable';
  return{raining,possible,source,label,radarRain,operaRain,aemetRain,radarStrong,operaStrong,aemetStrong,radarRate,operaRate,aemetRate,wetSignals};
}
function currentRainState(){
  const truth=currentTruth();
  if(truth!==null)return{raining:truth,possible:false,source:'feedback',label:truth?'Llueve ahora':'No llueve ahora'};
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
function nativeQuarterHourLikely(loc=state.loc){
  const lat=Number(loc?.lat),lon=Number(loc?.lon);
  if(!Number.isFinite(lat)||!Number.isFinite(lon))return false;
  // Open-Meteo documents native 15-min precipitation only for limited Central-European / North-American domains.
  // Iberia is explicitly treated as interpolated, never as native 15-min guidance.
  if(lat>=35&&lat<=44.5&&lon>=-10&&lon<=4.5)return false;
  const centralEurope=lat>=43.5&&lat<=56.5&&lon>=-5&&lon<=22;
  const northAmerica=lat>=25&&lat<=55&&lon>=-130&&lon<=-60;
  return centralEurope||northAmerica;
}
function modelPointAt(timeMs){
  const rows=state.data?.timeline||[];
  const best=rows.reduce((acc,row)=>{
    const d=Math.abs(Date.parse(row.time)-timeMs);
    return !acc||d<acc.d?{row,d}:acc;
  },null);
  if(!best||best.d>90*60_000)return{probability:0,rate:0,row:null};
  return{
    probability:Math.max(0,Math.min(1,(Number(best.row.probability)||0)/100)),
    rate:Math.max(0,Number(best.row.precipitation)||0),
    row:best.row
  };
}
function aemetNowcastInfo(){
  const radar=state.data?.aemetRadar,nowcast=radar?.nowcast;
  if(!aemetRadarFreshness(radar).ok||nowcast?.status!=='ok'||!Array.isArray(nowcast.series))return null;
  return nowcast;
}
function nowcastReliability(){
  const rv=Math.max(0,Math.min(1,Number(state.nowcast?.evolution?.score)||Number(state.nowcast?.confidence)||0));
  const op=operaNowcastInfo(),opAge=Number(state.data?.opera?.ageMinutes);
  const opFresh=op?Math.max(0,Math.min(1,1-Math.max(0,opAge-10)/30)):0;
  const opScore=op?(Number(op.confidence)||0)*opFresh:0;
  const ae=aemetNowcastInfo(),aeAge=Number(state.data?.aemetRadar?.ageMinutes);
  const aeFresh=ae?Math.max(0,Math.min(1,1-Math.max(0,aeAge-10)/30)):0;
  const aeScore=ae?(Number(ae.confidence)||0)*aeFresh:0;
  return Math.max(rv,opScore,aeScore);
}
function radarBlendThresholds(reliability=nowcastReliability()){
  const r=Math.max(0,Math.min(1,Number(reliability)||0));
  return{full:12+18*r,zero:48+42*r};
}
function radarBlendWeight(horizonMinutes,reliability=nowcastReliability()){
  const {full,zero}=radarBlendThresholds(reliability);
  if(horizonMinutes<=full)return .9;
  if(horizonMinutes>=zero)return 0;
  return .9*(1-(horizonMinutes-full)/Math.max(1,zero-full));
}
function nowcastReliableHorizon(){
  const rv=state.nowcast?.status==='ok'?Math.max(20,Math.min(90,Number(state.nowcast?.reliableHorizonMinutes)||45)):0;
  const op=operaNowcastInfo(),opH=op?Math.max(20,Math.min(80,Number(op.reliableHorizonMinutes)||25+50*(Number(op.confidence)||0))):0;
  const ae=aemetNowcastInfo(),aeH=ae?Math.max(20,Math.min(90,Number(ae.reliableHorizonMinutes)||25+55*(Number(ae.confidence)||0))):0;
  return Math.round(Math.max(rv,opH,aeH));
}

function confidenceGrade(value){
  const p=pct(value);
  if(p>=75)return{label:'ALTA',key:'high',percent:p};
  if(p>=50)return{label:'MEDIA',key:'medium',percent:p};
  return{label:'BAJA',key:'low',percent:p};
}
function confidenceMarkup(value){
  if(value==null||!Number.isFinite(Number(value)))return'—';
  const g=confidenceGrade(value);
  return '<span class="confGrade '+g.key+'">'+g.label+'</span><small class="confPct">'+g.percent+'%</small>';
}
function decisionBasisInfo(decision){
  const ev=decision?.event,now=decision?.now||Date.now(),reliable=nowcastReliableHorizon();
  const lead=ev?.start?Math.max(0,(Date.parse(ev.start)-now)/60_000):0;
  if(ev?.kind==='observed'||decision?.mode==='episode_pause'||decision?.mode==='episode_ended_early')return{label:'Tu observación + RainETA',key:'radar'};
  if(decision?.dry?.reliableHorizonMinutes)return{label:'Basado en radar',key:'radar'};
  const radarDriven=['radar','opera','radarFusion'].includes(ev?.kind);
  if(decision?.mode==='rain_now'||decision?.mode==='possible_now'||radarDriven&&lead<=reliable){
    return{label:'Basado en radar',key:'radar'};
  }
  const blend=radarBlendWeight(Math.min(SHORT_HORIZON_MINUTES,lead),nowcastReliability());
  if(ev&&lead<=SHORT_HORIZON_MINUTES&&blend>=.20)return{label:'Radar + modelos',key:'mixed'};
  return{label:'Basado principalmente en modelos',key:'models'};
}
function renderDecisionBasis(decision){
  const el=$('decisionBasis');if(!el)return;
  const basis=decisionBasisInfo(decision),g=decision?.confidence!=null?confidenceGrade(decision.confidence):null;
  el.className='decisionBasis '+basis.key;
  el.innerHTML='<span>'+basis.label+'</span>'+(g?'<b>Confianza '+g.label.toLowerCase()+' <small>'+g.percent+'%</small></b>':'');
  if(($('metricConfLabel')?.textContent||'').toLowerCase().includes('confianza')&&decision?.confidence!=null){
    $('conf').innerHTML=confidenceMarkup(decision.confidence);
  }
}
function importantPhenomenon(){
  const now=Date.now(),limit=now+24*3600_000;
  for(const event of canonicalEvents()){
    if(Date.parse(event.end)<=now||Date.parse(event.start)>limit)continue;
    const rows=eventDetailRows(event);
    const severe=rows.filter(row=>{
      const rate=Number(row.precipitation)||0,code=Number(row.weatherCode);
      return rate>=7.5||[95,96,99].includes(code);
    });
    if(!severe.length)continue;
    const groups=[];
    for(const row of severe){
      const start=Date.parse(row.time),end=Date.parse(row.end),rate=Number(row.precipitation)||0,storm=[95,96,99].includes(Number(row.weatherCode));
      const last=groups.at(-1);
      if(last&&start<=last.end+60_000&&last.storm===storm){
        last.end=Math.max(last.end,end);last.peak=Math.max(last.peak,rate);
      }else groups.push({start,end,peak:rate,storm});
    }
    const g=groups[0];
    return{
      kind:g.storm?'storm':'heavy',
      title:g.storm?'Tormenta prevista':'Lluvia fuerte prevista',
      start:g.start,end:g.end,peak:g.peak
    };
  }
  return null;
}
function renderImportantPhenomenon(){
  const el=$('importantPhenomenon');if(!el)return;
  const item=importantPhenomenon();
  if(!item){el.hidden=true;el.innerHTML='';return}
  el.hidden=false;el.className='importantPhenomenon '+item.kind;
  el.innerHTML='<strong>'+(item.kind==='storm'?'⚡ ':'⚠ ')+item.title+'</strong><span>'+fmtDateTime(item.start)+'–'+fmtTime(item.end)+(item.peak>=7.5?' · pico ~'+item.peak.toFixed(1).replace('.',',')+' mm/h':'')+'</span>';
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
function weatherParts(row={}){
  const code=Number(row.weatherCode),snow=Number(row.snowfall)||0,rate=Number(row.precipitation)||0;
  const signal=classifyRainHour({probability:(Number(row.probability)||0)/100,expectedPrecipitation:rate});
  const thunder=[95,96,99].includes(code),showers=[80,81,82].includes(code);
  let primary;
  if(snow>=.02||[71,73,75,77,85,86].includes(code))primary=snow>=.5?'Nieve intensa':'Nieve';
  else if(signal==='wet'||(signal==='possible'&&rate>=.05))primary=intensityLabel(rate);
  else if([45,48].includes(code))primary='Niebla';
  else{
    const cloud=Number(row.cloudCover);
    if(code===0||Number.isFinite(cloud)&&cloud<20)primary='Despejado';
    else if([1,2].includes(code)||Number.isFinite(cloud)&&cloud<65)primary='Parcialmente nublado';
    else primary='Nublado';
  }
  return{primary,phenomenon:thunder?'Tormenta prevista':showers?'Chubascos':null};
}
function conditionLabel(row={}){
  const p=weatherParts(row);
  return p.phenomenon?p.primary+' · '+p.phenomenon.toLowerCase():p.primary;
}
function conditionVisual(row={}){
  const p=weatherParts(row),rate=Number(row.precipitation)||0,code=Number(row.weatherCode),snow=Number(row.snowfall)||0;
  const thunder=[95,96,99].includes(code),showers=[80,81,82].includes(code);
  if(rate>=7.5)return{key:'heavy',icon:thunder?'⚡▼':'▼',label:thunder?'Tormenta con lluvia fuerte':showers?'Chubasco fuerte':'Lluvia fuerte'};
  if(thunder)return{key:'storm',icon:'⚡',label:'Tormenta'};
  if(snow>=.02||[71,73,75,77,85,86].includes(code))return{key:'snow',icon:'❄',label:snow>=.5?'Nieve intensa':'Nieve'};
  if(showers)return{key:'showers',icon:'◒',label:'Chubascos'};
  if(rate>.05){
    if(rate<.5)return{key:'drizzle',icon:'·',label:'Llovizna'};
    if(rate<2.5)return{key:'light',icon:'↓',label:'Lluvia débil'};
    if(rate<7.5)return{key:'moderate',icon:'↓↓',label:'Lluvia moderada'};
    return{key:'heavy',icon:'▼',label:'Lluvia fuerte'};
  }
  if([45,48].includes(code))return{key:'fog',icon:'≋',label:'Niebla'};
  if(p.primary==='Nublado')return{key:'cloudy',icon:'●',label:'Nublado'};
  if(p.primary==='Parcialmente nublado')return{key:'partly',icon:'◐',label:'Parcialmente nublado'};
  if(p.primary==='Despejado')return{key:'clear',icon:'○',label:'Despejado'};
  return{key:'dry',icon:'—',label:'Seco'};
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
function operaPointAt(timeMs){
  const n=operaNowcastInfo(),base=Date.parse(n?.observedAt||state.data?.opera?.observedAt||'');
  if(!n?.series?.length||!Number.isFinite(base))return null;
  const best=n.series.reduce((acc,row)=>{
    const t=base+(Number(row.minute)||0)*60_000,d=Math.abs(t-timeMs);
    return !acc||d<acc.d?{row,d,time:t}:acc;
  },null);
  return best&&best.d<=8*60_000?best.row:null;
}
function aemetPointAt(timeMs){
  const n=aemetNowcastInfo(),base=Date.parse(n?.observedAt||state.data?.aemetRadar?.observedAt||'');
  if(!n?.series?.length||!Number.isFinite(base))return null;
  const best=n.series.reduce((acc,row)=>{
    const t=base+(Number(row.minute)||0)*60_000,d=Math.abs(t-timeMs);
    return !acc||d<acc.d?{row,d,time:t}:acc;
  },null);
  return best&&best.d<=8*60_000?best.row:null;
}
function shortPoints(){
  const now=Date.now(),n=state.nowcast,truth=currentTruth(4),correction=truth===false?feedbackEpisodeCorrection(now):null,rawEvent=chooseDisplayEvent(),rainNow=currentRainState().raining;
  let ev=rawEvent;
  if(correction?.mode==='pause'){
    ev={kind:'resume',active:false,start:new Date(correction.resumeAt).toISOString(),end:new Date(correction.episode.end).toISOString(),confidence:Number(correction.confidence)||0};
  }else if(correction?.mode==='pause_unresolved'){
    ev=null;
  }else if(correction?.mode==='ended_early'){
    ev=nextModelEventAfter(correction.episode.maxEnd+5*60_000);
  }
  const radarBase=Date.parse(n?.radarTime||''),series=Array.isArray(n?.series)?n.series:[];
  const eventStart=ev?.start?Date.parse(ev.start):Infinity,eventEnd=ev?.end?Date.parse(ev.end):Infinity;
  const native15=nativeQuarterHourLikely(),reliability=nowcastReliability(),points=[];
  for(let i=0;i<=SHORT_HORIZON_MINUTES/5;i++){
    const time=now+i*5*60_000,horizon=Math.max(0,(time-now)/60_000);
    let radar=null;
    if(Number.isFinite(radarBase)&&series.length){
      radar=series.reduce((best,row)=>{
        const d=Math.abs((radarBase+(Number(row.minute)||0)*60_000)-time);
        return !best||d<best.d?{row,d}:best;
      },null)?.row||null;
    }
    const operaPoint=operaPointAt(time),aemetPoint=aemetPointAt(time),model=modelPointAt(time);
    const native15Rate=native15?quarterHourRateAt(time):0;
    const modelRate=native15&&native15Rate>0?Math.max(model.rate*.35,native15Rate):model.rate;
    const modelProb=model.probability;
    const radarRate=Number(radar?.radarRate)||0,operaRate=Number(operaPoint?.rateMmH)||0,aemetRate=Number(aemetPoint?.radarRate)||0;
    const radarProb=Math.max(0,Math.min(1,Number(radar?.probability)||0));
    const operaProb=Math.max(0,Math.min(1,Number(operaPoint?.probability)||0));
    const aemetProb=Math.max(0,Math.min(1,Number(aemetPoint?.probability)||0));
    const wetFraction=Number(radar?.wetFraction)||0,operaWetFraction=Number(operaPoint?.wetFraction)||0,aemetWetFraction=Number(aemetPoint?.wetFraction)||0;
    const radarWet=wetFraction>=.10&&radarRate>=.03,operaWet=operaWetFraction>=.10&&operaRate>=.03,aemetWet=aemetWetFraction>=.10&&aemetRate>=.03;
    const sourceRates=[radarWet?radarRate:null,operaWet?operaRate:null,aemetWet?aemetRate:null].filter(Number.isFinite);
    const sourceProbs=[radar?radarProb:null,operaPoint?operaProb:null,aemetPoint?aemetProb:null].filter(Number.isFinite);
    const nowcastRate=sourceRates.length?sourceRates.reduce((a,b)=>a+b,0)/sourceRates.length:0;
    const nowcastProb=sourceProbs.length?sourceProbs.reduce((a,b)=>a+b,0)/sourceProbs.length:0;
    const blend=sourceProbs.length?radarBlendWeight(horizon,reliability):0;
    let rate=nowcastRate*blend+modelRate*(1-blend);
    let probability=nowcastProb*blend+modelProb*(1-blend);
    const inEvent=Boolean(ev)&&time>=eventStart&&time<=eventEnd;
    if(!inEvent&&probability<.34&&rate<.05){probability*=.45;rate*=.35}
    if(rainNow&&i===0){
      rate=Math.max(radarRate,operaRate,aemetRate,Number(n?.currentRadarRate)||0,Number(state.data?.opera?.sample?.rateMmH)||0,Number(state.data?.aemetRadar?.sample?.rateMmH)||0,rate);
      probability=Math.max(probability,.78);
    }
    if(i===0){
      const localTruth=currentTruth();
      if(localTruth===true){probability=1;rate=Math.max(rate,.1)}
      if(localTruth===false){probability=0;rate=0}
    }
    const wet=i===0
      ? rainNow&&rate>.03
      : probability>=.36&&rate>=.03;
    points.push({
      time,probability:Math.max(0,Math.min(1,probability||0)),rate:Math.max(0,rate||0),
      radarRate,operaRate,aemetRate,modelRate,wetFraction,operaWetFraction,aemetWetFraction,inEvent,wet,
      blendWeight:blend,
      dominantSource:blend>=.66?'radar':blend>=.20?'mixed':'models'
    });
  }
  return points;
}
function renderShortNowcast(){
  if(state.selectedHourIndex!==null&&renderSelectedHour())return;
  $('nowcastBody').hidden=false;$('selectedBody').hidden=true;$('shortBack').hidden=true;
  const points=shortPoints(),decision=buildRainDecision(),ev=decision.event,now=decision.now,rain=decision.rain,dry=decision.dry;
  const delayedByRadar=decision.delayedByRadar;
  const near=decision.near;
  const wetPoints=points.filter(p=>p.wet);
  const arrivalPoints=wetPoints.slice(0,Math.min(4,wetPoints.length));
  const arrivalRate=arrivalPoints.length
    ? arrivalPoints.reduce((sum,p)=>sum+p.rate,0)/arrivalPoints.length
    : 0;
  const peakRate=wetPoints.length?Math.max(...wetPoints.map(p=>p.rate)):0;
  const labelRate=rain.raining?Math.max(Number(state.nowcast?.currentRadarRate)||0,Number(state.data?.opera?.sample?.rateMmH)||0,arrivalRate):arrivalRate;
  const compactCorrection=decision.mode==='episode_pause'||decision.mode==='episode_ended_early';
  $('shortDetail').hidden=compactCorrection;
  $('shortWindow').hidden=compactCorrection;
  $('shortState').textContent=decision.mode==='episode_pause'||decision.mode==='episode_ended_early'
    ? 'Tiempo estable'
    : decision.mode==='possible_now'
      ? 'Lluvia no confirmada'
      : near||rain.raining?intensityLabel(labelRate):'Tiempo estable';
  $('shortDetail').textContent=decision.mode==='episode_pause'
    ? decision.correction?.resumeAt
      ? 'Pausa observada · posible reanudación '+fmtTime(decision.correction.resumeAt)+' ('+decision.correction.resumeSource+') · fin previsto del tramo '+fmtTime(decision.correction.episode.end)
      : 'Pausa seca observada · reevaluando si el episodio ha terminado · fin previsto del tramo '+fmtTime(decision.correction?.episode?.end)
    : decision.mode==='episode_ended_early'
      ? 'Episodio recortado: sigue seco · terminó ~'+fmtTime(decision.correction?.observedEnd)+' en vez de '+fmtTime(decision.correction?.episode?.end)
      : decision.mode==='possible_now'
        ? 'El radar marca '+Math.max(Number(rain.radarRate)||0,Number(rain.operaRate)||0).toFixed(1).replace('.',',')+' mm/h sobre el punto, pero no hay corroboración suficiente para afirmar que llueve en superficie'
      : rain.raining
        ? 'Radar / nowcast: '+labelRate.toFixed(1)+' mm/h ahora · RainViewer '+fmtTime(state.nowcast?.radarTime||Date.now())+(state.data?.opera?.observedAt?' · radar europeo '+fmtTime(state.data.opera.observedAt):'')
        : decision.mode==='stable_now'&&decision.stable
          ? 'Sin lluvia prevista en las próximas '+decision.stable.label+'. Radar útil ~'+nowcastReliableHorizon()+' min; después mandan los modelos y el consenso.'
        : delayedByRadar
          ? 'Radar sin precipitación proyectada hasta ~'+fmtTime(dry.end)+'. Los modelos mantienen riesgo después.'
          : near
            ? 'Llegada '+fmtTime(ev.start)+' · '+labelRate.toFixed(1)+' mm/h al inicio · pico ~'+peakRate.toFixed(1)+' mm/h'
            : dry
              ? (dry.horizonLimited
                ? 'Radar sin precipitación proyectada sobre el punto al menos hasta ~'+fmtTime(dry.end)+'. Ese límite es el horizonte fiable, no una ETA de lluvia'
                : 'Radar sin precipitación proyectada sobre el punto hasta ~'+fmtTime(dry.end))+(dry.operaDry?' · OPERA seco ahora':'')
              : 'Sin lluvia probable en las próximas 3 h';
  $('shortEtaLabel').textContent=decision.mode==='episode_pause'
    ? (decision.correction?.resumeAt?'Puede volver en':'Reevaluando')
    : decision.mode==='episode_ended_early'
      ? (ev?.start?'Siguiente riesgo':'Fin confirmado')
      : decision.mode==='possible_now'
        ? 'Señal radar hasta'
      : rain.raining?'Fin estimado':decision.mode==='stable_now'?'Horizonte':delayedByRadar||(!near&&dry)?'Estable hasta':near?'Empieza en':'Próximo cambio';
  $('shortCountdown').textContent=decision.mode==='episode_pause'
    ? (decision.correction?.resumeAt?formatCountdownMs(decision.correction.resumeAt-now):formatCountdownMs(now-Number(decision.correction?.observedEnd||now))+' seco')
    : decision.mode==='episode_ended_early'
      ? (ev?.start?formatCountdownMs(Date.parse(ev.start)-now):'—')
      : decision.mode==='possible_now'
        ? (ev?.end?formatCountdownMs(Date.parse(ev.end)-now):'—')
      : rain.raining
        ? (ev?.end?formatCountdownMs(Date.parse(ev.end)-now):'—')
        : decision.mode==='stable_now'&&decision.stable
          ? decision.stable.label
        : delayedByRadar||(!near&&dry)
          ? formatCountdownMs(Date.parse(dry.end)-now)
          : near?formatCountdownMs(Date.parse(ev.start)-now):'>3 h';
  $('shortWindow').textContent=decision.mode==='episode_pause'
    ? 'Pausa dentro del episodio · fin previsto del tramo '+fmtTime(decision.correction?.episode?.end)
    : decision.mode==='episode_ended_early'
      ? 'Tramo anterior cerrado ~'+fmtTime(decision.correction?.observedEnd)+(ev?.start?' · siguiente '+fmtTime(ev.start):'')
      : decision.mode==='possible_now'
        ? 'Señal de radar actual · no confirmada en superficie'
      : decision.mode==='stable_now'&&decision.stable
        ? 'Sin señal de llegada · previsión estable '+decision.stable.label+' · radar útil ~'+nowcastReliableHorizon()+' min'
      : near
        ? fmtTime(ev.start)+(ev.end?'–'+fmtTime(ev.end):'')+(['radar','opera','aemet','radarFusion'].includes(ev.kind)?' · '+uncertaintyText(ev):'')
        : dry
          ? (dry.horizonLimited
            ? 'Seco confirmado por radar · '+fmtTime(dry.start)+'–'+fmtTime(dry.end)+' · después sin ETA de lluvia'
            : 'Ventana seca radar · '+fmtTime(dry.start)+'–'+fmtTime(dry.end))
          : 'Ventana corta estable';
  const leadMinutes=near?Math.max(0,(Date.parse(ev.start)-now)/60_000):dry?Math.max(0,(Date.parse(dry.end)-now)/60_000):SHORT_HORIZON_MINUTES;
  const shortConfidence=near
    ? calibratedEventConfidence(ev,ev.confidence,leadMinutes)
    : decision.mode==='stable_now'&&decision.stable
      ? Number(decision.stable.confidence)
      : dry&&!dry.horizonLimited
        ? calibratedRadarConfidence(dry.confidence,leadMinutes)
        : null;
  if(shortConfidence!=null){
    const grade=confidenceGrade(shortConfidence);
    $('shortConfidence').textContent=grade.label+' · '+grade.percent+'%';
  }else $('shortConfidence').textContent='—';
  const reliable=nowcastReliableHorizon(),evolution=Number(state.nowcast?.evolution?.score)||0;
  const evolutionLabel=evolution>=.72?'estable':evolution>=.48?'cambiante':'muy cambiante';
  if($('blendLegend')){
    $('blendLegend').innerHTML='<span><b>Radar útil ~'+reliable+' min</b></span><span>la autoridad pasa gradualmente a modelos</span>';
  }
  if($('shortSourceZones')){
    const thresholds=radarBlendThresholds(nowcastReliability()),full=Math.min(SHORT_HORIZON_MINUTES,Math.round(thresholds.full)),zero=Math.min(SHORT_HORIZON_MINUTES,Math.round(thresholds.zero));
    const radarPct=Math.max(0,Math.min(100,full/SHORT_HORIZON_MINUTES*100));
    const mixedPct=Math.max(0,Math.min(100,(zero-full)/SHORT_HORIZON_MINUTES*100));
    const modelPct=Math.max(0,100-radarPct-mixedPct);
    $('shortSourceZones').innerHTML=
      '<span class="sourceZone radar" style="width:'+radarPct+'%"><b>RADAR</b><small>0–'+full+'m</small></span>'+
      '<span class="sourceZone mixed" style="width:'+mixedPct+'%"><b>MEZCLA</b><small>'+full+'–'+zero+'m</small></span>'+
      '<span class="sourceZone models" style="width:'+modelPct+'%"><b>MODELOS</b><small>'+zero+'–180m</small></span>';
  }
  if($('nowcastQuality')){
    $('nowcastQuality').textContent='Evolución '+evolutionLabel+' · radar útil ~'+reliable+' min';
    $('nowcastQuality').className='nowcastQuality '+(evolution>=.72?'good':evolution>=.48?'medium':'low');
  }
  renderRadarSkill();

  const maxRate=Math.max(.35,Math.min(12,Math.max(...points.map(p=>p.rate))));
  $('minuteStrip').innerHTML=points.map((p,i)=>{
    const wet=Boolean(p.wet);
    const band=probabilityBand(p.probability);
    const height=wet?Math.max(8,Math.min(100,8+Math.sqrt(Math.min(p.rate,maxRate)/maxRate)*92)):3;
    return '<div class="minuteCol src-'+p.dominantSource+' '+(wet?'wet '+band+' ':'')+(i===0?'now':'')+'" title="'+fmtTime(p.time)+' · '+(p.dominantSource==='radar'?'radar':p.dominantSource==='mixed'?'radar + modelos':'modelos')+' · prob. '+Math.round(p.probability*100)+'% · intensidad '+p.rate.toFixed(1)+' mm/h"><i class="minuteMark" style="height:'+height+'%"></i></div>';
  }).join('');
  const ticks=[],lastIndex=points.length-1;
  for(let i=0;i<=lastIndex;i+=6){
    const left=lastIndex?i/lastIndex*100:0;
    ticks.push('<span class="minuteTick" style="left:'+left+'%">'+fmtTime(points[i].time)+'</span>');
  }
  $('minuteAxis').innerHTML=ticks.join('');
}
function updateLiveCountdown(){
  if(!state.data||state.selectedHourIndex!==null)return;
  const decision=buildRainDecision(),ev=decision.event,now=decision.now,rain=decision.rain,dry=decision.dry;
  if(!$('shortCountdown'))return;
  if(decision.mode==='episode_pause'){
    $('shortCountdown').textContent=decision.correction?.resumeAt
      ? formatCountdownMs(decision.correction.resumeAt-now)
      : formatCountdownMs(now-Number(decision.correction?.observedEnd||now))+' seco';
    return;
  }
  if(decision.mode==='episode_ended_early'){
    $('shortCountdown').textContent=ev?.start?formatCountdownMs(Date.parse(ev.start)-now):'—';
    return;
  }
  if(decision.mode==='possible_now'){
    $('shortCountdown').textContent=ev?.end?formatCountdownMs(Date.parse(ev.end)-now):'—';
    return;
  }
  if(decision.mode==='stable_now'&&decision.stable){
    $('shortCountdown').textContent=decision.stable.label;
    return;
  }
  if(!ev){
    $('shortCountdown').textContent=dry?formatCountdownMs(Date.parse(dry.end)-now):'>3 h';
    return;
  }
  $('shortCountdown').textContent=rain.raining
    ? (ev.end?formatCountdownMs(Date.parse(ev.end)-now):'—')
    : decision.delayedByRadar||(!decision.near&&dry)
      ? formatCountdownMs(Date.parse(dry.end)-now)
      : decision.near?formatCountdownMs(Date.parse(ev.start)-now):'>3 h';
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
function calibratedRadarConfidence(raw,leadMinutes){
  const stats=radarSkillStats(),lead=[15,30,60,90].reduce((a,b)=>Math.abs(b-leadMinutes)<Math.abs(a-leadMinutes)?b:a,15);
  const sample=stats[lead];
  if(!sample||sample.n<6||sample.accuracy==null||sample.accuracy>=.70)return raw;
  const cap=Math.max(.40,Math.min(.78,Number(sample.accuracy)+.10));
  return Math.min(raw,cap);
}
function conservativeSkillCap(raw,source,leadMinutes){
  const skill=sourceSkillFor(source,leadMinutes);
  if(!skill||skill.n<5||skill.accuracy==null||skill.accuracy>=.70)return raw;
  const cap=Math.max(.40,Math.min(.78,Number(skill.accuracy)+.10));
  return Math.min(raw,cap);
}
function calibratedEventConfidence(event,raw,leadMinutes){
  if(!event)return raw;
  if(event.kind==='radar')return calibratedRadarConfidence(raw,leadMinutes);
  if(event.kind==='opera')return conservativeSkillCap(raw,'opera',leadMinutes);
  if(event.kind==='aemet')return conservativeSkillCap(raw,'aemet',leadMinutes);
  if(event.kind==='model'||event.kind==='model15')return conservativeSkillCap(raw,'models',leadMinutes);
  if(event.kind==='radarFusion'){
    const ids=new Set((event.sources||[]).map(x=>String(x).toLowerCase()));
    const skills=[];
    if(!ids.size||[...ids].some(x=>x.includes('radar')||x.includes('rainviewer')))skills.push(sourceSkillFor('rainviewer',leadMinutes));
    if(!ids.size||[...ids].some(x=>x.includes('opera')))skills.push(sourceSkillFor('opera',leadMinutes));
    if([...ids].some(x=>x.includes('aemet')))skills.push(sourceSkillFor('aemet',leadMinutes));
    const ready=skills.filter(x=>x&&x.n>=5&&x.accuracy!=null);
    if(ready.length<2)return raw;
    const accuracy=ready.reduce((sum,x)=>sum+Number(x.accuracy),0)/ready.length;
    if(!Number.isFinite(accuracy)||accuracy>=.70)return raw;
    return Math.min(raw,Math.max(.40,Math.min(.78,accuracy+.10)));
  }
  return raw;
}
function renderRadarSkill(){
  const stats=radarSkillStats(),episodeStats=episodeLearningStats();
  const ready=[15,30,60,90].filter(lead=>stats[lead].n>=3);
  let text;
  if(!ready.length){
    const n=[15,30,60,90].reduce((sum,lead)=>sum+stats[lead].n,0);
    text='Autoevaluación radar: '+(n?'aprendiendo ('+n+' comprobaciones)':'iniciando historial…');
  }else{
    text='Autoevaluación radar · '+ready.map(lead=>lead+' min '+Math.round(stats[lead].accuracy*100)+'% ('+stats[lead].n+')').join(' · ');
  }
  if(episodeStats.count){
    text+=' · finales de episodio: '+episodeStats.count+' corrección'+(episodeStats.count===1?'':'es');
    if(episodeStats.bias>0)text+=' · sesgo observado '+Math.round(episodeStats.bias)+' min antes';
  }
  $('skillText').textContent=text;
}

function sourceSkillKey(){return 'raineta.sourceSkill.'+locationKey(state.loc)}
function readSourceSkill(){return readLocal(sourceSkillKey(),{snapshots:[],scores:[]})}
function writeSourceSkill(data){
  try{localStorage.setItem(sourceSkillKey(),JSON.stringify(data))}catch{}
}
function radarPredictionAt(timeMs){
  const n=state.nowcast,base=Date.parse(n?.radarTime||''),series=Array.isArray(n?.series)?n.series:[];
  if(!Number.isFinite(base)||!series.length)return null;
  const best=series.reduce((acc,row)=>{
    const t=base+(Number(row.minute)||0)*60_000,d=Math.abs(t-timeMs);
    return !acc||d<acc.d?{row,d}:acc;
  },null);
  if(!best||best.d>9*60_000)return null;
  const row=best.row,wet=(Number(row.wetFraction)||0)>=.10&&(Number(row.radarRate)||0)>=.03;
  return{predicted:wet,probability:Math.max(0,Math.min(1,Number(row.probability)||0))};
}
function operaPredictionAt(timeMs){
  const row=operaPointAt(timeMs);
  if(!row)return null;
  const wet=(Number(row.wetFraction)||0)>=.10&&(Number(row.rateMmH)||0)>=.03;
  return{predicted:wet,probability:Math.max(0,Math.min(1,Number(row.probability)||0))};
}
function aemetPredictionAt(timeMs){
  const row=aemetPointAt(timeMs);
  if(!row)return null;
  const wet=(Number(row.wetFraction)||0)>=.10&&(Number(row.radarRate)||0)>=.03;
  return{predicted:wet,probability:Math.max(0,Math.min(1,Number(row.probability)||0))};
}
function modelPredictionAt(timeMs){
  const rows=state.data?.timeline||[];
  const best=rows.reduce((acc,row)=>{
    const d=Math.abs(Date.parse(row.time)-timeMs);
    return !acc||d<acc.d?{row,d}:acc;
  },null);
  if(!best||best.d>75*60_000)return null;
  const row=best.row,p=Math.max(0,Math.min(1,(Number(row.probability)||0)/100));
  const signal=classifyRainHour({probability:p,expectedPrecipitation:Number(row.precipitation)||0});
  const qhRate=quarterHourRateAt(timeMs);
  const predicted=signal==='wet'||(qhRate>=.05&&p>=.36);
  return{predicted,probability:Math.max(p,qhRate>=.05?.48:0)};
}
function observedSkillTruth(){
  const feedback=currentTruth();
  if(feedback!==null)return{actual:Boolean(feedback),exclude:[],source:'feedback'};
  const n=state.nowcast,radarAge=Date.now()-Date.parse(n?.radarTime||''),radarWet=Number(n?.currentWetFraction);
  const rvOk=(n?.status==='ok'||n?.status==='motion_uncertain')&&Number.isFinite(radarWet)&&Number.isFinite(radarAge)&&radarAge<=20*60_000;
  const rv=rvOk?radarWet>=calibratedRadarThreshold():null;
  const opera=state.data?.opera,sample=opera?.sample,quality=Number(sample?.quality),rate=Number(sample?.rateMmH);
  const opOk=Boolean(sample?.ok&&operaFreshness(opera,OPERA_SURFACE_STALE_MINUTES).ok&&quality>=.5&&Number.isFinite(rate));
  const op=opOk?rate>=.05:null;
  const aemet=state.data?.aemetRadar,aemetRate=Number(aemet?.sample?.rateMmH),aemetWet=Number(aemet?.sample?.wetFraction);
  const aeOk=Boolean(aemetRadarFreshness(aemet,20).ok&&Number.isFinite(aemetRate));
  const ae=aeOk?aemetRate>=.05&&(!Number.isFinite(aemetWet)||aemetWet>=.15):null;
  const votes=[];
  if(rvOk)votes.push(['rainviewer',rv]);
  if(opOk)votes.push(['opera',op]);
  if(aeOk)votes.push(['aemet',ae]);
  if(votes.length>=2){
    const wet=votes.filter(([,value])=>value===true).length,dry=votes.filter(([,value])=>value===false).length;
    if(wet===dry)return null;
    return{actual:wet>dry,exclude:[],source:votes.map(([id])=>id).join('+')};
  }
  if(rvOk)return{actual:rv,exclude:['rainviewer'],source:'rainviewer'};
  if(opOk)return{actual:op,exclude:['opera'],source:'opera'};
  if(aeOk)return{actual:ae,exclude:['aemet'],source:'aemet'};
  return null;
}
function sourceSkillStats(){
  const data=readSourceSkill(),out={};
  for(const source of ['rainviewer','opera','aemet','models']){
    const rows=(data.scores||[]).filter(x=>x.source===source);
    const byHorizon={};
    for(const horizon of [15,30,60,90,120]){
      const h=rows.filter(x=>Number(x.horizon)===horizon);
      byHorizon[h]={n:h.length,accuracy:h.length?h.filter(x=>x.correct).length/h.length:null};
    }
    out[source]={n:rows.length,accuracy:rows.length?rows.filter(x=>x.correct).length/rows.length:null,byHorizon};
  }
  return out;
}
function sourceSkillFor(source,leadMinutes){
  const stats=sourceSkillStats()?.[source];
  if(!stats)return null;
  const horizon=[15,30,60,90,120].reduce((a,b)=>Math.abs(b-leadMinutes)<Math.abs(a-leadMinutes)?b:a,15);
  const h=stats.byHorizon?.[horizon];
  if(h?.n>=5&&h.accuracy!=null)return{accuracy:h.accuracy,n:h.n,horizon};
  if(stats.n>=8&&stats.accuracy!=null)return{accuracy:stats.accuracy,n:stats.n,horizon:null};
  return null;
}
function updateSourceSkill(){
  if(!state.data)return;
  const now=Date.now(),truth=observedSkillTruth(),data=readSourceSkill();
  data.snapshots=Array.isArray(data.snapshots)?data.snapshots:[];
  data.scores=Array.isArray(data.scores)?data.scores:[];
  for(const snap of data.snapshots){
    snap.done=snap.done||{};
    for(const forecast of snap.forecasts||[]){
      const key=forecast.source+':'+forecast.horizon;
      if(snap.done[key])continue;
      const age=now-Number(forecast.targetMs);
      if(age>15*60_000){snap.done[key]='missed';continue}
      if(age<-2*60_000||!truth)continue;
      if((truth.exclude||[]).includes(forecast.source)){snap.done[key]='self_truth';continue}
      const actual=Boolean(truth.actual),predicted=Boolean(forecast.predicted);
      data.scores.push({
        time:now,issuedAt:Number(snap.issuedAt),targetMs:Number(forecast.targetMs),
        source:forecast.source,horizon:Number(forecast.horizon),predicted,actual,
        correct:predicted===actual,probability:Number(forecast.probability)||0,
        truthSource:truth.source
      });
      snap.done[key]='scored';
    }
  }
  const last=data.snapshots.at(-1);
  if(!last||now-Number(last.issuedAt)>=9*60_000){
    const forecasts=[];
    for(const horizon of [15,30,60,90,120]){
      const targetMs=now+horizon*60_000;
      const predictions=[
        ['rainviewer',radarPredictionAt(targetMs)],
        ['opera',operaPredictionAt(targetMs)],
        ['aemet',aemetPredictionAt(targetMs)]
      ];
      if(!state.data?.degradedForecast)predictions.push(['models',modelPredictionAt(targetMs)]);
      for(const [source,prediction] of predictions){
        if(prediction)forecasts.push({source,horizon,targetMs,...prediction});
      }
    }
    if(forecasts.length)data.snapshots.push({issuedAt:now,forecasts,done:{}});
  }
  data.snapshots=data.snapshots.filter(x=>now-Number(x.issuedAt)<7*24*3600_000).slice(-180);
  data.scores=data.scores.filter(x=>now-Number(x.time)<30*24*3600_000).slice(-900);
  writeSourceSkill(data);
}
function renderSourceSkill(){
  const el=$('sourceSkillText');if(!el)return;
  const stats=sourceSkillStats(),labels={rainviewer:'RainViewer',opera:'OPERA',aemet:'AEMET radar',models:'Modelos'};
  const ready=Object.entries(stats).filter(([,s])=>s.n>=3&&s.accuracy!=null).sort((a,b)=>b[1].accuracy-a[1].accuracy);
  const n=Object.values(stats).reduce((sum,s)=>sum+s.n,0);
  if(!ready.length){
    el.textContent='Comparador local de fuentes: '+(n?'aprendiendo ('+n+' verificaciones)':'iniciando historial…');
    return;
  }
  el.textContent='Acierto local 0–2 h · '+ready.map(([id,s],i)=>(i===0?'★ ':'')+labels[id]+' '+Math.round(s.accuracy*100)+'% ('+s.n+')').join(' · ');
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
function radarMotionHistoryKey(){return 'raineta.radarMotion.'+locationKey(state.loc)}
function readRadarMotionHistory(){return readLocal(radarMotionHistoryKey(),[])}
function writeRadarMotionHistory(rows){
  try{localStorage.setItem(radarMotionHistoryKey(),JSON.stringify(rows.slice(-12)))}catch{}
}
function signedBearingDelta(from,to){
  return ((Number(to)-Number(from)+540)%360)-180;
}
function recordRadarMotionObservation(){
  const n=state.nowcast,m=n?.motion,radarMs=Date.parse(n?.radarTime||'');
  const speed=Number(m?.speedKmh),bearing=Number(m?.bearingDegrees),confidence=Number(n?.confidence)||0;
  if(n?.status!=='ok'||!Number.isFinite(radarMs)||!Number.isFinite(speed)||!Number.isFinite(bearing)||speed<2||speed>220||confidence<.30)return;
  let rows=readRadarMotionHistory().filter(x=>radarMs-Number(x.radarMs)<75*60_000);
  if(rows.some(x=>Number(x.radarMs)===radarMs))return;
  rows.push({radarMs,speed,bearing:(bearing%360+360)%360,confidence});
  rows.sort((a,b)=>a.radarMs-b.radarMs);
  writeRadarMotionHistory(rows);
}
function radarTurnTrend(){
  const nowMs=Date.parse(state.nowcast?.radarTime||'');
  if(!Number.isFinite(nowMs))return null;
  const rows=readRadarMotionHistory()
    .filter(x=>nowMs-Number(x.radarMs)<=40*60_000&&nowMs-Number(x.radarMs)>=0&&Number(x.confidence)>=.38)
    .slice(-5);
  if(rows.length<3)return null;
  const spanMinutes=(Number(rows.at(-1).radarMs)-Number(rows[0].radarMs))/60_000;
  if(spanMinutes<10||spanMinutes>40)return null;
  const rates=[];
  for(let i=1;i<rows.length;i++){
    const dt=(Number(rows[i].radarMs)-Number(rows[i-1].radarMs))/60_000;
    if(dt<3||dt>15)continue;
    const delta=signedBearingDelta(rows[i-1].bearing,rows[i].bearing);
    if(Math.abs(delta)>22)continue;
    rates.push(delta/dt);
  }
  if(rates.length<2)return null;
  const rate=medianNumber(rates);
  if(!Number.isFinite(rate)||Math.abs(rate)<.04||Math.abs(rate)>.8)return null;
  const sameSign=rates.filter(x=>Math.sign(x)===Math.sign(rate)).length/rates.length;
  if(sameSign<.75)return null;
  const avgConfidence=rows.reduce((sum,x)=>sum+(Number(x.confidence)||0),0)/rows.length;
  const confidence=Math.max(0,Math.min(1,avgConfidence*sameSign));
  if(confidence<.50)return null;
  return{rateDegPerMinute:rate,confidence,samples:rows.length,spanMinutes};
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
  if(rows.length<2)return {...raw,rawStart:raw.start,stabilizationSamples:rows.length||1,historicalSpreadMinutes:0};
  const medianStartMs=medianNumber(rows.map(x=>Number(x.startMs)));
  const spreadMinutes=Number.isFinite(medianStartMs)
    ? Math.max(...rows.map(x=>Math.abs(Number(x.startMs)-medianStartMs)))/60_000
    : 0;
  return{
    ...raw,
    start:raw.start,
    end:raw.end,
    rawStart:raw.start,
    historicalMedianStart:Number.isFinite(medianStartMs)?new Date(medianStartMs).toISOString():null,
    stabilizationSamples:rows.length,
    historicalSpreadMinutes:Math.round(spreadMinutes),
    uncertaintyMinutes:Math.max(Number(raw.uncertaintyMinutes)||0,Math.round(spreadMinutes))
  };
}
function canonicalEtaHistoryKey(){return 'raineta.canonicalEta.'+locationKey(state.loc)}
function etaTrendText(ev){
  if(!ev?.start)return'';
  const marker=ev.kind==='radar'
    ? (state.nowcast?.radarTime||'radar')
    : ev.kind==='opera'
      ? (state.data?.opera?.observedAt||'opera')
      : ev.kind==='radarFusion'
        ? (state.nowcast?.radarTime||'radar')+'|'+(state.data?.opera?.observedAt||'opera')
        : (state.data?.generatedAt||'model');
  let rows=readLocal(canonicalEtaHistoryKey(),[]);
  let current=rows.find(x=>x.marker===marker);
  if(!current){
    current={marker,time:Date.now(),start:Date.parse(ev.start),kind:ev.kind};
    rows.push(current);rows=rows.slice(-10);
    try{localStorage.setItem(canonicalEtaHistoryKey(),JSON.stringify(rows))}catch{}
  }
  const idx=rows.findIndex(x=>x.marker===marker),prev=idx>0?rows[idx-1]:null;
  const parts=[];
  if(ev.kind==='radarFusion'){
    parts.push('ETA cruzada radar + radar europeo');
  }
  if(ev.disagreementMinutes){
    const chosen=ev.kind==='opera'?'radar europeo':'radar RainViewer';
    if(ev.adaptiveChoice&&ev.localSkill?.chosen){
      parts.push('Radar y radar europeo discrepan ~'+ev.disagreementMinutes+' min · se prioriza '+chosen+' por mejor acierto local ('+Math.round(ev.localSkill.chosen.accuracy*100)+'%, '+ev.localSkill.chosen.n+' verificaciones)');
    }else{
      parts.push('Radar y radar europeo discrepan ~'+ev.disagreementMinutes+' min · se prioriza '+chosen+' por confianza instantánea');
    }
  }
  if(ev.kind==='radar'&&ev.event?.stabilizationSamples>=2){
    const s=ev.event,spread=Number(s.historicalSpreadMinutes)||0;
    parts.push('ETA actual contrastada con '+s.stabilizationSamples+' barridos'+(spread>=4?' · variación reciente ±'+spread+' min':''));
  }
  if(prev&&Number.isFinite(prev.start)){
    const delta=Math.round((Date.parse(ev.start)-Number(prev.start))/60_000);
    if(Math.abs(delta)>=5)parts.push('revisión '+(delta>0?'+':'')+delta+' min desde '+fmtTime(prev.time));
  }
  return parts.join(' · ');
}

function refineWithQuarterHour(event,qh){
  if(!event||!qh?.events?.length||!nativeQuarterHourLikely())return event;
  const e0=Date.parse(event.start),best=qh.events.map(e=>({...e,dist:Math.abs(Date.parse(e.start)-e0)})).sort((a,b)=>a.dist-b.dist)[0];
  if(!best||best.dist>3*3600_000)return event;
  return{...event,displayStart:best.start,displayEnd:best.end,quarterHourRefined:true};
}

function modelRiskWithin(minutes=120){
  const now=Date.now(),end=now+minutes*60_000;
  const probs=(state.data?.timeline||[])
    .filter(row=>{
      const t=Date.parse(row.time);
      return Number.isFinite(t)&&t>=now-60*60_000&&t<=end;
    })
    .map(row=>Number(row.probability))
    .filter(Number.isFinite);
  return probs.length?Math.max(...probs):null;
}
function forecastStableWindow(now=Date.now()){
  if(!state.data||state.data.degradedForecast)return null;
  const rows=(state.data.timeline||[])
    .map(row=>{
      const time=Date.parse(row.time);
      const probability=Math.max(0,Math.min(1,(Number(row.probability)||0)/100));
      const expected=Math.max(0,Number(row.precipitation)||0);
      const families=Number(row.independentFamilies??row.independentFamilyCount);
      const signal=classifyRainHour({
        probability,
        expectedPrecipitation:expected,
        independentFamilyCount:Number.isFinite(families)?families:undefined
      });
      return{time,probability,expected,signal,confidence:Number(row.confidence)||0};
    })
    .filter(row=>Number.isFinite(row.time)&&row.time>=now-30*60_000&&row.time<=now+25*3600_000)
    .sort((a,b)=>a.time-b.time);
  if(!rows.length)return null;

  const health=state.data?.sources?.health;
  const healthRatio=Number(health?.total)>0?Math.max(0,Math.min(1,Number(health.available)/Number(health.total))):.5;
  const radarDry=localDryEvidence();
  const radarSupport=radarDry.dryCount>=2?.10:radarDry.dryCount===1?.05:0;

  const candidates=[
    {hours:24,maxRisk:.35},
    {hours:12,maxRisk:.40},
    {hours:6,maxRisk:.45},
    {hours:3,maxRisk:.50}
  ];
  for(const candidate of candidates){
    const end=now+candidate.hours*3600_000;
    const covered=rows.filter(row=>row.time<=end+45*60_000);
    const last=covered.at(-1);
    if(!last||last.time<end-75*60_000)continue;
    const within=covered.filter(row=>row.time>=now-30*60_000&&row.time<=end+15*60_000);
    if(!within.length)continue;
    if(within.some(row=>row.signal==='wet'))continue;
    const maxRisk=Math.max(...within.map(row=>row.probability),0);
    const maxExpected=Math.max(...within.map(row=>row.expected),0);
    if(maxRisk>candidate.maxRisk&&maxExpected>=.03)continue;
    const meanConfidence=within.map(row=>row.confidence).filter(Number.isFinite);
    const confidenceSignal=meanConfidence.length
      ? Math.max(0,Math.min(1,meanConfidence.reduce((a,b)=>a+b,0)/meanConfidence.length/100))
      : .55;
    const confidence=Math.max(.42,Math.min(.90,
      .30+.27*(1-maxRisk)+.18*healthRatio+.15*confidenceSignal+radarSupport
    ));
    return{
      start:new Date(now).toISOString(),
      end:new Date(end).toISOString(),
      hours:candidate.hours,
      maxRisk,
      maxExpected,
      confidence,
      healthRatio,
      radarSupport:radarDry.dryCount,
      label:candidate.hours>=24?'24 h':candidate.hours+' h'
    };
  }
  return null;
}
function consensusDecisionText(decision=buildRainDecision()){
  if(!state.data)return'';
  const n=state.nowcast,radarUsable=n?.status==='ok'||n?.status==='motion_uncertain';
  const radarWet=radarUsable&&Number.isFinite(Number(n?.currentWetFraction))
    ? Number(n.currentWetFraction)>=CANONICAL_RADAR_THRESHOLD
    : null;
  const radarLabel=radarWet===null?'sin nowcast fiable':radarWet?'lluvia':'seco';
  const opera=state.data?.opera,sample=opera?.sample;
  const operaFresh=Boolean(sample?.ok&&operaFreshness(opera,OPERA_SURFACE_STALE_MINUTES).ok);
  const operaRate=Number(sample?.rateMmH);
  const operaEta=operaEventCandidate(decision.now),operaAge=Number(opera?.ageMinutes);
  const operaLabel=operaFresh&&Number.isFinite(operaRate)
    ? (operaRate<.02?'seco':'lluvia '+operaRate.toFixed(1).replace('.',',')+' mm/h')+(operaEta&&!operaEta.active?' · posible lluvia '+fmtTime(operaEta.start):operaEta?.active?' · lluvia ahora':'')
    : operaEta
      ? 'posible lluvia '+fmtTime(operaEta.start)
      : 'sin dato reciente';
  const modelLabel=decision.modelRisk==null?'sin dato':('riesgo '+Math.round(decision.modelRisk)+' %');
  const practical=decision.mode==='rain_now'
    ? 'lluvia ahora'
    : decision.mode==='possible_now'
      ? 'señal de precipitación no confirmada en superficie'
    : decision.mode==='episode_pause'
      ? decision.correction?.resumeAt
        ? 'pausa seca · posible reanudación '+fmtTime(decision.correction.resumeAt)
        : 'pausa seca · episodio en reevaluación'
      : decision.mode==='episode_ended_early'
        ? decision.event?.start
          ? 'episodio terminado antes · siguiente riesgo '+fmtTime(decision.event.start)
          : 'episodio terminado antes'
        : decision.mode==='stable_now'&&decision.stable
          ? 'tiempo estable · sin lluvia prevista en las próximas '+decision.stable.label
          : decision.mode==='dry_now'&&decision.dryUntil
            ? 'ventana estable hasta '+fmtTime(decision.dryUntil)
          : decision.near&&decision.event
            ? 'posible lluvia '+fmtTime(decision.event.start)
            : decision.event
              ? 'sin lluvia inmediata · siguiente riesgo '+fmtTime(decision.event.start)
              : 'seco en 0–2 h';
  return'Radar: '+radarLabel+' · Radar europeo: '+operaLabel+' · Modelos: '+modelLabel+' → '+practical.charAt(0).toUpperCase()+practical.slice(1);
}
function renderConsensusDecision(decision=buildRainDecision()){
  const el=$('consensusLine');if(!el)return;
  el.textContent=consensusDecisionText(decision);
  el.title='Radar europeo = red EUMETNET OPERA, que combina radares meteorológicos europeos.';
}

function operaNowcastInfo(){
  const opera=state.data?.opera,nowcast=opera?.nowcast;
  if(!operaFreshness(opera).ok||nowcast?.status!=='ok'||!Array.isArray(nowcast.series))return null;
  return nowcast;
}
function operaEventCandidate(now=Date.now()){
  const n=operaNowcastInfo(),e=n?.event,age=Number(state.data?.opera?.ageMinutes);
  const freshness=age<=OPERA_SURFACE_STALE_MINUTES?1:Math.max(.65,1-(age-OPERA_SURFACE_STALE_MINUTES)/30);
  const confidence=(Number(n?.confidence)||0)*freshness;
  if(!e?.start||confidence<.22)return null;
  const start=Date.parse(e.start),end=Date.parse(e.end||'');
  if(!Number.isFinite(start)||!Number.isFinite(end)||end<=now)return null;
  return{
    kind:'opera',
    active:start<=now&&end>now&&currentTruth()!==false,
    start:e.start,end:e.end,
    confidence,
    rawConfidence:Number(n.confidence)||0,
    freshness,
    ageMinutes:age,
    uncertainty:Math.round((Number(e.uncertaintyMinutes)||10)+(age>20?(age-20)*.5:0)),
    event:e,
    motion:n.motion||null
  };
}
function aemetEventCandidate(now=Date.now()){
  const n=aemetNowcastInfo(),e=n?.event,age=Number(state.data?.aemetRadar?.ageMinutes);
  const freshness=age<=20?1:Math.max(.60,1-(age-20)/25);
  const confidence=(Number(n?.confidence)||0)*freshness;
  if(!e?.start||confidence<.24)return null;
  const start=Date.parse(e.start),end=Date.parse(e.end||'');
  if(!Number.isFinite(start)||!Number.isFinite(end)||end<=now)return null;
  return{
    kind:'aemet',
    active:start<=now&&end>now&&currentTruth()!==false,
    start:e.start,end:e.end,
    confidence,
    rawConfidence:Number(n.confidence)||0,
    freshness,
    ageMinutes:age,
    uncertainty:Math.round((Number(e.uncertaintyMinutes)||10)+(age>20?(age-20)*.6:0)),
    event:e,
    motion:n.motion||null
  };
}
function fuseAemetRadarEvent(base,aemet,now=Date.now()){
  if(!base)return aemet;
  if(!aemet)return base;
  const delta=Math.abs(Date.parse(base.start)-Date.parse(aemet.start))/60_000;
  const bw=Math.max(.1,Number(base.confidence)||0),aw=Math.max(.1,Number(aemet.confidence)||0);
  if(delta>30){
    const winner=bw>=aw?base:aemet;
    const penalty=Math.min(.22,.07+Math.max(0,delta-30)/500);
    return{
      ...winner,
      confidence:Math.max(.15,(Number(winner.confidence)||0)-penalty),
      uncertainty:Math.max(Number(winner.uncertainty)||10,Math.round(10+delta*.35)),
      disagreementMinutes:Math.round(delta),
      alternate:winner===base?aemet:base,
      sources:[...(base.sources||[base.kind]),'AEMET']
    };
  }
  const start=blendIso(base.start,aemet.start,bw,aw),end=blendIso(base.end,aemet.end,bw,aw);
  const agreement=Math.max(0,1-delta/30);
  return{
    kind:'radarFusion',
    active:Date.parse(start)<=now&&(!end||Date.parse(end)>now),
    start,end,
    confidence:Math.min(.97,.44*bw+.44*aw+.12*agreement),
    uncertainty:Math.max(4,Math.round(((Number(base.uncertainty)||9)+(Number(aemet.uncertainty)||10))/2+delta*.22)),
    event:{start,end},
    sources:[...(base.sources||[base.kind]),'AEMET'],
    baseRadar:base,
    aemet,
    motion:aw>bw?aemet.motion:base.motion
  };
}
function blendIso(a,b,wa,wb){
  const ta=Date.parse(a||''),tb=Date.parse(b||'');
  if(!Number.isFinite(ta))return b||null;
  if(!Number.isFinite(tb))return a||null;
  const total=Math.max(.001,wa+wb);
  return new Date((ta*wa+tb*wb)/total).toISOString();
}
function fuseRadarEvents(rv,op,now=Date.now()){
  if(!rv)return op;
  if(!op)return rv;
  const delta=Math.abs(Date.parse(rv.start)-Date.parse(op.start))/60_000;
  if(delta>30){
    const rvConfidence=Number(rv.confidence)||0,opConfidence=Number(op.confidence)||0;
    const rvLead=Math.max(0,(Date.parse(rv.start)-now)/60_000),opLead=Math.max(0,(Date.parse(op.start)-now)/60_000);
    const rvSkill=sourceSkillFor('rainviewer',rvLead),opSkill=sourceSkillFor('opera',opLead);
    const enoughLocalSkill=Boolean(rvSkill&&opSkill);
    const skillGap=enoughLocalSkill?Math.abs(Number(rvSkill.accuracy)-Number(opSkill.accuracy)):0;
    const adaptiveChoice=enoughLocalSkill&&skillGap>=.08;
    const rvScore=adaptiveChoice ? .72*rvConfidence+.28*Number(rvSkill.accuracy) : rvConfidence;
    const opScore=adaptiveChoice ? .72*opConfidence+.28*Number(opSkill.accuracy) : opConfidence;
    const winner=rvScore>=opScore?rv:op,alternate=winner===rv?op:rv;
    const chosenSkill=winner===rv?rvSkill:opSkill;
    const penalty=Math.min(.22,.06+Math.max(0,delta-30)/600);
    const confidence=Math.max(.15,(Number(winner.confidence)||0)-penalty);
    const uncertainty=Math.max(Number(winner.uncertainty)||10,Math.round(10+delta*.35));
    return{
      ...winner,confidence,uncertainty,disagreementMinutes:Math.round(delta),alternate,adaptiveChoice,
      choiceReason:adaptiveChoice?'local_skill':'instant_confidence',
      localSkill:adaptiveChoice?{
        rainviewer:{accuracy:Number(rvSkill.accuracy),n:Number(rvSkill.n),horizon:rvSkill.horizon},
        opera:{accuracy:Number(opSkill.accuracy),n:Number(opSkill.n),horizon:opSkill.horizon},
        chosen:{accuracy:Number(chosenSkill?.accuracy),n:Number(chosenSkill?.n)}
      }:null
    };
  }
  const rw=Math.max(.1,Number(rv.confidence)||0),ow=Math.max(.1,Number(op.confidence)||0);
  const start=blendIso(rv.start,op.start,rw,ow),end=blendIso(rv.end,op.end,rw,ow);
  const agreement=Math.max(0,1-delta/30);
  const confidence=Math.min(.97,.48*rw+.42*ow+.10*agreement);
  return{
    kind:'radarFusion',
    active:Date.parse(start)<=now&&(!end||Date.parse(end)>now),
    start,end,confidence,
    uncertainty:Math.max(4,Math.round(((Number(rv.uncertainty)||8)+(Number(op.uncertainty)||10))/2+delta*.25)),
    event:{start,end},
    sources:['RainViewer','OPERA'],
    rainViewer:rv,
    opera:op,
    motion:rw>=ow?state.nowcast?.motion:op.motion
  };
}
function dryFeedbackStreak(maxAgeMinutes=25){
  if(!state.currentLocation||!samePlace(state.loc,state.currentLocation))return null;
  const cutoff=Date.now()-maxAgeMinutes*60_000;
  const rows=state.feedback.filter(x=>x.time>=cutoff&&samePlace(x,state.currentLocation,.0015)).sort((a,b)=>a.time-b.time);
  const tail=[];
  for(let i=rows.length-1;i>=0;i--){
    if(rows[i].raining===true)break;
    tail.unshift(rows[i]);
  }
  if(!tail.length)return null;
  return{
    count:tail.length,
    firstTime:Number(tail[0].time),
    lastTime:Number(tail.at(-1).time),
    spanMinutes:Math.max(0,(Number(tail.at(-1).time)-Number(tail[0].time))/60_000)
  };
}
function localDryEvidence(){
  const n=state.nowcast,radarWet=Number(n?.currentWetFraction),radarRate=Number(n?.currentRadarRate);
  const radarFresh=Boolean((n?.status==='ok'||n?.status==='motion_uncertain')&&n?.radarTime&&(Date.now()-Date.parse(n.radarTime))<=20*60_000);
  const radarDry=radarFresh&&Number.isFinite(radarWet)&&radarWet<CANONICAL_RADAR_THRESHOLD&&(Number.isFinite(radarRate)?radarRate<.05:true);
  const opera=state.data?.opera,sample=opera?.sample,operaRate=Number(sample?.rateMmH),operaQuality=Number(sample?.quality);
  const operaFresh=Boolean(sample?.ok&&operaFreshness(opera,OPERA_SURFACE_STALE_MINUTES).ok&&operaQuality>=.5&&Number.isFinite(operaRate));
  const operaDry=operaFresh&&operaRate<.02;
  const aemet=state.data?.aemetRadar,aemetRate=Number(aemet?.sample?.rateMmH),aemetWet=Number(aemet?.sample?.wetFraction);
  const aemetFresh=Boolean(aemetRadarFreshness(aemet,20).ok&&Number.isFinite(aemetRate));
  const aemetDry=aemetFresh&&aemetRate<.02&&(!Number.isFinite(aemetWet)||aemetWet<.15);
  const dryCount=[radarDry,operaDry,aemetDry].filter(Boolean).length;
  const freshCount=[radarFresh,operaFresh,aemetFresh].filter(Boolean).length;
  return{radarFresh,radarDry,operaFresh,operaDry,aemetFresh,aemetDry,dryCount,freshCount,bothDry:dryCount>=2,anyDry:dryCount>=1};
}
function rawOngoingEpisode(now=Date.now()){
  const candidates=[];
  const rv=stabilizedRadarEvent(),rvStart=Date.parse(rv?.start||''),rvEnd=Date.parse(rv?.end||'');
  if(Number(state.nowcast?.confidence)>=.30&&Number.isFinite(rvStart)&&Number.isFinite(rvEnd)&&rvStart<=now&&rvEnd>now){
    candidates.push({source:'RainViewer',start:rvStart,end:rvEnd,confidence:Number(state.nowcast.confidence)||0});
  }
  const op=operaNowcastInfo(),oe=op?.event,opStart=Date.parse(oe?.start||''),opEnd=Date.parse(oe?.end||'');
  if(Number(op?.confidence)>=.22&&Number.isFinite(opStart)&&Number.isFinite(opEnd)&&opStart<=now&&opEnd>now){
    candidates.push({source:'OPERA',start:opStart,end:opEnd,confidence:Number(op.confidence)||0});
  }
  const ae=aemetNowcastInfo(),aeEvent=ae?.event,aeStart=Date.parse(aeEvent?.start||''),aeEnd=Date.parse(aeEvent?.end||'');
  if(Number(ae?.confidence)>=.24&&Number.isFinite(aeStart)&&Number.isFinite(aeEnd)&&aeStart<=now&&aeEnd>now){
    candidates.push({source:'AEMET radar',start:aeStart,end:aeEnd,confidence:Number(ae.confidence)||0});
  }
  const model=(state.data?.events||[]).find(e=>{
    const s=Date.parse(e.start),end=Date.parse(e.end);
    return Number(e.timingConfidence||0)>=.35&&Number.isFinite(s)&&Number.isFinite(end)&&s<=now&&end>now;
  });
  if(model)candidates.push({source:model.quarterHourRefined?'modelos+15m':'modelos',start:Date.parse(model.start),end:Date.parse(model.end),confidence:Number(model.timingConfidence)||0});
  if(!candidates.length)return null;
  const primary=candidates.slice().sort((a,b)=>b.confidence-a.confidence)[0];
  return{
    start:Math.min(...candidates.map(x=>x.start)),
    end:primary.end,
    maxEnd:Math.max(...candidates.map(x=>x.end)),
    source:primary.source,
    confidence:primary.confidence,
    candidates
  };
}
function nextProjectedWetTime(now=Date.now(),limitMs=now+120*60_000){
  const candidates=[];
  const n=state.nowcast,radarBase=Date.parse(n?.radarTime||'');
  if(Number.isFinite(radarBase)&&Array.isArray(n?.series)){
    for(const row of n.series){
      const t=radarBase+(Number(row.minute)||0)*60_000;
      if(t<=now+2*60_000||t>limitMs)continue;
      const wet=(Number(row.wetFraction)||0)>=.10&&(Number(row.radarRate)||0)>=.03;
      if(wet){candidates.push({time:t,source:'RainViewer',confidence:Number(n.confidence)||0});break}
    }
  }
  const op=operaNowcastInfo(),operaBase=Date.parse(op?.observedAt||state.data?.opera?.observedAt||'');
  if(Number.isFinite(operaBase)&&Array.isArray(op?.series)){
    for(const row of op.series){
      const t=operaBase+(Number(row.minute)||0)*60_000;
      if(t<=now+2*60_000||t>limitMs)continue;
      const wet=(Number(row.wetFraction)||0)>=.10&&(Number(row.rateMmH)||0)>=.03;
      if(wet){candidates.push({time:t,source:'OPERA',confidence:Number(op.confidence)||0});break}
    }
  }
  const ae=aemetNowcastInfo(),aeBase=Date.parse(ae?.observedAt||state.data?.aemetRadar?.observedAt||'');
  if(Number.isFinite(aeBase)&&Array.isArray(ae?.series)){
    for(const row of ae.series){
      const t=aeBase+(Number(row.minute)||0)*60_000;
      if(t<=now+2*60_000||t>limitMs)continue;
      const wet=(Number(row.wetFraction)||0)>=.10&&(Number(row.radarRate)||0)>=.03;
      if(wet){candidates.push({time:t,source:'AEMET radar',confidence:Number(ae.confidence)||0});break}
    }
  }
  return candidates.sort((a,b)=>a.time-b.time)[0]||null;
}
function episodeLearningKey(){return 'raineta.episodeLearning.'+locationKey(state.loc)}
function readEpisodeLearning(){return readLocal(episodeLearningKey(),{corrections:[]})}
function episodeLearningStats(){
  const rows=(readEpisodeLearning().corrections||[]).filter(x=>Number.isFinite(Number(x.minutesEarly)));
  const values=rows.map(x=>Number(x.minutesEarly)).sort((a,b)=>a-b);
  const median=values.length?(values.length%2?values[Math.floor(values.length/2)]:(values[values.length/2-1]+values[values.length/2])/2):null;
  return{count:rows.length,medianEarly:median,bias:episodeEndBiasMinutesRaw(rows)};
}
function episodeEndBiasMinutesRaw(rows){
  const values=(rows||[]).filter(x=>Number(x.minutesEarly)>=5&&String(x.source||'').toLowerCase().includes('modelo')).map(x=>Number(x.minutesEarly)).filter(Number.isFinite).sort((a,b)=>a-b);
  if(values.length<5)return 0;
  const mid=Math.floor(values.length/2),median=values.length%2?values[mid]:(values[mid-1]+values[mid])/2;
  return Math.min(15,Math.max(0,median*.25));
}
function episodeEndBiasMinutes(){
  return episodeEndBiasMinutesRaw((readEpisodeLearning().corrections||[]).slice(-30));
}
function recordEpisodeEarlyEnd(correction){
  if(!correction?.episode||!correction.confirmedEnd)return;
  const key=episodeLearningKey(),data=readEpisodeLearning(),episode=correction.episode;
  data.corrections=Array.isArray(data.corrections)?data.corrections:[];
  const id=Math.round(episode.start/300000)+':'+Math.round(episode.end/300000);
  if(data.corrections.some(x=>x.id===id))return;
  data.corrections.push({
    id,time:Date.now(),
    predictedStart:new Date(episode.start).toISOString(),
    predictedEnd:new Date(episode.end).toISOString(),
    observedEnd:new Date(correction.observedEnd).toISOString(),
    minutesEarly:Math.max(0,Math.round((episode.end-correction.observedEnd)/60_000)),
    source:episode.source,
    reason:correction.reason
  });
  data.corrections=data.corrections.slice(-80);
  try{localStorage.setItem(key,JSON.stringify(data))}catch{}
}
function feedbackEpisodeCorrection(now=Date.now()){
  const feedback=recentFeedbackFor(state.currentLocation,60);
  if(!feedback||feedback.raining!==false||!samePlace(state.loc,state.currentLocation))return null;
  let episode=null;
  if(feedback.predictedEpisodeEnd){
    const start=Date.parse(feedback.predictedEpisodeStart||''),end=Date.parse(feedback.predictedEpisodeEnd||''),maxEnd=Date.parse(feedback.predictedEpisodeMaxEnd||feedback.predictedEpisodeEnd||'');
    const issued=Number(feedback.time)||now,legacyTooLong=Number.isFinite(end)&&end-issued>3*3600_000;
    if(!legacyTooLong&&Number.isFinite(end)&&end>now){
      episode={
        start:Number.isFinite(start)?start:issued,
        end,
        maxEnd:Number.isFinite(maxEnd)?Math.min(maxEnd,issued+3*3600_000):end,
        source:feedback.predictedEpisodeSource||'RainETA',
        confidence:Number(feedback.predictedEpisodeConfidence)||.45,
        candidates:[]
      };
    }
  }
  if(!episode)episode=canonicalEpisodeSnapshot(now);
  if(!episode)return null;
  const dryAgeMinutes=Math.max(0,(now-Number(feedback.time))/60_000),streak=dryFeedbackStreak(60),dry=localDryEvidence();
  const nextWet=nextProjectedWetTime(now,Math.min(episode.maxEnd,now+120*60_000));
  const humanConfirmed=Boolean(streak&&streak.count>=2&&streak.spanMinutes>=3);
  const sensorConfirmed=Boolean(dry.bothDry&&dryAgeMinutes>=5);
  const strongEnd=humanConfirmed||sensorConfirmed||(dry.anyDry&&dryAgeMinutes>=10);
  if(strongEnd&&!nextWet){
    const observedEnd=streak?.firstTime||Number(feedback.time)||now;
    const correction={mode:'ended_early',episode,observedEnd,confirmedEnd:true,reason:humanConfirmed?'repeated_feedback':dry.bothDry?'feedback+radar+opera_dry':'persistent_feedback+dry_sensor',dryAgeMinutes,streak,dry,nextWet:null};
    recordEpisodeEarlyEnd(correction);
    return correction;
  }
  if(nextWet){
    return{mode:'pause',episode,resumeAt:nextWet.time,resumeSource:nextWet.source,confidence:nextWet.confidence,observedEnd:Number(feedback.time),dryAgeMinutes,streak,dry,nextWet};
  }
  return{mode:'pause_unresolved',episode,resumeAt:null,confidence:Math.max(.25,episode.confidence*.65),observedEnd:Number(feedback.time),dryAgeMinutes,streak,dry,nextWet:null};
}
function nextModelEventAfter(minStartMs){
  const bias=0;
  for(const raw of state.data?.events||[]){
    const start=Date.parse(raw.start),end=Date.parse(raw.end);
    if(!Number.isFinite(start)||!Number.isFinite(end)||start<minStartMs||end<=start)continue;
    const adjustedEnd=new Date(Math.max(start+15*60_000,end-bias*60_000)).toISOString();
    return{
      kind:raw.quarterHourRefined?'model15':'model',
      active:false,start:new Date(start).toISOString(),end:adjustedEnd,
      confidence:Number(raw.timingConfidence)||0,event:raw,episodeBiasMinutes:bias
    };
  }
  return null;
}
function radarDryWindow(){
  const n=state.nowcast,now=Date.now();
  if(n?.status!=='ok'||!n.radarTime||!Array.isArray(n.series)||!n.series.length)return null;
  if(currentRainState().raining)return null;
  const radarMs=Date.parse(n.radarTime),radarConfidence=Number(n.confidence)||0;
  if(!Number.isFinite(radarMs)||(now-radarMs)>20*60_000)return null;
  const event=stabilizedRadarEvent(),operaEvent=operaEventCandidate(now);
  const requiredConfidence=event?.start ? .30 : .48;
  if(radarConfidence<requiredConfidence)return null;
  const horizonEnd=radarMs+nowcastReliableHorizon()*60_000,starts=[];
  if(event?.start&&Date.parse(event.start)>now)starts.push(Date.parse(event.start));
  if(operaEvent?.start&&operaEvent.confidence>=.28&&Date.parse(operaEvent.start)>now)starts.push(Date.parse(operaEvent.start));
  const earliestStart=starts.length?Math.min(...starts):null;
  const horizonLimited=!Number.isFinite(earliestStart)||earliestStart>=horizonEnd-2*60_000;
  let endMs=Number.isFinite(earliestStart)?Math.min(horizonEnd,earliestStart):horizonEnd;
  if(!Number.isFinite(endMs)||endMs<=now+15*60_000)return null;
  const opera=state.data?.opera,operaRate=Number(opera?.sample?.rateMmH),operaQuality=Number(opera?.sample?.quality);
  const operaDry=Boolean(opera?.sample?.ok&&operaFreshness(opera,OPERA_SURFACE_STALE_MINUTES).ok&&operaQuality>=.5&&operaRate<.02);
  const confidence=operaDry&&operaNowcastInfo()
    ? Math.min(.96,.68*radarConfidence+.32*(Number(opera.nowcast.confidence)||0)+.04)
    : radarConfidence;
  return{
    start:new Date(Math.max(now,radarMs)).toISOString(),
    end:new Date(endMs).toISOString(),
    confidence,
    radarConfidence,
    operaDry,
    operaEta:operaEvent?.start||null,
    fullHorizon:horizonLimited,
    horizonLimited,
    endReason:horizonLimited?'radar_horizon':'arrival',
    reliableHorizonMinutes:nowcastReliableHorizon(),
    minutes:Math.max(0,Math.round((endMs-now)/60_000))
  };
}
function chooseModelEvent(now,dry){
  const d=state.data,candidates=(d?.events||[]).filter(e=>Date.parse(e.end)>now);
  const dryEnd=dry?Date.parse(dry.end):null;
  for(const raw of candidates){
    let e=refineWithQuarterHour(raw,d?.quarterHour);
    let start=Date.parse(e.displayStart||e.start),end=Date.parse(e.displayEnd||e.end);
    if(!Number.isFinite(start)||!Number.isFinite(end)||end<=now)continue;
    let radarDelayed=false;
    if(Number.isFinite(dryEnd)&&start<dryEnd){
      const rawEnd=Date.parse(raw.end);
      if(end<=dryEnd&&Number.isFinite(rawEnd)&&rawEnd>dryEnd){
        e={...raw};
        start=dryEnd;end=rawEnd;radarDelayed=true;
      }else if(end<=dryEnd){
        continue;
      }else{
        start=dryEnd;radarDelayed=true;
      }
    }
    const endBias=0;
    if(endBias>0&&e.quarterHourRefined!==true)end=Math.max(start+15*60_000,end-endBias*60_000);
    if(start>=end)continue;
    const guidance=state.data?.arrivalGuidance;
    const guidanceMs=Date.parse(guidance?.median||'');
    const guidanceCompatible=Number.isFinite(guidanceMs)&&Math.abs(guidanceMs-start)<=3*60*60_000&&Number(guidance?.confidence)>=.30;
    if(guidanceCompatible&&!radarDelayed){
      const eventWeight=.58,guidanceWeight=.42;
      start=start*eventWeight+guidanceMs*guidanceWeight;
    }
    const active=start<=now&&end>now&&currentTruth()!==false;
    let confidence=radarDelayed?Math.min(Number(e.timingConfidence)||0,.68):Number(e.timingConfidence)||0;
    if(guidanceCompatible)confidence=Math.min(.94,.72*confidence+.28*Number(guidance.confidence));
    return{
      kind:e.quarterHourRefined?'model15':'model',
      active,
      start:new Date(start).toISOString(),
      end:new Date(end).toISOString(),
      confidence,
      event:e,
      radarDelayed,
      dryWindow:dry,
      ensembleArrival:guidanceCompatible?guidance:null
    };
  }
  return null;
}
function pulseSequenceText(ev){
  if(!ev?.start||!ev?.end)return'';
  const events=canonicalEvents().filter(e=>Date.parse(e.end)>Date.now());
  if(events.length<2)return'';
  const start=Date.parse(ev.start),end=Date.parse(ev.end);
  let index=events.findIndex(e=>Date.parse(e.end)>=start-30*60_000&&Date.parse(e.start)<=end+30*60_000);
  if(index<0)index=events.findIndex(e=>Date.parse(e.start)>=start);
  if(index<0||!events[index+1])return'';
  const current=events[index],next=events[index+1];
  const gapMs=Date.parse(next.start)-Date.parse(current.end);
  if(gapMs<30*60_000)return'';
  return'Después: seco ~'+durationText(current.end,next.start)+' · siguiente pulso '+fmtTime(next.start)+'.';
}
function chooseDisplayEvent(){
  const now=Date.now(),n=state.nowcast,rainNow=currentRainState(),truth=currentTruth(),radarEvent=stabilizedRadarEvent();
  const rv=n?.status==='ok'&&radarEvent&&Number(n.confidence)>=.30&&Date.parse(radarEvent.end||radarEvent.start)>now
    ? {kind:'radar',active:Date.parse(radarEvent.start)<=now&&truth!==false,start:radarEvent.start,end:radarEvent.end,confidence:Number(n.confidence)||0,uncertainty:radarEvent.uncertaintyMinutes||8,event:radarEvent,motion:n.motion||null}
    : null;
  const op=operaEventCandidate(now),ae=aemetEventCandidate(now);
  if(rainNow.raining){
    const activeRv=rv?.active?rv:null,activeOp=op?.active?op:null,activeAe=ae?.active?ae:null;
    const radarChoice=fuseAemetRadarEvent(fuseRadarEvents(activeRv,activeOp,now),activeAe,now);
    if(truth===true){
      return{kind:'observed',active:true,start:new Date(now).toISOString(),end:radarChoice?.end||null,confidence:1,uncertainty:radarChoice?.uncertainty||8,event:radarChoice?.event||null};
    }
    if(radarChoice)return radarChoice;
    const opera=state.data?.opera,operaRate=Number(opera?.sample?.rateMmH);
    if(opera?.sample?.ok&&operaFreshness(opera,OPERA_SURFACE_STALE_MINUTES).ok&&operaRate>=.05){
      return{kind:'opera',active:true,start:opera.observedAt||new Date(now).toISOString(),end:op?.end||null,confidence:Number(opera.nowcast?.confidence)||.55,uncertainty:op?.uncertainty||12,event:op?.event||null,motion:opera.nowcast?.motion||null};
    }
    const aemet=state.data?.aemetRadar,aemetRate=Number(aemet?.sample?.rateMmH);
    if(aemetRadarFreshness(aemet,20).ok&&aemetRate>=.05){
      return{kind:'aemet',active:true,start:aemet.observedAt||new Date(now).toISOString(),end:ae?.end||null,confidence:Number(aemet.nowcast?.confidence)||.55,uncertainty:ae?.uncertainty||12,event:ae?.event||null,motion:aemet.nowcast?.motion||null};
    }
    if(n?.status==='ok'){
      return{kind:'radar',active:true,start:n.radarTime||new Date(now).toISOString(),end:rv?.end||null,confidence:Number(n.confidence)||.5,uncertainty:rv?.uncertainty||8,event:rv?.event||null,motion:n.motion||null};
    }
  }
  const rvHorizon=Math.max(20,Math.min(90,Number(n?.reliableHorizonMinutes)||45));
  const opHorizon=op?Math.max(20,Math.min(80,Number(op.event?.reliableHorizonMinutes)||25+50*(Number(op.confidence)||0))):0;
  const aeHorizon=ae?Math.max(20,Math.min(90,Number(state.data?.aemetRadar?.nowcast?.reliableHorizonMinutes)||25+55*(Number(ae.confidence)||0))):0;
  const futureRv=rv&&Date.parse(rv.start)<=now+rvHorizon*60_000?rv:null;
  const futureOp=op&&Date.parse(op.start)<=now+opHorizon*60_000?op:null;
  const futureAe=ae&&Date.parse(ae.start)<=now+aeHorizon*60_000?ae:null;
  const radarChoice=fuseAemetRadarEvent(fuseRadarEvents(futureRv,futureOp,now),futureAe,now);
  if(radarChoice)return radarChoice;
  return chooseModelEvent(now,radarDryWindow());
}
function buildRainDecision(){
  const now=Date.now(),rain=currentRainState(),truth=currentTruth(4);
  const correction=truth===false?feedbackEpisodeCorrection(now):null;
  let dry=radarDryWindow(),event=chooseDisplayEvent();
  const stable=!rain.raining&&!correction?forecastStableWindow(now):null;
  if(correction?.mode==='pause'){
    dry=null;
    event={
      kind:'resume',active:false,
      start:new Date(correction.resumeAt).toISOString(),
      end:new Date(correction.episode.end).toISOString(),
      confidence:Number(correction.confidence)||Number(correction.episode.confidence)||0,
      uncertainty:10,
      event:{start:new Date(correction.resumeAt).toISOString(),end:new Date(correction.episode.end).toISOString()},
      pauseCorrection:true,resumeSource:correction.resumeSource
    };
  }else if(correction?.mode==='pause_unresolved'){
    dry=null;
    event={
      kind:'pause',active:false,
      start:null,end:new Date(correction.episode.end).toISOString(),
      confidence:Number(correction.confidence)||0,
      pauseCorrection:true
    };
  }else if(correction?.mode==='ended_early'){
    event=nextModelEventAfter(correction.episode.maxEnd+5*60_000);
  }
  const delayedByRadar=Boolean(event?.radarDelayed&&dry&&event?.start&&Date.parse(event.start)>=Date.parse(dry.end)-2*60_000);
  const near=Boolean(event?.start&&Date.parse(event.start)<=now+SHORT_HORIZON_MINUTES*60_000&&!delayedByRadar);
  const radarDryIsArrival=Boolean(dry&&!dry.horizonLimited);
  const dryUntil=!rain.raining&&!correction
    ? (radarDryIsArrival?dry.end:(event?.start&&Date.parse(event.start)>now?event.start:stable?.end||null))
    : correction?.mode==='pause'&&correction.resumeAt
      ? new Date(correction.resumeAt).toISOString()
      : correction?.mode==='ended_early'&&event?.start
        ? event.start
        : null;
  let mode='dry_unknown';
  if(rain.raining)mode='rain_now';
  else if(rain.possible&&!correction)mode='possible_now';
  else if(correction?.mode==='pause')mode='episode_pause';
  else if(correction?.mode==='pause_unresolved')mode='episode_pause';
  else if(correction?.mode==='ended_early')mode='episode_ended_early';
  else if(stable&&!event)mode='stable_now';
  else if(dry&&!dry.horizonLimited)mode='dry_now';
  else if(near)mode='rain_soon';
  else if(event)mode='rain_later';
  const confidence=rain.raining
    ? Number(event?.confidence)||Number(state.nowcast?.confidence)||0
    : correction
      ? Number(event?.confidence)||Number(correction.episode?.confidence)||0
      : mode==='stable_now'&&stable
        ? Number(stable.confidence)||0
        : dry&&!dry.horizonLimited
          ? Number(dry.confidence)||0
          : event
            ? Number(event.confidence)||0
            : stable
              ? Number(stable.confidence)||0
              : null;
  return{
    now,rain,dry,stable,event,near,delayedByRadar,mode,dryUntil,confidence,correction,
    dryMinutes:dryUntil?Math.max(0,Math.round((Date.parse(dryUntil)-now)/60_000)):null,
    nextRainStart:event?.start||null,
    nextRainEnd:event?.end||null,
    modelRisk:modelRiskWithin(SHORT_HORIZON_MINUTES)
  };
}
function decisionHistoryKey(){return 'raineta.decisionHistory.'+locationKey(state.loc)}
function recordRainDecisionSnapshot(decision=buildRainDecision()){
  if(!state.data)return;
  const key=decisionHistoryKey(),now=decision.now||Date.now();
  let rows=readLocal(key,[]);
  const last=rows.at(-1);
  const signature=[
    decision.mode,
    decision.dryUntil?Math.round(Date.parse(decision.dryUntil)/300000):'',
    decision.nextRainStart?Math.round(Date.parse(decision.nextRainStart)/300000):''
  ].join('|');
  if(last&&last.signature===signature&&now-Number(last.time)<10*60_000)return;
  const operaRate=Number(state.data?.opera?.sample?.rateMmH);
  rows.push({
    time:now,signature,mode:decision.mode,
    dryUntil:decision.dryUntil||null,
    nextRainStart:decision.nextRainStart||null,
    nextRainEnd:decision.nextRainEnd||null,
    confidence:Number.isFinite(Number(decision.confidence))?Number(decision.confidence):null,
    modelRisk:Number.isFinite(Number(decision.modelRisk))?Number(decision.modelRisk):null,
    radarTime:state.nowcast?.radarTime||null,
    radarConfidence:Number(state.nowcast?.confidence)||null,
    operaRate:Number.isFinite(operaRate)?operaRate:null
  });
  rows=rows.filter(x=>now-Number(x.time)<7*24*3600_000).slice(-500);
  try{localStorage.setItem(key,JSON.stringify(rows))}catch{}
}
function uncertaintyText(ev){
  if(['radar','opera','aemet','radarFusion'].includes(ev.kind))return'± '+ev.uncertainty+' min';
  const e=ev.event;
  if(e?.startWindow?.earliest&&e?.startWindow?.latest)return fmtTime(e.startWindow.earliest)+'–'+fmtTime(e.startWindow.latest);
  return ev.kind==='model15'?'resolución 15 min':'resolución horaria';
}
function render(){
  const d=state.data,n=state.nowcast,decision=buildRainDecision(),ev=decision.event,nowState=decision.rain,truth=currentTruth();
  $('place').textContent=state.loc.name;
  $('summary').hidden=true;
  $('metricStartLabel').textContent='Inicio';
  $('metricEndLabel').textContent='Fin';
  $('metricConfLabel').textContent='Confianza';
  $('metricDurLabel').textContent='Duración';
  if(decision.mode==='episode_pause'){
    const correction=decision.correction,episode=correction?.episode;
    $('heroLabel').textContent='Pausa dentro del episodio';
    $('eta').innerHTML='No llueve <span>ahora</span>';
    $('metricStartLabel').textContent=correction?.resumeAt?'Puede reanudarse':'Reevaluación';
    $('metricEndLabel').textContent='Fin previsto del tramo';
    $('metricConfLabel').textContent='Confianza';
    $('metricDurLabel').textContent='Seco observado';
    $('start').textContent=correction?.resumeAt?fmtDateTime(correction.resumeAt):'sin nuevo pulso detectado';
    $('end').textContent=episode?.end?fmtDateTime(episode.end):'—';
    $('conf').textContent=pct(decision.confidence)+'%';
    $('dur').textContent=durationText(correction?.observedEnd||decision.now,decision.now);
    $('summary').textContent='';
    $('summary').hidden=true;
  }else if(decision.mode==='episode_ended_early'){
    const correction=decision.correction,episode=correction?.episode,minutesEarly=Math.max(0,Math.round((Number(episode?.end)-Number(correction?.observedEnd))/60_000));
    $('heroLabel').textContent='Episodio recalculado';
    $('eta').innerHTML='No llueve <span>ahora</span>';
    $('metricStartLabel').textContent='Terminó aprox.';
    $('metricEndLabel').textContent='Fin previsto del tramo';
    $('metricConfLabel').textContent='Corrección';
    $('metricDurLabel').textContent='Siguiente riesgo';
    $('start').textContent=correction?.observedEnd?fmtDateTime(correction.observedEnd):'—';
    $('end').textContent=episode?.end?fmtDateTime(episode.end):'—';
    $('conf').textContent=minutesEarly?minutesEarly+' min antes':'ajustado';
    $('dur').textContent=ev?.start?fmtDateTime(ev.start):'sin episodio inmediato';
    $('summary').textContent='';
    $('summary').hidden=true;
  }else if(decision.mode==='possible_now'){
    const radarRate=Number(nowState.radarRate)||0,operaRate=Number(nowState.operaRate)||0;
    const opera=state.data?.opera,operaFresh=Boolean(opera?.sample?.ok&&operaFreshness(opera,OPERA_SURFACE_STALE_MINUTES).ok);
    $('heroLabel').textContent='Señal radar';
    $('eta').innerHTML='Lluvia <span>no confirmada</span>';
    $('metricStartLabel').textContent='Radar local';
    $('metricEndLabel').textContent='Radar europeo';
    $('metricConfLabel').textContent='Confianza señal';
    $('metricDurLabel').textContent='Señal hasta';
    $('start').textContent=radarRate>.02?radarRate.toFixed(1).replace('.',',')+' mm/h':'sin señal clara';
    $('end').textContent=operaFresh?(operaRate>.02?operaRate.toFixed(1).replace('.',',')+' mm/h':'seco'):'dato no reciente';
    $('conf').textContent=pct(decision.confidence)+'%';
    $('dur').textContent=ev?.end?fmtDateTime(ev.end):'por determinar';
    $('summary').hidden=false;
    $('summary').textContent='El radar detecta precipitación sobre el punto, pero no hay suficiente corroboración para afirmar que esté llegando al suelo. Los modelos no cuentan como prueba de que llueva ahora.';
  }else if(decision.mode==='stable_now'){
    const stable=decision.stable,reliable=nowcastReliableHorizon();
    $('heroLabel').textContent='Tiempo estable';
    $('eta').textContent='Tiempo estable';
    $('metricStartLabel').textContent='Próxima lluvia';
    $('metricEndLabel').textContent='Previsión';
    $('metricConfLabel').textContent='Confianza';
    $('metricDurLabel').textContent='Horizonte';
    $('start').textContent='sin ETA';
    $('end').textContent='sin señal de llegada';
    $('conf').textContent=pct(decision.confidence)+'%';
    $('dur').textContent=stable?.label||'—';
    $('summary').hidden=false;
    $('summary').textContent='Sin lluvia prevista en las próximas '+(stable?.label||'horas')+'. El radar es fiable aproximadamente '+reliable+' min; ese límite es técnico y no implica que vaya a cambiar el tiempo.';
  }else if(decision.mode==='dry_now'){
    const horizonLimited=Boolean(decision.dry?.horizonLimited);
    $('heroLabel').textContent='Tiempo estable';
    $('eta').innerHTML='Estable hasta <span>'+fmtTime(decision.dryUntil)+'</span>';
    $('metricStartLabel').textContent='Próxima lluvia';
    $('metricEndLabel').textContent='Duración lluvia';
    $('metricConfLabel').textContent='Confianza seco';
    $('metricDurLabel').textContent='Ventana estable';
    $('start').textContent=ev?.start?fmtDateTime(ev.start):(horizonLimited?'sin ETA de lluvia':'después de '+fmtTime(decision.dryUntil));
    $('end').textContent=ev?.start&&ev?.end?durationText(ev.start,ev.end):'—';
    $('conf').textContent=pct(decision.confidence)+'%';
    $('dur').textContent=(horizonLimited?'≥ ':'')+durationText(decision.now,decision.dryUntil);
    if(horizonLimited){
      $('summary').hidden=false;
      $('summary').textContent='El radar mantiene el punto seco hasta su horizonte fiable. '+fmtTime(decision.dryUntil)+' es el límite de esa confirmación, no una hora prevista de llegada de lluvia.';
    }else{
      $('summary').textContent='';
      $('summary').hidden=true;
    }
  }else if(!ev){
    $('heroLabel').textContent='Sin lluvia relevante';
    $('eta').textContent='Sin lluvia';
    $('summary').textContent='No hay episodio con consenso suficiente en las próximas 72 horas.';
    $('start').textContent='—';$('end').textContent='—';$('conf').textContent='—';$('dur').textContent='—';
  }else{
    if(ev.active&&decision.mode==='rain_now'){$('heroLabel').textContent='Estado actual';$('eta').innerHTML='Lluvia <span>ahora</span>'}
    else{$('heroLabel').textContent='Próxima lluvia';$('eta').innerHTML=ev?.start?'<span>'+fmtTime(ev.start)+'</span>':'Sin hora confirmada'}
    $('start').textContent=fmtDateTime(ev.start);
    $('end').textContent=ev.end?fmtDateTime(ev.end):'por determinar';
    $('conf').textContent=pct(decision.confidence)+'%';
    $('dur').textContent=durationText(ev.start,ev.end);
    if(truth===false&&Date.parse(ev.start)<=Date.now()&&(!ev.end||Date.parse(ev.end)>Date.now())){
      $('eta').textContent='No llueve ahora';
      $('summary').hidden=false;
      $('summary').textContent='Tu observación contradice la señal automática; queda registrada para calibrar la detección local.';
    }else if(ev.kind==='observed'){
      $('summary').textContent='Confirmado por ti en esta ubicación'+(ev.end?' · fin estimado '+fmtTime(ev.end):'')+'.';
    }else if(ev.kind==='radarFusion'){
      const speed=Number(ev.motion?.speedKmh),dir=compassDirection(ev.motion?.bearingDegrees);
      const motion=Number.isFinite(speed)&&speed<220?' · eco '+Math.round(speed)+' km/h'+(dir?' hacia '+dir:''):'';
      if(ev.active){
        $('summary').textContent='RainViewer + OPERA coinciden en lluvia ahora'+(ev.end?' · fin probable '+fmtTime(ev.end):'')+motion+'.';
      }else{
        $('summary').textContent='ETA cruzada RainViewer + OPERA: llegada '+fmtTime(ev.start)+' · '+uncertaintyText(ev)+motion+'.';
      }
    }else if(ev.kind==='opera'){
      const speed=Number(ev.motion?.speedKmh),dir=compassDirection(ev.motion?.bearingDegrees);
      const motion=Number.isFinite(speed)&&speed<220?' · movimiento OPERA '+Math.round(speed)+' km/h'+(dir?' hacia '+dir:''):'';
      if(ev.active){
        $('summary').textContent='OPERA espacial detecta lluvia ahora'+(ev.end?' · fin probable '+fmtTime(ev.end):'')+motion+'.';
      }else{
        $('summary').textContent='Nowcast OPERA independiente: llegada '+fmtTime(ev.start)+' · '+uncertaintyText(ev)+motion+'.';
      }
      if(ev.disagreementMinutes)$('summary').textContent+=' RainViewer discrepa ~'+ev.disagreementMinutes+' min.';
    }else if(ev.kind==='radar'){
      const speed=Number(n?.motion?.speedKmh),dir=compassDirection(n?.motion?.bearingDegrees);
      const motion=Number.isFinite(speed)&&speed<220?' · desplazamiento del eco de lluvia '+Math.round(speed)+' km/h'+(dir?' hacia '+dir:''):'';
      if(ev.active){
        $('summary').textContent='Radar RainViewer: lluvia detectada ahora'+(ev.end?' · fin probable '+fmtTime(ev.end):'')+motion+'.';
      }else{
        $('summary').textContent='Nowcast RainViewer: llegada '+fmtTime(ev.start)+' · '+uncertaintyText(ev)+motion+'.';
      }
      if(ev.disagreementMinutes)$('summary').textContent+=' OPERA discrepa ~'+ev.disagreementMinutes+' min.';
    }else if(ev.kind==='model15'){
      if(ev.radarDelayed&&ev.dryWindow){
        $('summary').textContent='Radar sin precipitación proyectada sobre el punto hasta ~'+fmtTime(ev.dryWindow.end)+(ev.dryWindow.operaDry?' · OPERA también está seco ahora':'')+'. Después, los modelos mantienen riesgo de lluvia intermitente.';
      }else{
        $('summary').textContent='Consenso de modelos afinado con guía de 15 min. Esa guía puede ser interpolada en España.';
      }
    }else{
      const w=ev.event?.startWindow;
      if(ev.radarDelayed&&ev.dryWindow){
        $('summary').textContent='Radar sin precipitación proyectada sobre el punto hasta ~'+fmtTime(ev.dryWindow.end)+(ev.dryWindow.operaDry?' · OPERA también está seco ahora':'')+'. Después, el consenso multimodelo mantiene riesgo de lluvia.';
      }else{
        const g=ev.ensembleArrival;
        $('summary').textContent='Consenso multimodelo'+(g?' · ensembles: inicio central '+fmtTime(g.median)+' · ventana ~'+fmtTime(g.earliest)+'–'+fmtTime(g.latest)+' ('+g.families+' familias)':w?.earliest?' · ventana de inicio '+fmtTime(w.earliest)+'–'+fmtTime(w.latest):'')+'.';
      }
    }
    const sequence=pulseSequenceText(ev);
    if(sequence)$('summary').textContent+=' '+sequence;
  }
  const current=d.quarterHour?.current||{};
  $('nowRain').textContent='Ahora: '+nowState.label;
  $('nowRain').classList.toggle('wet',nowState.raining);
  $('nowRain').classList.toggle('possible',Boolean(nowState.possible&&!nowState.raining));
  $('tempNow').textContent=Number.isFinite(current.temperature)?current.temperature.toFixed(1).replace('.',',')+' °C':'— °C';
  const savedHere=isSaved();
  $('savePlace').textContent=state.loc.isCurrent
    ? (savedHere?'★ GPS guardado':'☆ Guardar GPS')
    : (savedHere?'★ Guardado':'☆ Guardar');
  $('savePlace').hidden=false;
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
  renderConsensusDecision(decision);
  renderDecisionBasis(decision);
  renderImportantPhenomenon();
  recordRainDecisionSnapshot(decision);
  updateSourceSkill();
  renderSourceSkill();
  $('etaTrend').textContent=etaTrendText(ev);
  const h=d.sources.health;
  const degradedAge=Number(d.degradedCacheAgeMs)||0;
  $('health').textContent=d.degradedForecast
    ? 'MODO DEGRADADO · previsión guardada hace '+Math.max(1,Math.round(degradedAge/60_000))+' min · '+h.available+' de '+h.total+' capas vivas'
    : h.available+' de '+h.total+' capas disponibles · radar '+(n?.status==='ok'?'analizado':n?.status==='motion_uncertain'?'sin movimiento fiable':'degradado');
  $('sourceCount').textContent=h.available+'/'+h.total;
  renderShortNowcast();renderTimeline();renderWeekForecast();renderEvents();renderSources();renderRadar();
  const completed=state.lastCompletedAt||d.generatedAt;
  const radarStamp=n?.radarTime||d.radar?.frames?.at(-1)?.time*1000||null;
  $('updated').textContent=d.degradedForecast
    ? 'Actualización '+fmtTimeSeconds(completed)+' · MODELOS EN FALLBACK '+fmtTime(d.generatedAt)+' ('+Math.max(1,Math.round(degradedAge/60_000))+' min)'+(radarStamp?' · radar '+fmtTime(radarStamp):'')
    : 'Actualización '+fmtTimeSeconds(completed)+' · modelos '+fmtTime(d.generatedAt)+(radarStamp?' · radar '+fmtTime(radarStamp):'');
  updateLiveCountdown();
}
function canonicalTimelineRows(){
  const base=(state.data?.timeline||[]).map(row=>({...row}));
  if(!base.length||!state.nowcast)return base;
  const decision=buildRainDecision(),now=decision.now,cutoff=now+SHORT_HORIZON_MINUTES*60_000,points=shortPoints();
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
    row.confidence=Math.round((decision.confidence||0)*100);
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
function quarterHourCoverage(){
  const times=(state.data?.quarterHour?.time||[]).map(Date.parse).filter(Number.isFinite).sort((a,b)=>a-b);
  if(!times.length)return null;
  return{start:times[0]-8*60_000,end:times.at(-1)+8*60_000};
}
function quarterHourSupports(timeMs){
  const coverage=quarterHourCoverage();
  return Boolean(coverage&&timeMs>=coverage.start&&timeMs<=coverage.end);
}
function detail15MinuteCoverage(){
  const now=Date.now(),qh=quarterHourCoverage();
  let end=0;
  if(nativeQuarterHourLikely())end=qh?.end||0;
  if(state.nowcast?.status==='ok'&&Array.isArray(state.nowcast?.series)&&state.nowcast.series.length){
    end=Math.max(end,now+nowcastReliableHorizon()*60_000);
  }
  return end>now?{start:now-15*60_000,end}:null;
}
function baseTimelineRowAt(timeMs,rows=canonicalTimelineRows()){
  return rows.find(row=>{
    const t=Date.parse(row.time);return t<=timeMs&&timeMs<t+60*60_000;
  })||rows.reduce((best,row)=>{
    const d=Math.abs(Date.parse(row.time)-timeMs);return !best||d<best.d?{row,d}:best;
  },null)?.row||null;
}
function detailRow(slot,minutes,hourly,short){
  const slotEnd=slot+minutes*60_000,center=slot+minutes*30_000,base=baseTimelineRowAt(center,hourly);
  if(!base)return null;
  let probability=Number(base.probability)||0,rate=Number(base.precipitation)||0,source=minutes===15?'Modelo 15 min':'Consenso 30 min';
  if(minutes===15){
    const shortBucket=short.filter(p=>p.time>=slot&&p.time<slotEnd),shortWet=shortBucket.filter(p=>p.wet);
    if(shortBucket.length&&slot<=Date.now()+nowcastReliableHorizon()*60_000){
      probability=Math.round((shortWet.length?Math.max(...shortWet.map(p=>p.probability)):Math.max(...shortBucket.map(p=>p.probability),0))*100);
      rate=shortWet.length?shortWet.reduce((sum,p)=>sum+p.rate,0)/shortWet.length:0;
      source='Radar / nowcast';
    }else if(nativeQuarterHourLikely()&&quarterHourSupports(center)){
      rate=quarterHourRateAt(center);
      const signal=rate<=.05?0:Math.min(.82,.30+Math.log1p(rate)*.26);
      probability=Math.max(probability,Math.round(signal*100));
      source='Modelo 15 min nativo';
    }
  }
  const row={
    ...base,time:new Date(slot).toISOString(),end:new Date(slotEnd).toISOString(),
    probability:Math.max(0,Math.min(100,Math.round(probability))),
    precipitation:Math.max(0,rate),detailSource:source,detailMinutes:minutes
  };
  return{...row,visual:conditionVisual(row)};
}
function eventDetailRows(event){
  const hourly=canonicalTimelineRows(),short=shortPoints(),coverage=detail15MinuteCoverage();
  const eventStart=Date.parse(event.start),eventEnd=Date.parse(event.end);
  if(!Number.isFinite(eventStart)||!Number.isFinite(eventEnd)||eventEnd<=eventStart)return[];
  const rows=[],now=Date.now(),visibleStart=Math.max(eventStart,now-15*60_000);
  let slot=Math.floor(visibleStart/(15*60_000))*(15*60_000);
  const fineEnd=coverage?.end||0;
  while(slot<eventEnd){
    const minutes=slot<fineEnd?15:30;
    const row=detailRow(slot,minutes,hourly,short);
    if(row)rows.push({...row,partialStart:Math.max(slot,eventStart),partialEnd:Math.min(slot+minutes*60_000,eventEnd)});
    slot+=minutes*60_000;
  }
  return rows;
}
function fmtDetailRange(start,end){
  return fmtTime(start)+'–'+fmtTime(end);
}

function fmtSegmentRange(start,end){
  const a=new Date(start),b=new Date(end);
  const ah=String(a.getHours()).padStart(2,'0'),bh=String(b.getHours()).padStart(2,'0');
  if(a.toDateString()===b.toDateString())return ah+'–'+bh+' h';
  const wd=d=>new Intl.DateTimeFormat('es-ES',{weekday:'short'}).format(d).replace('.','');
  return wd(a)+' '+ah+'–'+wd(b)+' '+bh+' h';
}
function semanticHour(row,peak,eventLength){
  const p=(Number(row.probability)||0)/100,rate=Number(row.precipitation)||0;
  const signal=row.canonicalSignal||classifyRainHour({probability:p,expectedPrecipitation:rate});
  const weather=weatherParts(row);
  if(rate>=7.5)return{key:'heavy',label:'Lluvia fuerte',phenomenon:weather.phenomenon};
  if(signal==='possible')return{key:'possible',label:'Riesgo bajo / intermitente',phenomenon:weather.phenomenon};
  const peakLike=eventLength>=3&&p>=.70&&rate>=Math.max(.12,peak*.72);
  if(peakLike)return{key:'peak',label:'Tramo más probable',phenomenon:weather.phenomenon};
  if(rate<.5)return p<.66
    ?{key:'drizzle-intermittent',label:'Llovizna intermitente',phenomenon:weather.phenomenon}
    :{key:'drizzle',label:'Llovizna / lluvia muy débil',phenomenon:weather.phenomenon};
  if(rate<2.5)return p<.66
    ?{key:'light-intermittent',label:'Lluvia débil intermitente',phenomenon:weather.phenomenon}
    :{key:'light',label:'Lluvia débil probable',phenomenon:weather.phenomenon};
  if(rate<7.5)return{key:'moderate',label:'Lluvia moderada',phenomenon:weather.phenomenon};
  return{key:'heavy',label:'Lluvia fuerte',phenomenon:weather.phenomenon};
}
function semanticSegments(event){
  const rows=eventDetailRows(event);
  if(!rows.length)return[];
  const peak=Math.max(...rows.map(r=>Number(r.precipitation)||0));
  const classified=rows.map(row=>({...row,semantic:semanticHour(row,peak,rows.length)}));
  const groups=[];
  for(const row of classified){
    const last=groups.at(-1);
    if(last&&last.key===row.semantic.key){
      last.rows.push(row);last.end=row.end;
    }else{
      groups.push({key:row.semantic.key,label:row.semantic.label,start:row.time,end:row.end,rows:[row]});
    }
  }
  return groups.map(group=>{
    const probs=group.rows.map(r=>Number(r.probability)||0);
    const rates=group.rows.map(r=>Number(r.precipitation)||0);
    const phenomena=[...new Set(group.rows.map(r=>r.semantic.phenomenon).filter(Boolean))];
    const minRate=Math.min(...rates),maxRate=Math.max(...rates),avgProb=Math.round(probs.reduce((a,b)=>a+b,0)/probs.length);
    const rateText=Math.abs(maxRate-minRate)<.05
      ?maxRate.toFixed(1).replace('.',',')+' mm/h'
      :minRate.toFixed(1).replace('.',',')+'–'+maxRate.toFixed(1).replace('.',',')+' mm/h';
    const phenomenonText=phenomena.map(x=>x==='Tormenta prevista'?'riesgo de tormenta':x.toLowerCase()).join(' · ');
    return{...group,avgProb,rateText,phenomenonText};
  });
}
function heavyRainWindows(rows=[]){
  const heavy=rows.filter(row=>(Number(row.precipitation)||0)>=7.5).sort((a,b)=>Date.parse(a.time)-Date.parse(b.time));
  const groups=[];
  for(const row of heavy){
    const start=Date.parse(row.time),end=Date.parse(row.end||row.time);
    if(!Number.isFinite(start)||!Number.isFinite(end))continue;
    const last=groups.at(-1);
    if(last&&start<=last.end+60_000){
      last.end=Math.max(last.end,end);
      last.peak=Math.max(last.peak,Number(row.precipitation)||0);
    }else{
      groups.push({start,end,peak:Number(row.precipitation)||0});
    }
  }
  return groups;
}
function heavyWindowsText(groups=[]){
  return groups.map(g=>fmtTime(g.start)+'–'+fmtTime(g.end)+' · pico '+g.peak.toFixed(1).replace('.',',')+' mm/h').join(' · ');
}

function dryWindowBetween(a,b){
  if(!a||!b)return null;
  const start=Date.parse(a.end),end=Date.parse(b.start),minutes=Math.round((end-start)/60_000);
  if(minutes<60)return null;
  return{start:a.end,end:b.start,minutes};
}

function weekLocalMs(unix,offsetSeconds=0){
  return (Number(unix)+Number(offsetSeconds||0))*1000;
}
function weekDateKey(unix,offsetSeconds=0){
  return new Date(weekLocalMs(unix,offsetSeconds)).toISOString().slice(0,10);
}
function weekHour(unix,offsetSeconds=0){
  return new Date(weekLocalMs(unix,offsetSeconds)).getUTCHours();
}
function weekDayLabel(unix,offsetSeconds=0){
  const d=new Date(weekLocalMs(unix,offsetSeconds));
  const raw=new Intl.DateTimeFormat('es-ES',{weekday:'long',day:'numeric',month:'short',timeZone:'UTC'}).format(d).replace('.','');
  return raw.charAt(0).toUpperCase()+raw.slice(1);
}
function weekWetHour(row){
  const p=Number(row.probability)||0,mm=Number(row.precipitation)||0;
  return (p>=40&&mm>=.10)||(p>=32&&mm>=.35);
}
function weekRainRanges(rows=[],offsetSeconds=0){
  const wet=rows.filter(weekWetHour).sort((a,b)=>a.unix-b.unix),groups=[];
  for(const row of wet){
    const start=row.unix,end=row.unix+3600,last=groups.at(-1);
    if(last&&start<=last.end+1){
      last.end=Math.max(last.end,end);
      last.maxProb=Math.max(last.maxProb,Number(row.probability)||0);
      last.total+=Number(row.precipitation)||0;
      last.peak=Math.max(last.peak,Number(row.precipitation)||0);
    }else{
      groups.push({start,end,maxProb:Number(row.probability)||0,total:Number(row.precipitation)||0,peak:Number(row.precipitation)||0});
    }
  }
  return groups.map(g=>({
    ...g,
    label:String(weekHour(g.start,offsetSeconds)).padStart(2,'0')+':00–'+String(weekHour(g.end,offsetSeconds)).padStart(2,'0')+':00'
  }));
}
function weekDays(week=state.data?.week){
  if(!week?.rows?.length)return[];
  const offset=Number(week.utcOffsetSeconds)||0;
  const nowUnix=Math.floor(Date.now()/1000),today=weekDateKey(nowUnix,offset),byDay=new Map();
  for(const row of week.rows){
    const key=weekDateKey(row.unix,offset);
    if(key<=today)continue;
    if(!byDay.has(key))byDay.set(key,[]);
    byDay.get(key).push(row);
  }
  return [...byDay.entries()].slice(0,7).map(([key,rows])=>{
    const ranges=weekRainRanges(rows,offset),maxProb=Math.max(0,...rows.map(r=>Number(r.probability)||0));
    const total=ranges.reduce((s,r)=>s+r.total,0),peak=Math.max(0,...ranges.map(r=>r.peak));
    return{key,label:weekDayLabel(rows[0].unix,offset),yes:ranges.length>0,ranges,maxProb,total,peak};
  });
}
function renderWeekForecast(){
  const root=$('weekDays'),summary=$('weekSummary');
  if(!root||!summary)return;
  const days=weekDays();
  if(!days.length){
    summary.textContent='sin datos';
    root.innerHTML='<div class="weekEmpty">No hay previsión semanal disponible ahora.</div>';
    return;
  }
  const rainy=days.filter(d=>d.yes);
  summary.textContent=rainy.length?rainy.length+' de 7 días con lluvia':'7 días sin lluvia relevante';
  root.innerHTML=days.map(day=>{
    if(!day.yes)return '<div class="weekDay"><div class="weekName">'+day.label+'</div><div class="weekNo">NO</div><div class="weekInfo">Sin tramo de lluvia con señal suficiente</div></div>';
    const ranges=day.ranges.slice(0,4).map(r=>'<span>'+r.label+' · '+Math.round(r.maxProb)+'% · ~'+r.total.toFixed(1).replace('.',',')+' mm</span>').join('');
    return '<div class="weekDay rainy"><div class="weekName">'+day.label+'</div><div class="weekYes">SÍ</div><div class="weekInfo">'+ranges+'<small>Total orientativo ~'+day.total.toFixed(1).replace('.',',')+' mm · pico horario ~'+day.peak.toFixed(1).replace('.',',')+' mm/h</small></div></div>';
  }).join('');
}
function renderTimeline(){
  const full=canonicalTimelineRows(),a=full.slice(0,state.timelineHours);
  $('timelineTitle').textContent='Próximas '+state.timelineHours+' horas';
  document.querySelectorAll('.rangeBtn').forEach(btn=>btn.classList.toggle('active',Number(btn.dataset.hours)===state.timelineHours));
  const maxIntensity=Math.max(.25,Math.min(6,Math.max(...a.map(x=>Number(x.precipitation)||0))));
  $('timeline').innerHTML=a.map((x,index)=>{
    const probability=(Number(x.probability)||0)/100,precipitation=Number(x.precipitation)||0;
    const signal=x.canonicalSignal||classifyRainHour({probability,expectedPrecipitation:precipitation});
    const band=probabilityBand(probability);
    const cls=signal==='wet'?band:signal==='possible'?band+' possible':'dry';
    const height=signal==='wet'
      ?Math.max(8,Math.round(10+Math.sqrt(Math.min(precipitation,maxIntensity)/maxIntensity)*90))
      :signal==='possible'?Math.max(5,Math.min(18,Math.round(5+precipitation/maxIntensity*20))):0;
    const selected=state.selectedHourIndex===index?' selected':'',visual=conditionVisual(x);
    return '<button type="button" class="bar '+cls+' wx-'+visual.key+selected+'" data-hour-index="'+index+'" style="height:'+height+'%" aria-label="'+fmtDateTime(x.time)+' · '+visual.label+'" title="'+fmtDateTime(x.time)+' · '+visual.label+' · prob. '+x.probability+'% · intensidad '+precipitation.toFixed(1)+' mm/h"></button>';
  }).join('');
  $('timeline').querySelectorAll('[data-hour-index]').forEach(el=>el.onclick=()=>selectTimelineHour(el.dataset.hourIndex));
  const ticks=[],lines=[],tickEvery=state.timelineHours<=24?3:6;
  for(let i=0;i<a.length;i++){
    const dt=new Date(a[i].time),hour=dt.getHours();
    if(i===0||hour%tickEvery===0){
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
  const decision=buildRainDecision(),now=decision.now;
  const events=canonicalEvents().filter(e=>Date.parse(e.end)>now).slice(0,8),radarDry=decision.dry;
  if(!events.length){
    $('events').innerHTML=(radarDry?'<div class="dryWindow"><strong>Ventana seca probable · '+durationText(radarDry.start,radarDry.end)+'</strong><span>hasta ~'+fmtTime(radarDry.end)+'</span></div>':'')+'<div class="status">Sin episodios relevantes.</div>';
    return;
  }
  const blocks=[];
  if(radarDry){
    blocks.push('<div class="dryWindow dryWindowPrimary"><strong>AHORA · Ventana seca probable · '+durationText(radarDry.start,radarDry.end)+'</strong><span>hasta ~'+fmtTime(radarDry.end)+'</span></div>');
  }
  events.forEach((e,index)=>{
    const durMinutes=Math.max(1,Math.round((Date.parse(e.end)-Date.parse(e.start))/60_000));
    const total=Number(e.totalExpectedPrecipitation||0),peak=Number(e.maxExpectedPrecipitation||0);
    const avgProb=pct(e.averageProbability??e.peakProbability),maxProb=pct(e.peakProbability);
    const families=e.independentFamilyCount||e.providerCount||0;
    const rows=eventDetailRows(e),segments=semanticSegments(e),heavyWindows=heavyRainWindows(rows);
    const heavyAlert=heavyWindows.length
      ? '<div class="eventHeavyNotice"><strong>⚠ Tramos de lluvia fuerte</strong><span>'+heavyWindowsText(heavyWindows)+'</span></div>'
      : '';
    const segmentsHtml='<div class="eventSegments"><div class="segmentTitle">Evolución prevista</div>'+
      segments.map(segment=>'<div class="eventSegment wx-'+conditionVisual(segment.rows[0]||{}).key+'"><span class="segmentTime">'+fmtSegmentRange(segment.start,segment.end)+'</span><span class="segmentText"><strong>'+segment.label+'</strong><small>Prob. media '+segment.avgProb+'% · intensidad '+segment.rateText+'</small></span></div>').join('')+
      '</div>';
    const detailRows=rows.map(row=>{
      const visual=row.visual||conditionVisual(row),prob=Math.round(Number(row.probability)||0)+'%';
      const rate=(Number(row.precipitation)||0).toFixed(1).replace('.',',')+' mm/h';
      return '<div class="eventHour wx-'+visual.key+'"><b>'+fmtDetailRange(row.time,row.end)+'</b><span class="ehCondition"><span class="wxIcon">'+visual.icon+'</span>'+visual.label+'<span class="ehPhenomenon">'+row.detailSource+'</span></span><span class="ehProb">'+prob+'</span><span class="ehRate">'+rate+'</span></div>';
    }).join('');
    const header='<div class="eventHourHead"><span>Tramo</span><span>Tiempo</span><span>Prob.</span><span>Intens.</span></div>';
    const fineCount=rows.filter(r=>r.detailMinutes===15).length,coarseCount=rows.filter(r=>r.detailMinutes===30).length;
    const detailLabel=fineCount&&coarseCount?'15 min mientras hay radar fiable · después 30 min':fineCount?'detalle cada 15 min':'detalle cada 30 min';
    const details='<details class="hourDetails"><summary>Ver '+detailLabel+' ('+rows.length+')</summary><div class="eventHours">'+header+detailRows+'</div></details>';
    const primary=segments[0]?.label||conditionLabel(rows[0]||{precipitation:peak,probability:maxProb});
    const startsIn=(Date.parse(e.start)-now)/60_000,active=Date.parse(e.start)<=now&&Date.parse(e.end)>now;
    const open=active||startsIn<=180;
    const warning=heavyWindows.length?' · ⚠ fuerte':'';
    const summary='<summary class="eventSummary"><span><b>'+fmtDateTime(e.start)+'–'+fmtTime(e.end)+'</b><small>'+primary+warning+'</small></span><strong>'+maxProb+'%</strong></summary>';
    const startWindow=e.startWindow?.earliest&&e.startWindow?.latest?'inicio '+fmtTime(e.startWindow.earliest)+'–'+fmtTime(e.startWindow.latest):'';
    const endWindow=e.endWindow?.earliest&&e.endWindow?.latest?'fin '+fmtTime(e.endWindow.earliest)+'–'+fmtTime(e.endWindow.latest):'';
    const timingWindow=[startWindow,endWindow].filter(Boolean).join(' · ');
    const internalConflict=Math.round((Number(e.internalFamilyDisagreement)||0)*100);
    const conflictMeta=internalConflict>=20?'<span>conflicto det↔ens ~'+internalConflict+'%</span>':'';
    const meta='<div class="eventMeta"><span>'+durationText(e.start,e.end)+'</span><span>~'+total.toFixed(1).replace('.',',')+' mm</span><span>pico '+peak.toFixed(1).replace('.',',')+' mm/h</span><span>'+families+' familias</span>'+conflictMeta+(timingWindow?'<span>'+timingWindow+'</span>':'')+'</div>';
    blocks.push('<details class="event eventDisclosure" '+(open?'open':'')+'>'+summary+'<div class="eventExpanded">'+heavyAlert+meta+segmentsHtml+details+'</div></details>');
    const dry=dryWindowBetween(e,events[index+1]);
    if(dry)blocks.push('<div class="dryWindow"><strong>Ventana seca probable · '+durationText(dry.start,dry.end)+'</strong><span>'+fmtDateTime(dry.start)+' → '+fmtTime(dry.end)+'</span></div>');
  });
  $('events').innerHTML=blocks.join('');
}

function modelSourceDetail(source,base){
  if(source?.fallback)return base+' · última previsión válida · sin actualización en vivo';
  if(source?.stale)return base+' · DESACTUALIZADO · retraso ~'+Math.max(0,Math.round(Number(source.delayMinutes)||0))+' min · excluido del consenso';
  if(source?.freshnessStatus==='fresh'){
    const run=source.initialisedAt?' · run '+fmtTime(source.initialisedAt):'';
    return base+run+' · frescura verificada';
  }
  if(source?.freshnessStatus==='propagating'){
    const run=source.initialisedAt?' · run '+fmtTime(source.initialisedAt):'';
    const age=Number.isFinite(Number(source.availabilityAgeMinutes))?' · disponible hace ~'+Math.max(0,Math.round(Number(source.availabilityAgeMinutes)))+' min':'';
    return base+run+' · EN PROPAGACIÓN'+age+' · confianza temporal suavizada';
  }
  if(source?.freshnessStatus==='unknown')return base+' · frescura no verificable';
  return base;
}
function renderSources(){
  const opera=state.data.opera,opNow=opera?.nowcast,opEvent=opNow?.event;
  const opFresh=operaFreshness(opera),rvFresh=radarFreshness(state.data.radar);
  const opAge=Number.isFinite(opFresh.ageMinutes)?Math.round(opFresh.ageMinutes):null;
  const rvAge=Number.isFinite(rvFresh.ageMinutes)?Math.round(rvFresh.ageMinutes):null;
  const opSpeed=Number(opNow?.motion?.speedKmh),opDir=compassDirection(opNow?.motion?.bearingDegrees);
  const opMotion=opNow?.status==='ok'
    ? ' · movimiento '+(Number.isFinite(opSpeed)?Math.round(opSpeed)+' km/h'+(opDir?' '+opDir:''):'calculado')+(opEvent?.start?' · ETA '+fmtTime(opEvent.start):' · sin llegada en 2 h')
    : opNow?.status?' · nowcast '+opNow.status:'';
  const opDetail=opFresh.ok
    ? 'EUMETNET OPERA · RATE '+(opera.resolutionKm||2)+' km / 5 min · hace '+opAge+' min'+(opera.sample?.ok?' · '+Number(opera.sample.rateMmH||0).toFixed(1)+' mm/h':'')+(opNow?.status==='ok'?' · flujo local · útil ~'+Math.round(Number(opNow.reliableHorizonMinutes)||45)+' min':'')+opMotion
    : opera?.ok?'EUMETNET OPERA desactualizado'+(opAge!==null?' · hace '+opAge+' min':'')+' · excluido de ETA/consenso':'EUMETNET OPERA sin compuesto reciente';
  const rvDetail=rvFresh.ok
    ? (state.nowcast?.status==='ok'?'hace '+rvAge+' min · flujo local + evolución · útil ~'+Math.max(0,Number(state.nowcast?.reliableHorizonMinutes)||0)+' min':'hace '+rvAge+' min · '+(state.nowcast?.status||'solo mapa'))
    : state.data.radar?'desactualizado'+(rvAge!==null?' · hace '+rvAge+' min':'')+' · solo mapa histórico':'sin radar';
  const modelSources=[...(state.data.sources.deterministic||[]),...(state.data.sources.ensembles||[])];
  const healthyModels=modelSources.filter(x=>x.ok);
  const healthyFamilies=new Set(healthyModels.map(x=>x.family||x.id).filter(Boolean)).size;
  const fallbackAge=Number(state.data?.degradedCacheAgeMs)||0;
  const propagation=state.data?.sources?.propagation;
  const nearInternal=(state.data?.timeline||[]).slice(0,8)
    .map(row=>Number(row.internalDisagreement))
    .filter(Number.isFinite);
  const internalDisagreement=nearInternal.length?Math.round(nearInternal.reduce((sum,value)=>sum+value,0)/nearInternal.length):0;
  const trustParts=[];
  if(propagation?.propagatingFamilies)trustParts.push(propagation.propagatingFamilies+' familias con run propagándose');
  if(propagation?.unknownFamilies)trustParts.push(propagation.unknownFamilies+' familias con frescura no verificable');
  if(Number(propagation?.confidencePenalty)>0)trustParts.push('confianza -'+Math.round(Number(propagation.confidencePenalty)*100)+' pt');
  if(internalDisagreement>=20)trustParts.push('conflicto det↔ens ~'+internalDisagreement+'%');
  const propagationText=trustParts.length?' · '+trustParts.join(' · '):'';
  const consensusDetail=state.data?.degradedForecast
    ? 'MODO DEGRADADO · última previsión válida de hace '+Math.max(1,Math.round(fallbackAge/60_000))+' min · confianza máxima '+Math.round((Number(state.data?.degradedConfidenceCap)||0)*100)+'%'
    : healthyFamilies+' familias independientes activas · '+healthyModels.length+'/'+modelSources.length+' modelos/ensembles disponibles · quórum mínimo 2'+propagationText;
  const list=[
    {label:'Consenso modelos',ok:!state.data?.degradedForecast&&healthyFamilies>=2,detail:consensusDetail},
    {label:'Radar europeo',ok:Boolean(state.data.sources.opera),detail:opDetail},
    {label:'Radar RainViewer',ok:Boolean(state.data.sources.radar),detail:rvDetail},
    {label:nativeQuarterHourLikely()?'Modelo 15 min nativo':'Guía temporal',ok:state.data.sources.quarterHour,detail:nativeQuarterHourLikely()
      ? 'resolución de 15 min disponible para esta zona'
      : 'en esta ubicación el dato de 15 min se trata como interpolado; no amplía la resolución real'},
    ...state.data.sources.deterministic.map(x=>({label:x.label,ok:x.ok,detail:modelSourceDetail(x,'determinista')})),
    ...state.data.sources.ensembles.map(x=>({label:x.label,ok:x.ok,detail:modelSourceDetail(x,x.members?x.members+' miembros':'ensemble')}))
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
  state.map.on('zoomend',()=>{
    if(state.mapLoaded&&Number(state.radarOffset)>0)showProjectedRadar(state.radarOffset);
  });
}
function updateMapLocation(){
  if(!state.map||!state.mapLoaded)return;
  state.map.jumpTo({center:[state.loc.lon,state.loc.lat]});
  const src=state.map.getSource('raineta-location');
  if(src?.setData)src.setData(locationGeoJSON());
}
function centerRadarMap(){
  if(!state.map||!state.mapLoaded)return;
  state.map.easeTo({center:[state.loc.lon,state.loc.lat],duration:450});
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
function radarProjectionZoom(){
  const mapZoom=Number(state.map?.getZoom?.());
  if(!Number.isFinite(mapZoom))return Math.max(5,RADAR_ZOOM-1);
  const canvas=state.map?.getCanvas?.();
  const width=Math.max(512,Number(canvas?.clientWidth)||512);
  const height=Math.max(512,Number(canvas?.clientHeight)||512);
  const viewportFactor=Math.max(width,height)/512;
  const extraCoverage=Math.max(0,Math.ceil(Math.log2(viewportFactor)));
  return Math.max(5,Math.min(RADAR_ZOOM,Math.floor(mapZoom)-extraCoverage));
}
function radarProjectionControl(){
  const motion=state.nowcast?.motion;
  const globalSpeed=Number(motion?.speedKmh);
  const globalBearing=Number(motion?.bearingDegrees);
  const confidence=Math.max(0,Math.min(1,Number(state.nowcast?.confidence)||0));
  const evolution=Math.max(0,Math.min(1,Number(state.nowcast?.evolution?.score)||0));
  const samples=Math.max(0,Number(motion?.samples)||0);
  const ok=Boolean(
    state.nowcast?.status==='ok'&&motion&&samples>=2&&
    Number.isFinite(globalSpeed)&&globalSpeed>=0&&globalSpeed<=MAX_RADAR_ADVECTION_KMH&&
    Number.isFinite(globalBearing)&&confidence>=RADAR_PROJECTION_MIN_CONFIDENCE&&evolution>=RADAR_PROJECTION_MIN_EVOLUTION
  );
  const localSpeed=Number(motion?.localSpeedKmh),localBearing=Number(motion?.localBearingDegrees);
  const localQuality=Math.max(0,Math.min(1,(Number(motion?.localFlowConfidence)||0)*.7+(Number(motion?.localFlowCoverage)||0)*.3));
  const headingDifference=Number.isFinite(globalBearing)&&Number.isFinite(localBearing)
    ? Math.abs((((localBearing-globalBearing)+540)%360)-180)
    : Infinity;
  const speedDifference=Number.isFinite(localSpeed)&&Number.isFinite(globalSpeed)
    ? Math.abs(localSpeed-globalSpeed)/Math.max(20,globalSpeed)
    : Infinity;
  const localUsable=ok&&Number.isFinite(localSpeed)&&localSpeed>=0&&localSpeed<=MAX_RADAR_ADVECTION_KMH&&
    Number.isFinite(localBearing)&&localQuality>=.35&&headingDifference<=50&&speedDifference<=.65;
  return{
    ok,globalSpeed,globalBearing,localSpeed,localBearing,localQuality,
    localBlend:localUsable?Math.min(.28,localQuality*.28):0,
    confidence,evolution
  };
}
function radarImageCoordinates(centerLat,centerLon,displayZoom=RADAR_ZOOM){
  const zoom=Math.max(0,Number(displayZoom)||0);
  const world=256*(2**zoom);
  const lat=Math.max(-85.05112878,Math.min(85.05112878,Number(centerLat)||0));
  const lon=Number(centerLon)||0;
  const latRad=lat*Math.PI/180;
  const centerX=(lon+180)/360*world;
  const centerY=(1-Math.log(Math.tan(latRad)+1/Math.cos(latRad))/Math.PI)/2*world;
  // RainViewer size=512 is a high-resolution rendition of one logical XYZ tile.
  // Its geographic footprint is therefore 256 logical map pixels, not 512.
  const halfLogicalTile=128;
  const lonAt=x=>x/world*360-180;
  const latAt=y=>Math.atan(Math.sinh(Math.PI*(1-2*y/world)))*180/Math.PI;
  const west=lonAt(centerX-halfLogicalTile),east=lonAt(centerX+halfLogicalTile);
  const north=latAt(centerY-halfLogicalTile),south=latAt(centerY+halfLogicalTile);
  return[[west,north],[east,north],[east,south],[west,south]];
}
function projectionCoordinates(minutes,displayZoom=RADAR_ZOOM){
  const motion=state.nowcast?.motion;
  const lat=Number(state.loc.lat),lon=Number(state.loc.lon);
  const requested=Math.max(0,Number(minutes)||0);
  const control=radarProjectionControl();
  if(!control.ok||requested<=0)return radarImageCoordinates(lat,lon,displayZoom);
  const reliable=Math.max(0,Number(state.nowcast?.reliableHorizonMinutes)||0);
  const turn=radarTurnTrend();
  const turnMinutes=Math.min(requested,reliable,45);
  const turnAdjustment=turn&&requested>=5
    ? Math.max(-4,Math.min(4,.35*Number(turn.rateDegPerMinute)*turnMinutes*Number(turn.confidence)))
    : 0;
  const globalBearing=(control.globalBearing+turnAdjustment)*Math.PI/180;
  const localBearing=Number.isFinite(control.localBearing)?(control.localBearing+turnAdjustment)*Math.PI/180:NaN;
  const quality=.55*control.confidence+.45*control.evolution;
  const extra=Math.max(0,requested-reliable);
  const maxExtra=12+18*quality;
  const effectiveMinutes=requested<=reliable
    ? requested
    : reliable+maxExtra*(1-Math.exp(-extra/45));
  const progress=reliable>0?Math.min(1,effectiveMinutes/reliable):0;
  const blend=Number.isFinite(control.localSpeed)&&Number.isFinite(localBearing)
    ? control.localBlend*progress
    : 0;
  const globalEast=control.globalSpeed*Math.sin(globalBearing),globalNorth=control.globalSpeed*Math.cos(globalBearing);
  const localEast=Number.isFinite(control.localSpeed)?control.localSpeed*Math.sin(localBearing):globalEast;
  const localNorth=Number.isFinite(control.localSpeed)?control.localSpeed*Math.cos(localBearing):globalNorth;
  const eastKmh=globalEast*(1-blend)+localEast*blend;
  const northKmh=globalNorth*(1-blend)+localNorth*blend;
  const east=eastKmh*effectiveMinutes/60,north=northKmh*effectiveMinutes/60;
  const shiftedLat=lat+north/111.32;
  const shiftedLon=lon+east/(111.32*Math.max(.25,Math.cos(lat*Math.PI/180)));
  return radarImageCoordinates(shiftedLat,shiftedLon,displayZoom);
}
function nearestObservedFrame(offsetMinutes){
  const latest=state.frames.at(-1);if(!latest)return null;
  const target=latest.time+Number(offsetMinutes)*60;
  return state.frames.reduce((best,f)=>Math.abs(f.time-target)<Math.abs(best.time-target)?f:best,state.frames[0]);
}
function showObservedRadar(offsetMinutes){
  const r=state.data?.radar,f=nearestObservedFrame(offsetMinutes);if(!r||!f||!state.mapLoaded)return;
  clearRadarVisual();
  state.radarProjectionImageKey=null;
  state.map.addSource('raineta-radar',{
    type:'raster',
    tiles:[radarFrameHost(r,f)+f.path+'/256/{z}/{x}/{y}/2/1_1.png'],
    tileSize:256,maxzoom:7,attribution:'Weather data by RainViewer'
  });
  const before=state.map.getLayer('raineta-location')?'raineta-location':undefined;
  state.map.addLayer({id:'raineta-radar',type:'raster',source:'raineta-radar',paint:{'raster-opacity':.76,'raster-fade-duration':0}},before);
  const latest=state.frames.at(-1),delta=Math.round((f.time-latest.time)/60);
  const frameIndex=Math.max(0,state.frames.findIndex(row=>Number(row.time)===Number(f.time)));
  $('radarTime').textContent=fmtTime(f.time*1000);
  $('radarPosition').textContent=delta<0?'Observado '+Math.abs(delta)+' min antes · '+fmtTime(f.time*1000):'Último radar observado · '+fmtTime(f.time*1000);
  if($('radarFrameStatus'))$('radarFrameStatus').textContent='OBSERVADO · frame '+(frameIndex+1)+'/'+state.frames.length+' · '+fmtTime(f.time*1000);
  $('radarMotion').textContent='Imagen observada real de RainViewer. A la derecha de AHORA la proyección es orientativa y pierde peso conforme avanza el horizonte.';
}
function projectedRadarOpacity(minutes,canMove,reliable){
  const requested=Math.max(0,Math.min(RADAR_VISUAL_HORIZON_MINUTES,Number(minutes)||0));
  if(!canMove){
    const progress=requested/RADAR_VISUAL_HORIZON_MINUTES;
    return Math.max(.16,.34-.18*progress);
  }
  const confidence=Math.max(0,Math.min(1,Number(state.nowcast?.confidence)||0));
  const evolution=Math.max(0,Math.min(1,Number(state.nowcast?.evolution?.score)||0));
  const quality=.55*confidence+.45*evolution;
  const safeReliable=Math.max(1,Number(reliable)||1);
  const startOpacity=.70*(.86+.14*quality);
  if(requested<=safeReliable){
    const progress=Math.max(0,Math.min(1,requested/safeReliable));
    return Math.max(.46,startOpacity*(1-.18*progress));
  }
  const horizonOpacity=Math.max(.48,startOpacity*.82);
  const beyond=Math.max(0,Math.min(1,(requested-safeReliable)/Math.max(1,RADAR_VISUAL_HORIZON_MINUTES-safeReliable)));
  return Math.max(.30,horizonOpacity-(horizonOpacity-.30)*beyond);
}
function showProjectedRadar(minutes){
  const r=state.data?.radar,latest=state.frames.at(-1),motion=state.nowcast?.motion;
  if(!r||!latest||!state.mapLoaded)return;
  const control=radarProjectionControl(),canMove=control.ok;
  removeRadarLayer('raineta-radar');
  const reliable=nowcastReliableHorizon(),within=canMove&&minutes<=reliable;
  const projectedAt=latest.time*1000+minutes*60_000;
  if(!canMove||minutes>reliable){
    removeRadarLayer('raineta-radar-projection');
    state.radarProjectionImageKey=null;
    $('radarTime').textContent=fmtTime(projectedAt);
    if($('radarFrameStatus'))$('radarFrameStatus').textContent='SIN CAMPO RADAR FIABLE · +'+Math.round(minutes)+' min · '+fmtTime(projectedAt);
    $('radarPosition').textContent='Sin proyección espacial fiable · +'+Math.round(minutes)+' min · '+fmtTime(projectedAt);
    $('radarMotion').textContent=canMove
      ? 'El radar observado ya ha superado su horizonte fiable (~'+reliable+' min). RainETA no desplaza ni congela ecos artificialmente; la ETA pasa a modelos y consenso.'
      : 'No hay movimiento radar suficientemente fiable. RainETA no inventa una trayectoria; la ETA procede de modelos y consenso.';
    return;
  }
  const displayZoom=radarProjectionZoom();
  const url=radarDisplayImageUrl(r,latest,512,displayZoom),coordinates=projectionCoordinates(canMove?minutes:0,displayZoom);
  const before=state.map.getLayer('raineta-location')?'raineta-location':undefined;
  let source=state.map.getSource('raineta-radar-projection');
  const imageKey=latest.path+'@z'+displayZoom;
  if(!source||state.radarProjectionImageKey!==imageKey){
    removeRadarLayer('raineta-radar-projection');
    state.map.addSource('raineta-radar-projection',{type:'image',url,coordinates});
    state.map.addLayer({
      id:'raineta-radar-projection',type:'raster',source:'raineta-radar-projection',
      paint:{'raster-opacity':.66,'raster-fade-duration':0}
    },before);
    state.radarProjectionImageKey=imageKey;
    source=state.map.getSource('raineta-radar-projection');
  }else if(typeof source.setCoordinates==='function'){
    source.setCoordinates(coordinates);
  }
  const opacity=projectedRadarOpacity(minutes,canMove,reliable);
  if(state.map.getLayer('raineta-radar-projection'))state.map.setPaintProperty('raineta-radar-projection','raster-opacity',opacity);
  $('radarTime').textContent=fmtTime(projectedAt);
  if($('radarFrameStatus'))$('radarFrameStatus').textContent='PROYECCIÓN · +'+Math.round(minutes)+' min · paso 1 min · '+fmtTime(projectedAt);
  if(canMove){
    $('radarPosition').textContent=(within?'Radar útil':'Proyección orientativa')+' · +'+Math.round(minutes)+' min · '+fmtTime(projectedAt);
    if(within){
      const evolution=Number(state.nowcast?.evolution?.score)||0;
      const shape=evolution>=.72?'estable':evolution>=.48?'cambiante':'muy cambiante';
      const turn=radarTurnTrend();
      const curve=turn?' · rumbo reciente '+(turn.rateDegPerMinute>0?'girando a la derecha':'girando a la izquierda')+' (ajuste limitado)':'';
      $('radarMotion').textContent='Proyección continua del radar observado · evolución '+shape+curve+' · horizonte radar útil ~'+reliable+' min.';
    }else{
      $('radarMotion').textContent='Fuera del horizonte fiable (~'+reliable+' min), el movimiento y la opacidad decaen de forma continua: es solo referencia visual; la ETA y la decisión pasan a modelos/consenso.';
    }
  }else{
    $('radarPosition').textContent='Referencia visual orientativa · +'+Math.round(minutes)+' min · '+fmtTime(projectedAt);
    $('radarMotion').textContent='Sin movimiento radar suficientemente fiable: se conserva el último radar como referencia visual con desvanecimiento continuo mientras la ETA y la decisión proceden de modelos/consenso.';
  }
}
function showRadarOffset(offset=state.radarOffset){
  state.radarOffset=Math.max(Number($('frame')?.min)||-90,Math.min(RADAR_VISUAL_HORIZON_MINUTES,Number(offset)||0));
  if($('frame'))$('frame').value=state.radarOffset;
  if(state.radarOffset<=0)showObservedRadar(state.radarOffset);
  else showProjectedRadar(state.radarOffset);
  updateRadarStepButtons();
}
function radarArrivalSource(ev){
  if(ev?.kind==='radarFusion')return'radar + radar europeo';
  if(ev?.kind==='opera')return'radar europeo';
  if(ev?.kind==='radar')return'radar RainViewer';
  if(ev?.kind==='model15')return'modelos';
  return'modelos';
}
function radarArrivalTarget(){
  const latest=state.frames.at(-1),decision=state.data?buildRainDecision():null,ev=decision?.event||null;
  if(!latest||!ev?.start)return{status:'no_eta',event:ev||null};
  const baseMs=Number(latest.time)*1000,startMs=Date.parse(ev.start);
  if(!Number.isFinite(baseMs)||!Number.isFinite(startMs))return{status:'no_eta',event:ev};
  const rawMinutes=(startMs-baseMs)/60_000,reliable=nowcastReliableHorizon();
  if(decision?.mode==='possible_now'&&(ev.active||rawMinutes<=2.5))return{status:'signal_now',target:0,event:ev,rawMinutes,reliable};
  if(ev.active||rawMinutes<=2.5)return{status:'now',target:0,event:ev,rawMinutes,reliable};
  if(rawMinutes>RADAR_VISUAL_HORIZON_MINUTES)return{status:'later',event:ev,rawMinutes,reliable};
  const radarDriven=['radar','opera','radarFusion'].includes(ev.kind);
  const canProject=state.nowcast?.status==='ok'&&state.nowcast?.motion&&Number(state.nowcast?.confidence)>=.20;
  const sourceType=radarDriven&&rawMinutes<=reliable?'radar':radarDriven?'radar+modelos':'modelos';
  return{
    status:'ready',
    target:Math.max(0,Math.min(RADAR_VISUAL_HORIZON_MINUTES,rawMinutes)),
    event:ev,rawMinutes,reliable,sourceType,
    modelBased:sourceType!=='radar',
    canProject
  };
}
function stopRadarPlayback(){
  if(state.playTimer){clearInterval(state.playTimer);state.playTimer=null}
  state.playMode=null;
  if($('play'))$('play').textContent='▶';
  if($('radarArrival')){
    $('radarArrival').classList.remove('running');
    updateRadarArrivalButton();
  }
}
function updateRadarArrivalButton(){
  const button=$('radarArrival');if(!button||state.playMode==='arrival')return;
  const target=radarArrivalTarget();
  button.classList.remove('running');
  if(target.status==='ready'){
    button.disabled=false;button.textContent='▶ HASTA LLUVIA';
    button.title=target.sourceType==='radar'
      ? 'Avanza hasta la ETA respaldada por radar'
      : 'Avanza hasta la ETA del consenso/modelos; fuera del radar fiable la imagen es orientativa';
  }else if(target.status==='signal_now'){
    button.disabled=false;button.textContent='● SEÑAL RADAR AHORA';button.title='';
  }else if(target.status==='now'){
    button.disabled=false;button.textContent='● LLUVIA AHORA';button.title='';
  }else if(target.status==='later'){
    button.disabled=true;button.textContent='ETA > 4 H';button.title='';
  }else{
    button.disabled=true;button.textContent='SIN ETA';button.title='';
  }
}
function markRadarArrival(target){
  const ev=target?.event;if(!ev)return;
  const source=target.sourceType==='radar+modelos'?'radar + modelos':radarArrivalSource(ev);
  $('radarPosition').textContent='Llegada estimada · '+fmtTime(ev.start)+' · +'+Math.round(target.target)+' min';
  if(target.sourceType==='radar'){
    $('radarMotion').textContent='RainETA se detiene aquí: '+source+' sitúa el inicio de la lluvia sobre tu ubicación alrededor de '+fmtTime(ev.start)+(ev.uncertainty?' · '+uncertaintyText(ev):'')+'.';
  }else{
    const visual=target.canProject
      ? 'La proyección visual es orientativa fuera del horizonte fiable.'
      : 'Sin movimiento radar fiable, el último radar se mantiene atenuado solo como referencia visual orientativa.';
    $('radarMotion').textContent='RainETA se detiene en la ETA de '+source+' ('+fmtTime(ev.start)+'). '+visual+' La hora y la decisión las fija el consenso/modelos.';
  }
}
function playRadarUntilRain(){
  const target=radarArrivalTarget(),slider=$('frame'),button=$('radarArrival');
  if(!slider||!button)return;
  if(state.playMode==='arrival'){stopRadarPlayback();return}
  if(target.status==='signal_now'||target.status==='now'){
    stopRadarPlayback();slider.value='0';showRadarOffset(0);
    $('radarPosition').textContent=target.status==='signal_now'
      ? 'El radar marca precipitación sobre el punto, no confirmada en superficie'
      : 'La lluvia ya está en tu ubicación';
    return;
  }
  if(target.status!=='ready'){
    updateRadarArrivalButton();
    if(target.status==='later')$('radarPosition').textContent='La llegada prevista queda fuera de las próximas 4 h';
    else $('radarPosition').textContent='Todavía no hay una ETA de lluvia que pueda mostrarse en el radar';
    return;
  }
  stopRadarPlayback();
  let current=Number(slider.value);
  if(!Number.isFinite(current)||current<0||current>=target.target)current=0;
  slider.value=String(current);showRadarOffset(current);
  state.playMode='arrival';
  button.disabled=false;button.classList.add('running');button.textContent='❚❚ HASTA LLUVIA';
  const tickMs=100;
  state.playTimer=setInterval(()=>{
    const currentOffset=Number(slider.value)||0;
    const next=Math.min(target.target,currentOffset+1);
    slider.value=String(next);showRadarOffset(next);
    if(next>=target.target){
      if(state.playTimer){clearInterval(state.playTimer);state.playTimer=null}
      state.playMode=null;
      button.classList.remove('running');
      updateRadarArrivalButton();
      markRadarArrival(target);
      try{navigator.vibrate?.([20,40,20])}catch{}
    }
  },tickMs);
}
function renderRadar(){
  initMap();if(!state.map)return;
  updateMapLocation();
  const r=state.data.radar;if(!r?.frames?.length){$('radarTime').textContent='sin radar';return}
  const latestSource=r.frames.at(-1);
  const cutoff=Number(latestSource?.time)-RADAR_PAST_HORIZON_MINUTES*60;
  state.frames=r.frames.filter(frame=>Number(frame.time)>=cutoff).sort((a,b)=>Number(a.time)-Number(b.time));
  const latest=state.frames.at(-1),oldest=state.frames[0];
  const availablePast=Math.min(RADAR_PAST_HORIZON_MINUTES,Math.max(5,Math.round((latest.time-oldest.time)/60/5)*5));
  $('frame').min=String(-availablePast);$('frame').max=String(RADAR_VISUAL_HORIZON_MINUTES);$('frame').step='1';
  $('radarPastLabel').textContent=availablePast>=240?'−4 h':'−'+availablePast+' min';
  state.radarOffset=Math.max(-availablePast,Math.min(RADAR_VISUAL_HORIZON_MINUTES,state.radarOffset||0));
  $('frame').value=state.radarOffset;
  const reliable=nowcastReliableHorizon(),evolution=Number(state.nowcast?.evolution?.score)||0;
  if($('radarHandoff')){
    const label=evolution>=.72?'estable':evolution>=.48?'cambiante':'muy cambiante';
    const history=availablePast>=240?'histórico observado 4 h':'histórico observado '+availablePast+' min · acumulando hasta 4 h';
    $('radarHandoff').innerHTML='<b>Radar útil ~'+reliable+' min</b><span>'+history+' · evolución '+label+' · después del límite manda el consenso</span>';
  }
  if($('radarReliableMarker')){
    const min=-availablePast,max=RADAR_VISUAL_HORIZON_MINUTES,left=(reliable-min)/(max-min)*100;
    $('radarReliableMarker').style.left=Math.max(0,Math.min(100,left))+'%';
    $('radarReliableMarker').title='Horizonte radar fiable ~'+fmtTime(latest.time*1000+reliable*60_000);
  }
  if($('radarReliableLabel')){
    $('radarReliableLabel').textContent='fiable hasta ~'+fmtTime(latest.time*1000+reliable*60_000);
  }
  if(state.mapLoaded)showRadarOffset(state.radarOffset);
  updateRadarArrivalButton();
}

async function refreshRadar(renderAfter=true){
  if(state.radarLoading||!state.data)return false;
  state.radarLoading=true;
  try{
    const [qhResult,radarResult,operaResult,aemetResult]=await Promise.allSettled([
      fetchQuarterHour(),fetchRadarMeta(),fetchOperaMeta(),fetchAemetRadarMeta()
    ]);
    const quarterHourFresh=qhResult.status==='fulfilled';
    const quarterHour=quarterHourFresh?qhResult.value:state.data.quarterHour;
    const radar=radarResult.status==='fulfilled'?radarResult.value:state.data.radar;
    const opera=operaResult.status==='fulfilled'?operaResult.value:state.data.opera;
    const aemetRadar=aemetResult.status==='fulfilled'?aemetResult.value:state.data.aemetRadar;
    const sources={
      ...state.data.sources,
      quarterHour:Boolean(quarterHour)&&(!state.data.degradedForecast||quarterHourFresh),
      radar:radarFreshness(radar).ok,
      opera:operaFreshness(opera).ok,
      aemetRadar:aemetRadarFreshness(aemetRadar).ok
    };
    const all=[...(sources.deterministic||[]),...(sources.ensembles||[])];
    sources.health={
      available:all.filter(x=>x.ok).length+(sources.quarterHour?1:0)+(sources.radar?1:0)+(sources.opera?1:0)+(sources.aemetRadar?1:0),
      total:all.length+4
    };
    state.data={...state.data,quarterHour,radar,opera,aemetRadar,sources,liveUpdatedAt:new Date().toISOString()};
    state.nowcast=radar
      ? await computeNowcast(radar).catch(e=>({status:'radar_analysis_failed',confidence:0,event:null,error:String(e?.message||e)}))
      : state.nowcast;
    if(state.playMode==='arrival')stopRadarPlayback();
    recordRadarMotionObservation();
    recordRadarEtaObservation();
    updateRadarValidation();
    state.lastRadarRefresh=Date.now();
    state.lastCompletedAt=new Date().toISOString();
    if(renderAfter)render();
    return true;
  }catch(e){
    if(state.nowcast)state.nowcast={...state.nowcast,refreshError:String(e?.message||e)};
    return false;
  }finally{state.radarLoading=false}
}

async function load(force=false){
  if(state.loading)return;state.loading=true;
  const hadData=Boolean(state.data);
  if(!hadData){
    $('eta').textContent='Calculando…';$('summary').hidden=false;$('summary').textContent='Fusionando radar, modelos y ensembles.';
  }else if(force&&$('updated')){
    $('updated').textContent='Actualizando fuentes… · se mantiene la última previsión visible';
  }
  try{
    state.data=await loadForecast(force);
    const cachedLiveAge=Number(state.data?.cacheAgeMs)||0;
    const refreshed=cachedLiveAge>90_000?await refreshRadar(false):false;
    if(!refreshed){
      state.nowcast=await computeNowcast(state.data.radar).catch(e=>({status:'radar_analysis_failed',confidence:0,event:null,error:String(e?.message||e)}));
      state.lastRadarRefresh=Date.now();
    }
    recordRadarMotionObservation();
    recordRadarEtaObservation();
    updateRadarValidation();
    state.lastCompletedAt=new Date().toISOString();
    render();
  }catch(e){
    $('eta').textContent='Sin datos';$('summary').hidden=false;$('summary').textContent=String(e?.message||e);
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

function canonicalEpisodeSnapshot(now=Date.now()){
  const radarEvent=chooseDisplayEvent();
  if(radarEvent?.end&&['radar','opera','radarFusion','observed'].includes(radarEvent.kind)){
    const end=Date.parse(radarEvent.end),start=Date.parse(radarEvent.start||'');
    if(Number.isFinite(end)&&end>now){
      return{
        start:Number.isFinite(start)?start:now,
        end, maxEnd:end,
        source:radarEvent.kind==='radarFusion'?'RainViewer+OPERA':radarEvent.kind,
        confidence:Number(radarEvent.confidence)||0
      };
    }
  }
  const current=(state.data?.events||[]).find(e=>Date.parse(e.start)<=now+5*60_000&&Date.parse(e.end)>now);
  if(current){
    const start=Date.parse(current.start),end=Math.min(Date.parse(current.end),now+180*60_000);
    if(Number.isFinite(start)&&Number.isFinite(end)&&end>now){
      return{start,end,maxEnd:end,source:'RainETA modelo',confidence:Number(current.timingConfidence)||Number(current.peakProbability)||.45};
    }
  }
  if(radarEvent?.end){
    const start=Date.parse(radarEvent.start||''),end=Math.min(Date.parse(radarEvent.end),now+180*60_000);
    if(Number.isFinite(end)&&end>now)return{start:Number.isFinite(start)?start:now,end,maxEnd:end,source:'RainETA',confidence:Number(radarEvent.confidence)||.4};
  }
  return null;
}
function recordFeedback(raining){
  if(!state.currentLocation||!samePlace(state.loc,state.currentLocation))return;
  const auto=automaticRainState(),now=Date.now(),episode=canonicalEpisodeSnapshot(now);
  const row={
    time:now,
    lat:state.currentLocation.lat,lon:state.currentLocation.lon,
    raining:Boolean(raining),predicted:Boolean(auto.raining),
    radarWetFraction:Number.isFinite(Number(state.nowcast?.currentWetFraction))?Number(state.nowcast.currentWetFraction):null,
    modelPrecip:Number(state.data?.quarterHour?.current?.precipitation)||0,
    threshold:calibratedRadarThreshold(),
    predictedEpisodeStart:episode?new Date(episode.start).toISOString():null,
    predictedEpisodeEnd:episode?new Date(episode.end).toISOString():null,
    predictedEpisodeMaxEnd:episode?new Date(episode.maxEnd).toISOString():null,
    predictedEpisodeSource:episode?.source||null,
    predictedEpisodeConfidence:Number(episode?.confidence)||null
  };
  const last=state.feedback.at(-1);
  if(last&&samePlace(last,row,.0015)&&now-last.time<90_000)state.feedback[state.feedback.length-1]=row;
  else state.feedback.push(row);
  state.feedback=state.feedback.slice(-120);persistFeedback();
  try{navigator.vibrate?.(25)}catch{}
  render();
}
function toggleSavedLocation(){
  const idx=state.savedLocations.findIndex(x=>samePlace(x,state.loc,.0015));
  if(idx>=0)state.savedLocations.splice(idx,1);
  else state.savedLocations.push({
    name:state.loc.isCurrent?'Mi ubicación guardada':state.loc.name,
    lat:state.loc.lat,lon:state.loc.lon,isCurrent:false,
    source:state.loc.isCurrent?'gps':'manual'
  });
  persistLocations();render();
}
async function fetchQuickSummary(loc){
  const p=new URLSearchParams({
    latitude:String(loc.lat),longitude:String(loc.lon),
    current:'temperature_2m,precipitation,rain,showers',
    minutely_15:'precipitation',forecast_minutely_15:'96',
    timeformat:'unixtime',timezone:'GMT'
  });
  const d=await fetchJson('https://api.open-meteo.com/v1/forecast?'+p,8000);
  const now=Date.now(),time=(d.minutely_15?.time||[]).map(iso),prec=(d.minutely_15?.precipitation||[]).map(v=>Number(v)||0);
  const events=detectQuarterHourEvents(time,prec).filter(e=>Date.parse(e.end)>now);
  const active=events.find(e=>Date.parse(e.start)<=now&&Date.parse(e.end)>now)||null;
  const nextFuture=events.find(e=>Date.parse(e.start)>now+60_000)||null;
  const next=active||nextFuture;
  const following=next?events.find(e=>Date.parse(e.start)>=Date.parse(next.end)+5*60_000)||null:null;
  const precipitation=Number(d.current?.precipitation)||0,horizonEnd=now+24*3600_000;
  const bestDry=events.length?bestDryWindow(events,now,horizonEnd,{minMinutes:45}):null;
  return{
    location:loc,
    temperature:Number(d.current?.temperature_2m),
    raining:precipitation>=.1,
    precipitation,
    active,next,nextFuture,following,bestDry,
    horizonHours:24
  };
}
function quickWhen(v){
  if(!v)return'—';
  const d=new Date(v),n=new Date();
  return d.toDateString()===n.toDateString()?fmtTime(v):fmtDateTime(v);
}
function allLocations(){
  const out=[];
  if(state.currentLocation)out.push({...state.currentLocation,isCurrent:true,name:'Mi ubicación'});
  for(const loc of state.savedLocations){
    const duplicateCurrent=out.some(x=>x.isCurrent&&samePlace(x,loc,.0015));
    if(!duplicateCurrent||loc.source==='gps')out.push({...loc,isCurrent:false});
  }
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
      const s=result.value,truth=loc.isCurrent?recentTruthFor(loc,4):null;
      const raining=truth===null?s.raining:truth;
      const sameCurrent=Boolean(state.data&&samePlace(loc,state.loc,.0015));
      const decision=sameCurrent?buildRainDecision():null;
      let nowText=raining?'LLUEVE':'NO LLUEVE',nextStart=null,nextEnd=null;
      if(decision){
        if(decision.mode==='possible_now')nowText='SEÑAL RADAR';
        else if(decision.mode==='episode_pause'||decision.mode==='episode_ended_early')nowText='NO LLUEVE';
        else nowText=decision.rain?.raining?'LLUEVE':'NO LLUEVE';
        nextStart=decision.rain?.raining?Date.now():decision.event?.start?Date.parse(decision.event.start):null;
        nextEnd=decision.event?.end?Date.parse(decision.event.end):null;
      }else{
        nextStart=raining?Date.now():s.nextFuture?.start?Date.parse(s.nextFuture.start):null;
        nextEnd=(raining?s.active?.end:s.nextFuture?.end)?Date.parse(raining?s.active.end:s.nextFuture.end):null;
      }
      const nextText=nextStart!=null?(raining?'Ahora':quickWhen(nextStart)):'Sin lluvia 24 h';
      const endText=nextEnd!=null?quickWhen(nextEnd):'—';
      const temp=Number.isFinite(s.temperature)?s.temperature.toFixed(1).replace('.',',')+' °C':'—';
      left.innerHTML=
        '<span class="locTitle"><strong>'+loc.name+(loc.isCurrent?' · GPS':'')+'</strong><small>'+temp+'</small></span>'+
        '<span class="locQuickGrid">'+
          '<span><small>Ahora</small><b class="'+(nowText==='LLUEVE'?'wet':'')+'">'+nowText+'</b></span>'+
          '<span><small>Próxima lluvia</small><b>'+nextText+'</b></span>'+
          '<span><small>Hasta cuándo</small><b>'+endText+'</b></span>'+
        '</span>';
    }else{
      left.innerHTML='<span class="locTitle"><strong>'+loc.name+(loc.isCurrent?' · GPS':'')+'</strong><small>sin datos</small></span><span class="locQuickGrid"><span><small>Ahora</small><b>—</b></span><span><small>Próxima lluvia</small><b>—</b></span><span><small>Hasta cuándo</small><b>—</b></span></span>';
    }
    left.onclick=()=>setLocation(loc);
    if(!loc.isCurrent){
      const actions=document.createElement('div');actions.className='locActions';
      const rename=document.createElement('button');rename.className='locAction';rename.textContent='✎';rename.title='Renombrar';
      rename.onclick=e=>{e.stopPropagation();openRenameLocation(loc)};
      const remove=document.createElement('button');remove.className='locAction danger';remove.textContent='🗑';remove.title='Eliminar';
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
document.querySelectorAll('.rangeBtn').forEach(btn=>btn.onclick=()=>{
  const hours=Number(btn.dataset.hours);
  if(![24,48,72].includes(hours))return;
  state.timelineHours=hours;
  localStorage.setItem('raineta.timelineHours',JSON.stringify(hours));
  if(state.selectedHourIndex!==null&&state.selectedHourIndex>=hours)state.selectedHourIndex=null;
  renderTimeline();
  if(state.selectedHourIndex===null)renderShortNowcast();
});
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
$('frame').oninput=function(){stopRadarPlayback();showRadarOffset(Number(this.value))};
$('radarNow').onclick=function(){
  stopRadarPlayback();
  $('frame').value='0';showRadarOffset(0);
};
$('radarArrival').onclick=playRadarUntilRain;
$('radarCenter').onclick=centerRadarMap;
$('radarPrev').onclick=stepRadarBackward;
$('radarNext').onclick=stepRadarForward;
function observedOffsets(){
  const latest=state.frames.at(-1);if(!latest)return[];
  return state.frames.map(f=>Math.round((Number(f.time)-Number(latest.time))/60)).filter(v=>v<=0).sort((a,b)=>a-b);
}
function nextObservedOffset(current){
  const offsets=observedOffsets();
  return offsets.find(v=>v>current+.5)??0;
}
function previousObservedOffset(current){
  const offsets=observedOffsets();
  for(let i=offsets.length-1;i>=0;i--)if(offsets[i]<current-.5)return offsets[i];
  return offsets[0]??0;
}
function updateRadarStepButtons(){
  const slider=$('frame');if(!slider)return;
  const current=Number(slider.value)||0,min=Number(slider.min)||0,max=Number(slider.max)||RADAR_VISUAL_HORIZON_MINUTES;
  if($('radarPrev'))$('radarPrev').disabled=current<=min+.5;
  if($('radarNext'))$('radarNext').disabled=current>=max-.5;
}
function stepRadarBackward(){
  stopRadarPlayback();
  const slider=$('frame');if(!slider)return;
  const current=Number(slider.value)||0;
  let next;
  if(current>0)next=Math.max(0,current-1);
  else next=previousObservedOffset(current);
  slider.value=String(next);showRadarOffset(next);updateRadarStepButtons();
}
function stepRadarForward(){
  stopRadarPlayback();
  const slider=$('frame');if(!slider)return;
  const current=Number(slider.value)||0;
  let next;
  if(current<0)next=nextObservedOffset(current);
  else next=Math.min(Number(slider.max)||RADAR_VISUAL_HORIZON_MINUTES,current+1);
  slider.value=String(next);showRadarOffset(next);updateRadarStepButtons();
}
$('play').onclick=function(){
  if(state.playMode==='loop'){stopRadarPlayback();return}
  stopRadarPlayback();
  if(!state.frames.length)return;
  const slider=$('frame');if(Number(slider.value)>=Number(slider.max))slider.value=slider.min;
  this.textContent='❚❚';state.playMode='loop';
  const tick=()=>{
    if(state.playMode!=='loop')return;
    const current=Number(slider.value)||0;
    let next,delay;
    if(current<0){
      next=nextObservedOffset(current);
      delay=RADAR_PAST_FRAME_MS;
    }else{
      next=current+1;
      delay=RADAR_FUTURE_TICK_MS;
    }
    if(next>Number(slider.max)){next=Number(slider.min);delay=RADAR_PAST_FRAME_MS}
    slider.value=String(next);showRadarOffset(next);
    state.playTimer=setTimeout(tick,delay);
  };
  state.playTimer=setTimeout(tick,Number(slider.value)<0?RADAR_PAST_FRAME_MS:RADAR_FUTURE_TICK_MS);
};
if('serviceWorker'in navigator){
  navigator.serviceWorker.register('/rain/sw.js',{updateViaCache:'none'}).then(reg=>{
    reg.update().catch(()=>{});
  }).catch(()=>{});
}
function scheduleAlignedLiveRefresh(){
  const now=Date.now(),lag=8_000;
  const next=Math.ceil(now/RADAR_REFRESH_MS)*RADAR_REFRESH_MS+lag;
  setTimeout(async()=>{
    if(document.visibilityState==='visible')await refreshRadar();
    scheduleAlignedLiveRefresh();
  },Math.max(5_000,next-now));
}
document.addEventListener('visibilitychange',()=>{
  if(document.visibilityState==='visible'&&Date.now()-state.lastRadarRefresh>90_000)refreshRadar();
});
scheduleAlignedLiveRefresh();
setInterval(()=>{if(document.visibilityState==='visible'&&state.data)updateLiveCountdown()},1000);
load();
