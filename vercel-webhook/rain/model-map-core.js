function clamp01(v){return Math.max(0,Math.min(1,Number(v)||0))}
export function selectSpatialForecastTimeIndex(validTimes=[],targetMs=Date.now()){
  const rows=(validTimes||[]).map((value,index)=>({index,time:Date.parse(value)})).filter(row=>Number.isFinite(row.time));
  if(!rows.length)return-1;
  const target=Number(targetMs);
  if(!Number.isFinite(target))return rows[0].index;
  const after=rows.find(row=>row.time>=target);
  return(after||rows.at(-1)).index;
}
export function selectSpatialForecastTimeBlend(validTimes=[],targetMs=Date.now()){
  const rows=(validTimes||[]).map((value,index)=>({index,time:Date.parse(value)})).filter(row=>Number.isFinite(row.time));
  if(!rows.length)return{fromIndex:-1,toIndex:-1,fraction:0,fromTime:null,toTime:null};
  const target=Number(targetMs);
  if(!Number.isFinite(target)||target<=rows[0].time){
    const row=rows[0];return{fromIndex:row.index,toIndex:row.index,fraction:0,fromTime:row.time,toTime:row.time};
  }
  for(let i=1;i<rows.length;i++){
    if(target<=rows[i].time){
      const a=rows[i-1],b=rows[i],span=Math.max(1,b.time-a.time);
      return{fromIndex:a.index,toIndex:b.index,fraction:clamp01((target-a.time)/span),fromTime:a.time,toTime:b.time};
    }
  }
  const row=rows.at(-1);
  return{fromIndex:row.index,toIndex:row.index,fraction:0,fromTime:row.time,toTime:row.time};
}
export function hybridFutureBlend(minutes=0){
  const m=Math.max(0,Number(minutes)||0);
  if(m<=12)return{radarOpacity:.76,modelOpacity:0,mode:'radar'};
  if(m<=20){
    const t=clamp01((m-12)/8);
    return{radarOpacity:.76-.18*t,modelOpacity:.18*t,mode:t<.3?'radar':'hybrid'};
  }
  if(m<=28){
    const t=clamp01((m-20)/8);
    return{radarOpacity:.58*(1-t),modelOpacity:.18+.60*t,mode:t>=.98?'model':'hybrid'};
  }
  return{radarOpacity:0,modelOpacity:.78,mode:'model'};
}
export function futureVisualLabel(minutes=0){
  const blend=hybridFutureBlend(minutes);
  if(blend.mode==='radar')return'NOWCAST RADAR';
  if(blend.mode==='hybrid')return'RADAR + MODELO';
  return'PREVISIÓN MODELO';
}
