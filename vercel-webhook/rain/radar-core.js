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
export function projectPointSeries(mask,w,h,motion,{horizonMinutes=120,sourceStepMinutes=10,outputStepMinutes=5,radius=1}={}){
  if(!motion||!mask?.length)return[];
  const cx=(w-1)/2,cy=(h-1)/2,steps=Math.floor(horizonMinutes/outputStepMinutes),rows=[];
  for(let i=0;i<=steps;i++){
    const minute=i*outputStepMinutes,f=minute/sourceStepMinutes,x=cx-motion.dx*f,y=cy-motion.dy*f;
    const wetFraction=wetNear(mask,w,h,x,y,radius),penalty=1-.52*(minute/Math.max(1,horizonMinutes));
    rows.push({minute,wetFraction,probability:clamp01(wetFraction*motion.confidence*Math.max(.35,penalty)),sampleX:x,sampleY:y});
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
