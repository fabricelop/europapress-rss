import {aggregateEnsembleModel,buildConsensus,compactTimeline,detectQuarterHourEvents,detectRainEvents,chooseNextEvent,median} from './core.js';
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
  data:null,nowcast:null,map:null,marker:null,radarLayer:null,frames:[],frameIndex:0,playTimer:null,loading:false,radarLoading:false,lastRadarRefresh:0,lastCompletedAt:null,view:'detail',locationsLoading:false
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
function currentTruth(maxAgeMinutes=12){
  if(!state.currentLocation||!samePlace(state.loc,state.currentLocation))return null;
  const cutoff=Date.now()-maxAgeMinutes*60_000;
  const item=[...state.feedback].reverse().find(x=>x.time>=cutoff&&samePlace(x,state.currentLocation,.0015));
  return item?Boolean(item.raining):null;
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
    current:'temperature_2m,precipitation,rain,showers',
    minutely_15:'precipitation',forecast_minutely_15:'32',
    timeformat:'unixtime',timezone:'GMT'
  });
  const d=await fetchJson('https://api.open-meteo.com/v1/forecast?'+p,8000);
  const h=d.minutely_15||{},times=(h.time||[]).map(iso),prec=(h.precipitation||[]).map(v=>Number(v)||0);
  return {
    current:{time:d.current?.time?iso(d.current.time):null,temperature:Number(d.current?.temperature_2m),precipitation:Number(d.current?.precipitation)||0,rain:Number(d.current?.rain)||0,showers:Number(d.current?.showers)||0},
    time:times,precipitation:prec,events:detectQuarterHourEvents(times,prec),
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
  const [det,ens,qh,radar]=await Promise.all([
    pool(DET_MODELS,fetchDet,3),pool(ENS_MODELS,fetchEns,2),
    Promise.allSettled([fetchQuarterHour()]),Promise.allSettled([fetchRadarMeta()])
  ]);
  const deterministic=det.filter(x=>x.status==='fulfilled').map(x=>x.value);
  const ensembles=ens.filter(x=>x.status==='fulfilled').map(x=>x.value);
  const quarterHour=qh[0]?.status==='fulfilled'?qh[0].value:null;
  const radarMeta=radar[0]?.status==='fulfilled'?radar[0].value:null;
  if(!deterministic.length&&!ensembles.length&&!quarterHour)throw new Error('No responde ninguna fuente de previsión');
  const now=Date.now(),end=now+72*3600_000;
  const consensus=buildConsensus({deterministic,ensembles,nowMs:now}).filter(r=>{
    const t=Date.parse(r.time);return t>=now-3600_000&&t<=end;
  });
  const events=detectRainEvents(consensus);
  const data={
    generatedAt:new Date().toISOString(),
    location:{...state.loc},
    timeline:compactTimeline(consensus,73),
    events,
    nextEvent:chooseNextEvent(events,now),
    quarterHour,
    radar:radarMeta,
    sources:{
      deterministic:sourceStatus(DET_MODELS,det),
      ensembles:sourceStatus(ENS_MODELS,ens),
      quarterHour:Boolean(quarterHour),radar:Boolean(radarMeta)
    }
  };
  const all=[...data.sources.deterministic,...data.sources.ensembles];
  data.sources.health={available:all.filter(x=>x.ok).length+(quarterHour?1:0)+(radarMeta?1:0),total:all.length+2};
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
  const d=ctx.getImageData(0,0,ANALYSIS_SIZE,ANALYSIS_SIZE).data,mask=new Uint8Array(ANALYSIS_SIZE*ANALYSIS_SIZE);
  let wet=0;
  for(let i=0,p=0;i<mask.length;i++,p+=4){
    const a=d[p+3],rgb=d[p]+d[p+1]+d[p+2];
    const v=a>14&&rgb>24?1:0;mask[i]=v;wet+=v;
  }
  const density=wet/mask.length;
  if(density>.90)throw new Error('radar mask opaca');
  return{mask,width:ANALYSIS_SIZE,height:ANALYSIS_SIZE,density};
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
  const center=(ANALYSIS_SIZE-1)/2,current=wetNear(latest.mask,ANALYSIS_SIZE,ANALYSIS_SIZE,center,center,1.5);
  const base={status:'motion_uncertain',confidence:motion?.confidence||0,event:null,rainingNow:current>=.10,currentWetFraction:current,radarTime:new Date(latest.time*1000).toISOString(),decodedFrames:masks.length};
  if(!motion||motion.samples<2||motion.confidence<.22)return base;
  const series=projectPointSeries(latest.mask,ANALYSIS_SIZE,ANALYSIS_SIZE,motion,{horizonMinutes:120,sourceStepMinutes:step,outputStepMinutes:5,radius:0});
  let event=detectNowcastEvent(series,{enterWetFraction:.10,exitWetFraction:.035,minConsecutive:2,stepMinutes:5});
  if(event){
    const t=latest.time*1000;
    event={...event,start:new Date(t+event.startMinute*60_000).toISOString(),end:new Date(t+event.endMinute*60_000).toISOString(),uncertaintyMinutes:nowcastUncertaintyMinutes(motion.confidence,event.startMinute)};
  }
  return{...base,status:'ok',confidence:motion.confidence,event,motion:{...radarGeo(motion,state.loc.lat,step),samples:motion.samples,consistency:motion.consistency},series};
}

