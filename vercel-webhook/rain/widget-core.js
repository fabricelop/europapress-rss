// Small, dependency-free RainETA contract shared by the API and tests.
// All times are absolute UTC timestamps. Never imply minute accuracy from hourly interpolation.
const toMs = value => typeof value === 'number' ? (value < 1e11 ? value * 1000 : value) : Date.parse(value);
const valid = n => Number.isFinite(Number(n));
const iso = n => Number.isFinite(n) ? new Date(n).toISOString() : null;
const wet = n => valid(n) && Number(n) >= 0.08; // mm accumulated per 15 minutes
const limit = (n,lo,hi) => Math.max(lo,Math.min(hi,n));

export function modelTransition(forecast, nowMs=Date.now()) {
  const data=forecast?.minutely_15||{};
  const times=Array.isArray(data.time)?data.time:[];
  const amounts=Array.isArray(data.precipitation)?data.precipitation:[];
  const rows=times.map((t,i)=>({at:toMs(t),mm:Number(amounts[i])}))
    .filter(r=>Number.isFinite(r.at)&&Number.isFinite(r.mm)&&r.at>=nowMs-15*60000&&r.at<=nowMs+4*3600000)
    .sort((a,b)=>a.at-b.at);
  const current=forecast?.current||{};
  const currentWet=wet(current.precipitation) || wet(current.rain) || wet(current.showers);
  if(!rows.length)return{available:false,currentlyWet:currentWet,onset:null,end:null,horizon:0};
  // Current observation overrides an interpolated first model cell when present.
  const currentlyWet=valid(current.precipitation)?currentWet:rows[0].mm>=0.08;
  // Ignore isolated single wet pixels/steps; do not imply continuous rain from a one-step spike.
  const states=rows.map(r=>wet(r.mm));
  let onset=null,end=null;
  if(currentlyWet){
    const firstDry=rows.findIndex((r,i)=>r.at>nowMs && !states[i] && !states[i+1]);
    if(firstDry>=0)end=rows[firstDry].at;
  }else{
    for(let i=0;i<rows.length-1;i++){
      if(rows[i].at<=nowMs)continue;
      if(states[i]&&states[i+1]){onset=rows[i].at;break}
    }
  }
  return{available:true,currentlyWet,onset,end,horizon:Math.round((rows.at(-1).at-nowMs)/60000)};
}

export function radarTransition(radar,nowMs=Date.now()) {
  const age=Number(radar?.ageMinutes),nc=radar?.nowcast,confidence=Number(nc?.confidence);
  if(!radar?.ok||!Number.isFinite(age)||age<0||age>20||!nc||nc.status!=='ok'||!Number.isFinite(confidence)||confidence<0.38)
    return{available:false,currentlyWet:false,onset:null,end:null};
  const event=nc.event||{};
  const start=toMs(event.start),end=toMs(event.end);
  const nowWet=Number(radar.sample?.rateMmH)>=0.2 && Number(radar.sample?.wetFraction)>=0.10;
  const horizon=limit(Number(nc.reliableHorizonMinutes)||30,10,45);
  const within=t=>Number.isFinite(t)&&t>nowMs&&t<=nowMs+horizon*60000;
  return{
    available:true,
    currentlyWet:nowWet,
    onset:within(start)?start:null,
    end:within(end)?end:null,
    confidence:limit(confidence,0,1),
    observedAt:radar.observedAt||null,
    horizon,
  };
}

export function buildRainWidget(forecast,radar,{nowMs=Date.now(),lat,lon}={}) {
  const model=modelTransition(forecast,nowMs),r=radarTransition(radar,nowMs);
  const inIberia=lat>=35&&lat<=44.5&&lon>=-10&&lon<=4.5;
  const currentlyWet=r.available?r.currentlyWet:model.currentlyWet;
  let target=currentlyWet?(r.available&&r.currentlyWet?r.end:null)||(model.currentlyWet?model.end:null)
    :(r.available?r.onset:null)||model.onset;
  if(target!=null&&target<=nowMs)target=null;
  const fromRadar=target!=null&&r.available&&(currentlyWet?r.currentlyWet&&r.end===target:r.onset===target);
  // A dry radar cannot confidently rule out a later model shower.
  const confidence=fromRadar?(r.confidence>=0.7?'media':'baja'):'baja';
  const phase=currentlyWet?'raining':'dry';
  const action=target==null?'none':currentlyWet?'stops':'starts';
  const precise=fromRadar?5:inIberia?30:15;
  return{
    ok:model.available||r.available,
    generatedAt:iso(nowMs),
    location:{lat,lon},
    phase,action,targetAt:iso(target),
    precisionMinutes:target==null?null:precise,
    confidence:target==null?null:confidence,
    summary:target==null?(currentlyWet?'Llueve; fin aún indeterminado':
       model.available?'Sin inicio confirmado en las próximas 4 h':'Datos insuficientes')
      :currentlyWet?'Dejará de llover aproximadamente':'Empezará a llover aproximadamente',
    sources:[...(r.available?['AEMET radar nowcast']:[]),...(model.available?['Open-Meteo / modelos']:[])],
    radarObservedAt:r.observedAt||null,
    caveat:fromRadar?'Estimación radar, no observación futura':
      inIberia?'Modelo de 15 min interpolado de datos horarios en Iberia':'Predicción modelizada, no observación',
    validityMinutes:10,
    horizonMinutes:model.horizon||r.horizon||0
  };
}
