export function wmsCapabilitiesHasLayer(xml,layerName){
  const text=String(xml||''),full=String(layerName||'').trim(),local=full.includes(':')?full.split(':').pop():full;
  if(!local)return false;
  return text.includes('<Name>'+full+'</Name>')||text.includes('<Name>'+local+'</Name>');
}
export function buildRadarProjectionRgba(mask,rateGrid,width,height,colorForRate){
  const w=Math.max(1,Math.floor(Number(width)||0)),h=Math.max(1,Math.floor(Number(height)||0)),size=w*h;
  if(!mask?.length||!rateGrid?.length||mask.length!==size||rateGrid.length!==size)throw new Error('invalid projection field');
  const rgba=new Uint8ClampedArray(size*4);
  let wetPixels=0,alphaPixels=0;
  const color=typeof colorForRate==='function'?colorForRate:(()=>[0,163,224,220]);
  for(let i=0,p=0;i<size;i++,p+=4){
    if(!mask[i])continue;
    const rate=Number(rateGrid[i]);
    if(!(rate>0))continue;
    const c=color(rate)||[0,0,0,0],alpha=Math.max(0,Math.min(255,Number(c[3])||0));
    if(alpha<=0)continue;
    rgba[p]=Math.max(0,Math.min(255,Number(c[0])||0));
    rgba[p+1]=Math.max(0,Math.min(255,Number(c[1])||0));
    rgba[p+2]=Math.max(0,Math.min(255,Number(c[2])||0));
    rgba[p+3]=alpha;
    wetPixels++;alphaPixels++;
  }
  return{rgba,wetPixels,alphaPixels,opaqueFraction:alphaPixels/size,width:w,height:h};
}
export function radarProjectionRenderMode({minutes=0,fieldAvailable=false,guidanceOk=false,horizon=0,continuityMinutes=3}={}){
  const m=Math.max(0,Number(minutes)||0),limit=Math.max(0,Number(continuityMinutes)||0),h=Math.max(0,Number(horizon)||0);
  if(!fieldAvailable||m<=0)return'none';
  if(guidanceOk&&m<=h)return'flow';
  if(m<=limit)return'persistence';
  return'none';
}
export function evaluateOverlaySourceState({enabled=false,context=true,verified=false,loaded=0,errors=0}={}){
  if(!enabled)return'disabled';
  if(!context)return'hidden';
  if(!verified)return errors>0?'error':'unverified';
  if(errors>0&&loaded<=0)return'error';
  if(loaded>0)return'active';
  return'loading';
}

