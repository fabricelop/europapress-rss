function clamp01(v){return Math.max(0,Math.min(1,Number(v)||0))}
export function selectSpatialForecastTimeIndex(validTimes=[],targetMs=Date.now()){
  const rows=(validTimes||[]).map((value,index)=>({index,time:Date.parse(value)})).filter(row=>Number.isFinite(row.time));
  if(!rows.length)return-1;
  const target=Number(targetMs);
  if(!Number.isFinite(target))return rows[0].index;
  const after=rows.find(row=>row.time>=target);
  return(after||rows.at(-1)).index;
}
export function hybridFutureBlend(minutes=0){
  const m=Math.max(0,Number(minutes)||0);
  if(m<=5)return{radarOpacity:.76,modelOpacity:0,mode:'radar'};
  if(m<=15){
    const t=clamp01((m-5)/10);
    return{radarOpacity:.76-.08*t,modelOpacity:.15*t,mode:t<.5?'radar':'hybrid'};
  }
  if(m<=30){
    const t=clamp01((m-15)/15);
    return{radarOpacity:.68-.18*t,modelOpacity:.15+.27*t,mode:'hybrid'};
  }
  if(m<=45){
    const t=clamp01((m-30)/15);
    return{radarOpacity:.50-.25*t,modelOpacity:.42+.26*t,mode:'hybrid'};
  }
  if(m<=60){
    const t=clamp01((m-45)/15);
    return{radarOpacity:.25*(1-t),modelOpacity:.68+.10*t,mode:t<.7?'hybrid':'model'};
  }
  return{radarOpacity:0,modelOpacity:.78,mode:'model'};
}
export function futureVisualLabel(minutes=0){
  const blend=hybridFutureBlend(minutes);
  if(blend.mode==='radar')return'NOWCAST RADAR';
  if(blend.mode==='hybrid')return'RADAR + MODELO';
  return'PREVISIÓN MODELO';
}
