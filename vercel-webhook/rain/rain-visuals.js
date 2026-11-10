// RainETA visualization primitives: presentation only, never forecast authority.
// All wet/possible/dry classifications use the canonical signal when supplied.
const finite=(value,fallback=0)=>Number.isFinite(Number(value))?Number(value):fallback;
const clamp=(value,min,max)=>Math.min(max,Math.max(min,value));

export function rainVisualSignal(point={}){
  if(['wet','possible','dry'].includes(point.canonicalSignal))return point.canonicalSignal;
  if(typeof point.wet==='boolean'&&point.wet)return 'wet';
  const rate=Math.max(0,finite(point.rate??point.precipitation));
  const raw=finite(point.probability);
  const probability=clamp(raw>1?raw/100:raw,0,1);
  // A non-wet minute is never painted as actual rain just because the
  // extrapolation has a non-zero precipitation rate.
  if(typeof point.wet==='boolean'){
    return rate>=.03&&probability>=.20?'possible':'dry';
  }
  if(rate>=.05&&probability>=.40)return 'wet';
  if(rate>=.03&&probability>=.20)return 'possible';
  return 'dry';
}

const pointTime=point=>{
  if(point?.time instanceof Date)return point.time.getTime();
  if(typeof point?.time==='number')return point.time;
  return Date.parse(point?.time||'');
};

export function rainVisualWindows(points=[],stepMinutes=5){
  if(!Array.isArray(points)||!points.length)return [];
  const defaultStep=Math.max(1,finite(stepMinutes,5))*60_000;
  const windows=[];
  for(let i=0;i<points.length;i++){
    const p=points[i],start=pointTime(p);
    if(!Number.isFinite(start))continue;
    const next=points[i+1]?pointTime(points[i+1]):NaN;
    const step=Number.isFinite(next)&&next>start?Math.min(next-start,3*60*60_000):defaultStep;
    const signal=rainVisualSignal(p);
    const rate=Math.max(0,finite(p.rate??p.precipitation));
    const last=windows[windows.length-1];
    if(last&&last.signal===signal&&start<=last.end+1000){
      last.end=Math.max(last.end,start+step);
      last.peakRate=Math.max(last.peakRate,rate);
      last.count++;
    }else{
      windows.push({signal,start,end:start+step,peakRate:rate,count:1});
    }
  }
  return windows;
}

export function rainWaveSvg(points=[],{id='rain-wave'}={}){
  if(!Array.isArray(points)||!points.length)return '';
  const width=960,base=124,top=12,n=points.length;
  const prefix=String(id).replace(/[^a-zA-Z0-9_-]/g,'')||'rain-wave';
  const rates=points.map(p=>rainVisualSignal(p)==='wet'?Math.max(0,finite(p.rate??p.precipitation)):0);
  const maxRate=Math.max(2,Math.min(20,...rates));
  const x=i=>Number((i/(Math.max(1,n-1))*width).toFixed(2));
  const y=i=>Number((base-Math.sqrt(Math.min(rates[i],maxRate)/maxRate)*(base-top)).toFixed(2));
  const coords=points.map((p,i)=>x(i)+' '+y(i));
  const line='M '+coords.map((p,i)=>(i?'L ':'')+p).join(' ');
  const area=line+' L '+width+' '+base+' L 0 '+base+' Z';
  const maybe=points.map((p,i)=>{
    if(rainVisualSignal(p)!=='possible')return '';
    const w=width/n,px=Math.max(0,i/n*width);
    return '<rect x="'+px.toFixed(2)+'" y="'+(base-9)+'" width="'+w.toFixed(2)+'" height="9" rx="2" fill="#cfb3ff" opacity=".55"/>';
  }).join('');
  const peaks=rates.map((v,i)=>({v,i})).filter(a=>a.v>0).sort((a,b)=>b.v-a.v);
  const peak=peaks[0];
  const dot=peak?'<circle cx="'+x(peak.i)+'" cy="'+y(peak.i)+'" r="4.5" fill="#e8fbff" stroke="#168bb9" stroke-width="2"/>':'';
  return '<svg class="rainWaveSvg" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 '+width+' 142" preserveAspectRatio="none" aria-hidden="true">'+
    '<defs><linearGradient id="'+prefix+'-fill" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#57caff" stop-opacity=".62"/><stop offset=".82" stop-color="#0c9eda" stop-opacity=".23"/><stop offset="1" stop-color="#0c9eda" stop-opacity=".06"/></linearGradient></defs>'+
    '<path d="M0 68 H960" stroke="#ffffff" stroke-opacity=".055" stroke-dasharray="4 8"/>'+
    '<path d="M0 '+base+' H960" stroke="#8fc9b6" stroke-opacity=".40"/>'+
    '<path d="'+area+'" fill="url(#'+prefix+'-fill)"/>'+
    '<path d="'+line+'" fill="none" stroke="#67dbff" stroke-width="3.5" stroke-linejoin="round" stroke-linecap="round" vector-effect="non-scaling-stroke"/>'+
    maybe+dot+'</svg>';
}