export function clamp01(v){return Math.max(0,Math.min(1,Number.isFinite(v)?v:0))}
export function maskDensity(mask){if(!mask?.length)return 0;let n=0;for(const v of mask)n+=v?1:0;return n/mask.length}
function overlap(prev,cur,w,h,dx,dy,pwet,cwet){
  let inter=0,union=0;
  for(let y=0;y<h;y++){const py=y-dy;if(py<0||py>=h)continue;
    for(let x=0;x<w;x++){const px=x-dx;if(px<0||px>=w)continue;const a=prev[py*w+px]?1:0,b=cur[y*w+x]?1:0;if(a||b){union++;if(a&&b)inter++}}}
  if(union<6)return{score:-Infinity,intersection:inter,union};
  const iou=inter/union,coverage=inter/Math.max(1,Math.min(pwet,cwet));
  return{score:.72*iou+.28*coverage,intersection:inter,union};
}
export function estimateTranslation(prev,cur,w,h,{maxShift=8}={}){
  if(!prev||!cur||prev.length!==cur.length||prev.length!==w*h)return null;
  const pd=maskDensity(prev),cd=maskDensity(cur);if(pd<.0008||cd<.0008||pd>.88||cd>.88)return null;
  const pwet=Math.round(pd*prev.length),cwet=Math.round(cd*cur.length);
  let best={dx:0,dy:0,score:-Infinity},second=-Infinity;
  for(let dy=-maxShift;dy<=maxShift;dy++)for(let dx=-maxShift;dx<=maxShift;dx++){
    const r=overlap(prev,cur,w,h,dx,dy,pwet,cwet);
    if(r.score>best.score){second=best.score;best={dx,dy,...r}}else if(r.score>second)second=r.score;
  }
  if(!Number.isFinite(best.score))return null;
  const unique=clamp01((best.score-Math.max(0,second))/.08);
  const stable=clamp01(1-Math.abs(pd-cd)/Math.max(.01,pd,cd));
  return{...best,confidence:clamp01(.6*best.score+.22*unique+.18*stable),prevDensity:pd,curDensity:cd};
}
function patchOverlap(prev,cur,w,h,cx,cy,dx,dy,radius){
  let inter=0,union=0,pwet=0,cwet=0;
  const x0=Math.max(0,Math.floor(cx-radius)),x1=Math.min(w-1,Math.ceil(cx+radius));
  const y0=Math.max(0,Math.floor(cy-radius)),y1=Math.min(h-1,Math.ceil(cy+radius));
  for(let y=y0;y<=y1;y++){
    const py=y-dy;if(py<0||py>=h)continue;
    for(let x=x0;x<=x1;x++){
      const px=x-dx;if(px<0||px>=w)continue;
      const a=prev[py*w+px]?1:0,b=cur[y*w+x]?1:0;
      pwet+=a;cwet+=b;
      if(a||b){union++;if(a&&b)inter++}
    }
  }
  if(union<4||Math.max(pwet,cwet)<3)return{score:-Infinity,intersection:inter,union,pwet,cwet};
  const iou=inter/union,coverage=inter/Math.max(1,Math.min(pwet,cwet));
  return{score:.72*iou+.28*coverage,intersection:inter,union,pwet,cwet};
}
function gridCenters(size,margin,count){
  if(count<=1)return[(size-1)/2];
  const span=Math.max(0,size-1-margin*2);
  return Array.from({length:count},(_,i)=>margin+span*i/(count-1));
}
export function estimateLocalFlow(prev,cur,w,h,{maxShift=7,grid=5,patchRadius=8}={}){
  if(!prev||!cur||prev.length!==cur.length||prev.length!==w*h)return null;
  const margin=Math.min(Math.floor(Math.min(w,h)/3),patchRadius+maxShift+1);
  const xs=gridCenters(w,margin,grid),ys=gridCenters(h,margin,grid),vectors=[];
  for(const y of ys)for(const x of xs){
    let best={score:-Infinity,dx:0,dy:0},second=-Infinity;
    for(let dy=-maxShift;dy<=maxShift;dy++)for(let dx=-maxShift;dx<=maxShift;dx++){
      const r=patchOverlap(prev,cur,w,h,x,y,dx,dy,patchRadius);
      if(r.score>best.score){second=best.score;best={...r,dx,dy}}
      else if(r.score>second)second=r.score;
    }
    if(!Number.isFinite(best.score))continue;
    const unique=clamp01((best.score-Math.max(0,second))/.10);
    const densityStable=clamp01(1-Math.abs(best.pwet-best.cwet)/Math.max(3,best.pwet,best.cwet));
    const confidence=clamp01(.62*best.score+.20*unique+.18*densityStable);
    if(confidence<.18)continue;
    vectors.push({x,y,dx:best.dx,dy:best.dy,confidence,score:best.score});
  }
  if(!vectors.length)return null;
  const confidence=vectors.reduce((s,v)=>s+v.confidence,0)/vectors.length;
  const coverage=vectors.length/Math.max(1,xs.length*ys.length);
  return{vectors,confidence:clamp01(confidence*(.72+.28*coverage)),coverage,gridX:xs.length,gridY:ys.length};
}
export function combineLocalFlows(flows=[]){
  const valid=flows.filter(f=>f?.vectors?.length);
  if(!valid.length)return null;
  const keyFor=v=>Number(v?.x).toFixed(4)+','+Number(v?.y).toFixed(4);
  const maps=valid.map(flow=>new Map(flow.vectors.map(v=>[keyFor(v),v])));
  const keys=[...new Set(valid.flatMap(flow=>flow.vectors.map(keyFor)))];
  const vectors=[];
  for(const key of keys){
    const samples=maps.map(map=>map.get(key)).filter(Boolean);
    if(!samples.length)continue;
    const dx=wmedian(samples.map(v=>({value:v.dx,weight:Math.max(.05,v.confidence||0)})));
    const dy=wmedian(samples.map(v=>({value:v.dy,weight:Math.max(.05,v.confidence||0)})));
    const spread=median(samples.map(v=>Math.hypot(v.dx-dx,v.dy-dy)))||0;
    const consistency=clamp01(1-spread/3);
    const mean=samples.reduce((sum,v)=>sum+(v.confidence||0),0)/samples.length;
    const persistence=samples.length/valid.length;
    const ref=samples.at(-1);
    vectors.push({
      x:ref.x,y:ref.y,dx,dy,
      confidence:clamp01((.64*mean+.26*consistency+.10*persistence)*(.82+.18*persistence)),
      consistency,persistence,samples:samples.length
    });
  }
  if(!vectors.length)return null;
  vectors.sort((a,b)=>a.y-b.y||a.x-b.x);
  const confidence=vectors.reduce((sum,v)=>sum+v.confidence,0)/vectors.length;
  const coverage=valid.reduce((sum,f)=>sum+(Number(f.coverage)||0),0)/valid.length;
  return{vectors,confidence:clamp01(confidence),coverage,historySamples:valid.length};
}
export function flowVectorAt(flow,x,y,fallback={dx:0,dy:0,confidence:0}){
  const vectors=flow?.vectors||[];
  if(!vectors.length)return fallback;
  const near=vectors.map(v=>({...v,d2:(v.x-x)**2+(v.y-y)**2})).sort((a,b)=>a.d2-b.d2).slice(0,6);
  let sw=0,dx=0,dy=0,conf=0;
  for(const v of near){
    const weight=Math.max(.02,v.confidence)/(v.d2+25);
    sw+=weight;dx+=v.dx*weight;dy+=v.dy*weight;conf+=v.confidence*weight;
  }
  if(sw<=0)return fallback;
  return{dx:dx/sw,dy:dy/sw,confidence:clamp01(conf/sw)};
}
export function evolutionReliability(prev,cur,w,h,motion){
  if(!prev||!cur||!motion)return{score:0,overlap:0,densityStable:0};
  const pd=maskDensity(prev),cd=maskDensity(cur);
  const pwet=Math.round(pd*prev.length),cwet=Math.round(cd*cur.length);
  const r=overlap(prev,cur,w,h,Math.round(motion.dx),Math.round(motion.dy),pwet,cwet);
  const densityStable=clamp01(1-Math.abs(pd-cd)/Math.max(.01,pd,cd));
  const overlapScore=Number.isFinite(r.score)?clamp01(r.score):0;
  const score=clamp01(.5*overlapScore+.25*densityStable+.25*clamp01(motion.consistency??motion.confidence??0));
  return{score,overlap:overlapScore,densityStable,densityChange:cd-pd};
}
export function projectPointSeriesFlow(mask,w,h,flow,motion,{horizonMinutes=120,sourceStepMinutes=10,outputStepMinutes=5,radius=1,intensityGrid=null,reliability=1}={}){
  if(!motion||!mask?.length)return[];
  const cx=(w-1)/2,cy=(h-1)/2,steps=Math.floor(horizonMinutes/outputStepMinutes),rows=[];
  const baseReliability=clamp01((motion.confidence||0)*.58+(flow?.confidence||0)*.42)*clamp01(reliability);
  for(let i=0;i<=steps;i++){
    const minute=i*outputStepMinutes;
    let x=cx,y=cy,remaining=minute;
    while(remaining>0){
      const dt=Math.min(outputStepMinutes,remaining),vec=flowVectorAt(flow,x,y,motion),f=dt/Math.max(1,sourceStepMinutes);
      x-=vec.dx*f;y-=vec.dy*f;remaining-=dt;
    }
    const wetFraction=wetNear(mask,w,h,x,y,radius);
    const radarRate=valueNear(intensityGrid,w,h,x,y,radius);
    const horizonPenalty=Math.max(.08,1-.86*(minute/Math.max(1,horizonMinutes)));
    const flowPenalty=Math.max(.55,.82+.18*(flow?.coverage||0));
    rows.push({
      minute,wetFraction,
      probability:clamp01(wetFraction*baseReliability*horizonPenalty*flowPenalty),
      radarRate,sampleX:x,sampleY:y
    });
  }
  return rows;
}
function median(a){const x=a.filter(Number.isFinite).sort((p,q)=>p-q);if(!x.length)return null;const m=Math.floor(x.length/2);return x.length%2?x[m]:(x[m-1]+x[m])/2}
function wmedian(entries){const x=entries.filter(e=>Number.isFinite(e.value)&&Number.isFinite(e.weight)&&e.weight>0).sort((a,b)=>a.value-b.value);if(!x.length)return null;const total=x.reduce((s,e)=>s+e.weight,0);let c=0;for(const e of x){c+=e.weight;if(c>=total/2)return e.value}return x.at(-1).value}
export function combineMotionEstimates(est=[]){
  const v=est.filter(e=>e&&Number.isFinite(e.dx)&&Number.isFinite(e.dy));if(!v.length)return null;
  const dx=wmedian(v.map(e=>({value:e.dx,weight:Math.max(.05,e.confidence||0)})));
  const dy=wmedian(v.map(e=>({value:e.dy,weight:Math.max(.05,e.confidence||0)})));
  const dist=v.map(e=>Math.hypot(e.dx-dx,e.dy-dy)),consistency=clamp01(1-(median(dist)||0)/4);
  const mean=v.reduce((s,e)=>s+(e.confidence||0),0)/v.length;
  return{dx,dy,confidence:clamp01(.65*mean+.35*consistency),consistency,samples:v.length};
}
export function wetNear(mask,w,h,x,y,r=1){
  let wet=0,total=0;
  for(let yy=Math.max(0,Math.floor(y-r));yy<=Math.min(h-1,Math.ceil(y+r));yy++)for(let xx=Math.max(0,Math.floor(x-r));xx<=Math.min(w-1,Math.ceil(x+r));xx++){total++;wet+=mask[yy*w+xx]?1:0}
  return total?wet/total:0;
}
export function valueNear(grid,w,h,x,y,r=1){
  if(!grid?.length)return 0;
  const values=[];
  for(let yy=Math.max(0,Math.floor(y-r));yy<=Math.min(h-1,Math.ceil(y+r));yy++)for(let xx=Math.max(0,Math.floor(x-r));xx<=Math.min(w-1,Math.ceil(x+r));xx++){
    const value=Number(grid[yy*w+xx]);
    if(Number.isFinite(value)&&value>0)values.push(value);
  }
  if(!values.length)return 0;
  values.sort((a,b)=>a-b);
  return values[Math.floor(values.length/2)];
}
export function projectPointSeries(mask,w,h,motion,{horizonMinutes=120,sourceStepMinutes=10,outputStepMinutes=5,radius=1,intensityGrid=null}={}){
  if(!motion||!mask?.length)return[];
  const cx=(w-1)/2,cy=(h-1)/2,steps=Math.floor(horizonMinutes/outputStepMinutes),rows=[];
  for(let i=0;i<=steps;i++){
    const minute=i*outputStepMinutes,f=minute/sourceStepMinutes,x=cx-motion.dx*f,y=cy-motion.dy*f;
    const wetFraction=wetNear(mask,w,h,x,y,radius),penalty=1-.52*(minute/Math.max(1,horizonMinutes));
    const radarRate=valueNear(intensityGrid,w,h,x,y,radius);
    rows.push({minute,wetFraction,probability:clamp01(wetFraction*motion.confidence*Math.max(.35,penalty)),radarRate,sampleX:x,sampleY:y});
  }
  return rows;
}
export function detectNowcastEvent(series=[],{enterWetFraction=.10,exitWetFraction=.035,minConsecutive=2,stepMinutes=5}={}){
  let start=-1,run=0;
  for(let i=0;i<series.length;i++){run=(series[i].wetFraction||0)>=enterWetFraction?run+1:0;if(run>=minConsecutive){start=i-minConsecutive+1;break}}
  if(start<0)return null;
  let end=series.length-1;run=0;
  for(let i=start+minConsecutive;i<series.length;i++){run=(series[i].wetFraction||0)<=exitWetFraction?run+1:0;if(run>=minConsecutive){end=i-minConsecutive+1;break}}
  const seg=series.slice(start,Math.max(start+1,end+1)),peak=seg.reduce((a,b)=>b.wetFraction>a.wetFraction?b:a,seg[0]);
  return{startMinute:series[start].minute,endMinute:series[end]?.minute??series[start].minute+stepMinutes,peakMinute:peak.minute,peakWetFraction:peak.wetFraction,peakProbability:peak.probability};
}
export function nowcastUncertaintyMinutes(conf,startMinute){return Math.round(Math.min(32,3+(1-clamp01(conf))*14+Math.max(0,Number(startMinute)||0)*.12))}