function currentRainState(){
  const truth=currentTruth();
  if(truth!==null)return{raining:truth,source:'feedback',label:truth?'Llueve ahora':'No llueve ahora'};
  const radarWet=Number(state.nowcast?.currentWetFraction);
  const radarOk=state.nowcast?.status==='ok'||state.nowcast?.status==='motion_uncertain';
  const radarRain=radarOk&&Number.isFinite(radarWet)&&radarWet>=calibratedRadarThreshold();
  const modelP=Number(state.data?.quarterHour?.current?.precipitation)||0;
  const modelRain=modelP>=.1;
  const raining=radarOk?(radarRain||(modelRain&&radarWet>=.08)):modelRain;
  return{raining,source:radarOk?'radar+modelo':'modelo',label:raining?'Llueve ahora':'No llueve ahora'};
}
function feedbackStats(){
  if(!state.currentLocation)return{count:0,accuracy:null};
  const rows=state.feedback.filter(x=>samePlace(x,state.currentLocation,.0015)).slice(-40);
  if(!rows.length)return{count:0,accuracy:null};
  const evaluable=rows.filter(x=>typeof x.predicted==='boolean');
  const correct=evaluable.filter(x=>x.predicted===Boolean(x.raining)).length;
  return{count:rows.length,accuracy:evaluable.length?correct/evaluable.length:null};
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
    return{kind:truth===true?'observed':'radar',active:true,start:n.radarTime||new Date(now).toISOString(),end:n.event?.end||null,confidence:truth===true?1:n.confidence,uncertainty:n.event?.uncertaintyMinutes||8,event:n.event};
  }
  if(n?.status==='ok'&&n.event&&n.confidence>=.30&&Date.parse(n.event.start)<=now+125*60_000){
    const active=Date.parse(n.event.start)<=now&&truth!==false;
    return{kind:'radar',active,start:n.event.start,end:n.event.end,confidence:n.confidence,uncertainty:n.event.uncertaintyMinutes,event:n.event};
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
    if(ev.active)$('eta').innerHTML='Lluvia <span>ahora</span>';
    else $('eta').innerHTML='<span>'+until(ev.start)+'</span>';
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
      const speed=n?.motion?.speedKmh?Math.round(n.motion.speedKmh)+' km/h':'movimiento estimado';
      if(ev.active){
        $('summary').textContent='Radar: lluvia detectada ahora'+(ev.end?' · fin probable '+fmtTime(ev.end):'')+' · '+speed+'.';
      }else{
        $('summary').textContent='Nowcast radar: llegada '+fmtTime(ev.start)+' · '+uncertaintyText(ev)+' · '+speed+'.';
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
    const stats=feedbackStats(),threshold=Math.round(calibratedRadarThreshold()*100);
    $('feedbackStatus').textContent=stats.count
      ? 'Registradas '+stats.count+' comprobaciones'+(stats.accuracy!=null?' · acierto '+Math.round(stats.accuracy*100)+'%':'')+' · umbral radar local '+threshold+'%.'
      : 'Tu respuesta queda en este dispositivo y sirve para medir aciertos y calibrar la detección local.';
  }
  const h=d.sources.health;
  $('health').textContent=h.available+' de '+h.total+' capas disponibles · radar '+(n?.status==='ok'?'analizado':n?.status==='motion_uncertain'?'sin movimiento fiable':'degradado');
  $('sourceCount').textContent=h.available+'/'+h.total;
  renderTimeline();renderEvents();renderSources();renderRadar();
  const completed=state.lastCompletedAt||d.generatedAt;
  const radarStamp=n?.radarTime||d.radar?.frames?.at(-1)?.time*1000||null;
  $('updated').textContent='Última actualización '+fmtTimeSeconds(completed)+(radarStamp?' · radar '+fmtTime(radarStamp):'');
}
function renderTimeline(){
  const a=state.data.timeline||[],mx=Math.max(50,...a.map(x=>x.probability));
  $('timeline').innerHTML=a.map(x=>{
    const probable=x.probability>=45||x.precipitation>=.10;
    const maybe=!probable&&(x.probability>=35||x.precipitation>=.05);
    const cls=probable?'':maybe?'maybe':'dry';
    const height=probable||maybe?Math.max(5,Math.round(x.probability/mx*100)):0;
    return '<div class="bar '+cls+'" style="height:'+height+'%" title="'+fmtDateTime(x.time)+' · '+x.probability+'% · '+x.precipitation+' mm"></div>';
  }).join('');
  const ticks=[],lines=[];
  for(let i=0;i<a.length;i++){
    const dt=new Date(a[i].time),hour=dt.getHours();
    if(i===0||hour%6===0){
      const left=a.length>1?i/(a.length-1)*100:0;
      const day=new Intl.DateTimeFormat('es-ES',{weekday:'short'}).format(dt).replace('.','');
      ticks.push('<span class="tick" style="left:'+left+'%"><b>'+String(hour).padStart(2,'0')+':00</b>'+day+'</span>');
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
  const events=(state.data.events||[]).filter(e=>Date.parse(e.end)>now).slice(0,6);
  $('events').innerHTML=events.map(e=>{
    const dur=Math.max(1,Math.round((Date.parse(e.end)-Date.parse(e.start))/3600_000));
    return'<div class="event"><div><strong>'+fmtDateTime(e.start)+' → '+fmtTime(e.end)+'</strong><small>'+dur+' h · pico '+Number(e.maxExpectedPrecipitation||0).toFixed(1)+' mm/h · '+(e.independentFamilyCount||e.providerCount)+' familias</small></div><div class="prob">'+pct(e.peakProbability)+'%</div></div>';
  }).join('')||'<div class="status">Sin episodios relevantes.</div>';
}
function renderSources(){
  const list=[
    {label:'Radar RainViewer',ok:Boolean(state.data.radar),detail:state.nowcast?.status==='ok'?'nowcast activo':state.nowcast?.status||'solo mapa'},
    {label:'Guía 15 min',ok:state.data.sources.quarterHour,detail:'modelo/interpolación'},
    ...state.data.sources.deterministic.map(x=>({label:x.label,ok:x.ok,detail:'determinista'})),
    ...state.data.sources.ensembles.map(x=>({label:x.label,ok:x.ok,detail:x.members?x.members+' miembros':'ensemble'}))
  ];
  $('sources').innerHTML=list.map(x=>'<div class="source"><span>'+x.label+'<small>'+x.detail+'</small></span><i class="'+(x.ok?'ok':'bad')+'">'+(x.ok?'OK':'—')+'</i></div>').join('');
}
function initMap(){
  if(state.map||!window.L)return;
  state.map=L.map('map',{zoomControl:false,minZoom:4,maxZoom:12}).setView([state.loc.lat,state.loc.lon],7);
  L.control.zoom({position:'bottomright'}).addTo(state.map);
  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',{maxZoom:19,attribution:'© OpenStreetMap'}).addTo(state.map);
  state.marker=L.circleMarker([state.loc.lat,state.loc.lon],{radius:6,color:'#fff',weight:2,fillColor:'#4fc6ff',fillOpacity:1}).addTo(state.map);
}
function renderRadar(){
  initMap();if(!state.map)return;
  state.map.setView([state.loc.lat,state.loc.lon],state.map.getZoom());
  state.marker.setLatLng([state.loc.lat,state.loc.lon]);
  const r=state.data.radar;if(!r?.frames?.length){$('radarTime').textContent='sin radar';return}
  state.frames=r.frames.slice(-10);state.frameIndex=Math.min(state.frameIndex||state.frames.length-1,state.frames.length-1);
  $('frame').max=state.frames.length-1;$('frame').value=state.frameIndex;showRadarFrame();
}
function showRadarFrame(){
  const f=state.frames[state.frameIndex],r=state.data.radar;if(!f||!r)return;
  if(state.radarLayer)state.map.removeLayer(state.radarLayer);
  state.radarLayer=L.tileLayer(r.host+f.path+'/256/{z}/{x}/{y}/2/1_1.png',{tileSize:256,opacity:.76,maxNativeZoom:7,maxZoom:12,attribution:'Weather data by RainViewer'}).addTo(state.map);
  $('frame').value=state.frameIndex;$('radarTime').textContent=fmtTime(f.time*1000);
}
async function refreshRadar(){
  if(state.radarLoading||!state.data)return;
  state.radarLoading=true;
  try{
    const radar=await fetchRadarMeta();
    const sources={...state.data.sources,radar:true};
    const all=[...(sources.deterministic||[]),...(sources.ensembles||[])];
    sources.health={available:all.filter(x=>x.ok).length+(sources.quarterHour?1:0)+1,total:all.length+2};
    state.data={...state.data,radar,sources};
    state.nowcast=await computeNowcast(radar).catch(e=>({status:'radar_analysis_failed',confidence:0,event:null,error:String(e?.message||e)}));
    state.lastRadarRefresh=Date.now();
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
    state.lastRadarRefresh=Date.now();
    render();
  }catch(e){
    $('eta').textContent='Sin datos';$('summary').textContent=String(e?.message||e);
  }finally{state.loading=false}
}
function setLocation(loc){
  state.loc={name:loc.name||'Ubicación',lat:Number(loc.lat),lon:Number(loc.lon)};
  localStorage.setItem('raineta.loc',JSON.stringify(state.loc));state.frameIndex=0;
  $('dlg').close();load(true);
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
      b.onclick=()=>setLocation({name:x.name,lat:x.latitude,lon:x.longitude});
      $('results').appendChild(b);
    }
    if(!$('results').children.length)$('results').textContent='Sin resultados';
  }catch{$('results').textContent='No se pudo buscar'}
}

