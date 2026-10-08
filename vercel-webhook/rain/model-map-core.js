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
export function hybridFutureBlend(minutes=0,handoffMinutes=20){
  const m=Math.max(0,Number(minutes)||0),handoff=Math.max(1,Number(handoffMinutes)||20);
  if(m<=handoff)return{radarOpacity:.76,modelOpacity:0,mode:'radar',handoffMinutes:handoff};
  return{radarOpacity:0,modelOpacity:.78,mode:'model',handoffMinutes:handoff};
}
export function futureVisualLabel(minutes=0,handoffMinutes=20){
  return hybridFutureBlend(minutes,handoffMinutes).mode==='radar'?'NOWCAST RADAR':'PREVISIÓN MODELO';
}