$('place').onclick=()=>$('dlg').showModal();
$('close').onclick=()=>$('dlg').close();
$('refresh').onclick=()=>load(true);
$('search').onclick=searchPlace;
$('q').onkeydown=e=>{if(e.key==='Enter')searchPlace()};
$('geo').onclick=()=>{
  if(!navigator.geolocation){$('results').textContent='Geolocalización no disponible';return}
  $('results').textContent='Obteniendo ubicación…';
  navigator.geolocation.getCurrentPosition(
    p=>setLocation({name:'Mi ubicación',lat:Number(p.coords.latitude.toFixed(5)),lon:Number(p.coords.longitude.toFixed(5))}),
    e=>$('results').textContent=e.message,
    {enableHighAccuracy:true,timeout:15000,maximumAge:60000}
  );
};
$('frame').oninput=function(){state.frameIndex=Number(this.value);showRadarFrame()};
$('play').onclick=function(){
  if(state.playTimer){clearInterval(state.playTimer);state.playTimer=null;this.textContent='▶';return}
  if(!state.frames.length)return;this.textContent='❚❚';
  state.playTimer=setInterval(()=>{state.frameIndex=(state.frameIndex+1)%state.frames.length;showRadarFrame()},1200);
};
if('serviceWorker'in navigator)navigator.serviceWorker.register('/rain/sw.js').catch(()=>{});
document.addEventListener('visibilitychange',()=>{
  if(document.visibilityState==='visible'&&Date.now()-state.lastRadarRefresh>RADAR_REFRESH_MS)refreshRadar();
});
setInterval(()=>{if(document.visibilityState==='visible')refreshRadar()},RADAR_REFRESH_MS);
load();
