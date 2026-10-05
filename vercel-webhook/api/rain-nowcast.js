import sharp from 'sharp';
import {makeMaskFromAlpha,estimateTranslation,combineMotionEstimates,projectPointSeries,detectNowcastEvent,nowcastUncertaintyMinutes,wetNear} from '../lib/radar-nowcast-core.js';

const META='https://api.rainviewer.com/public/weather-maps.json';
const SIZE=512,ZOOM=7,STRIDE=4,ALPHA=128,FRAMES=5;

function reply(res,status,body,cache='public, s-maxage=180, stale-while-revalidate=300'){
  res.statusCode=status;res.setHeader('Content-Type','application/json; charset=utf-8');res.setHeader('Cache-Control',cache);res.end(JSON.stringify(body));
}
function num(v){const n=Number(v);return Number.isFinite(n)?n:null}
function valid(lat,lon){return Number.isFinite(lat)&&Number.isFinite(lon)&&lat>=-90&&lat<=90&&lon>=-180&&lon<=180}
async function get(url,ms=9000){
  const c=new AbortController(),t=setTimeout(()=>c.abort(),ms);
  try{const r=await fetch(url,{signal:c.signal,headers:{'User-Agent':'RainETA/0.2 personal nowcasting project'}});if(!r.ok)throw Error('HTTP '+r.status);return r}
  finally{clearTimeout(t)}
}
async function metadata(){return (await get(META,5000)).json()}
function tile(host,frame,lat,lon){return host+frame.path+'/'+SIZE+'/'+ZOOM+'/'+lat+'/'+lon+'/2/0_0.png'}
async function maskFor(host,frame,lat,lon){
  const r=await get(tile(host,frame,lat,lon)),buf=Buffer.from(await r.arrayBuffer());
  const out=await sharp(buf).ensureAlpha().raw().toBuffer({resolveWithObject:true}),info=out.info,data=out.data;
  const alpha=new Uint8Array(info.width*info.height);
  for(let i=0,p=3;i<alpha.length;i++,p+=info.channels)alpha[i]=data[p];
  return{...makeMaskFromAlpha(alpha,info.width,info.height,{threshold:ALPHA,stride:STRIDE}),time:Number(frame.time),path:frame.path};
}
function median(a){const x=a.filter(Number.isFinite).sort((p,q)=>p-q);if(!x.length)return null;const m=Math.floor(x.length/2);return x.length%2?x[m]:(x[m-1]+x[m])/2}
function frameStep(a){const d=[];for(let i=1;i<a.length;i++){const v=(a[i].time-a[i-1].time)/60;if(v>0&&v<=30)d.push(v)}return median(d)||10}
function geo(motion,lat,step){
  const deg=(360/(256*(2**ZOOM)))*STRIDE,ekm=motion.dx*deg*111.32*Math.cos(lat*Math.PI/180),nkm=-motion.dy*deg*110.57,h=Math.max(1/60,step/60);
  return{eastKmh:ekm/h,northKmh:nkm/h,speedKmh:Math.hypot(ekm,nkm)/h,bearingDegrees:(Math.atan2(ekm,nkm)*180/Math.PI+360)%360};
}

export default async function handler(req,res){
  if(req.method!=='GET'){res.setHeader('Allow','GET');return reply(res,405,{error:'method_not_allowed'})}
  const lat=num(req.query?.lat),lon=num(req.query?.lon);if(!valid(lat,lon))return reply(res,400,{error:'invalid_coordinates'});
  const started=Date.now();
  try{
    const meta=await metadata(),frames=(meta.radar?.past||[]).slice(-FRAMES);
    if(frames.length<3)return reply(res,200,{status:'insufficient_frames',location:{lat,lon},frames:frames.length,event:null,confidence:0});
    const settled=await Promise.allSettled(frames.map(f=>maskFor(meta.host,f,lat,lon)));
    const masks=settled.filter(x=>x.status==='fulfilled').map(x=>x.value).sort((a,b)=>a.time-b.time);
    if(masks.length<3)return reply(res,200,{status:'insufficient_radar_data',location:{lat,lon},framesRequested:frames.length,framesDecoded:masks.length,event:null,confidence:0});
    const step=frameStep(masks),est=[];
    for(let i=1;i<masks.length;i++){
      if(masks[i].width!==masks[i-1].width||masks[i].height!==masks[i-1].height)continue;
      const m=estimateTranslation(masks[i-1].mask,masks[i].mask,masks[i].width,masks[i].height,{maxShift:16});
      if(m)est.push({...m,from:masks[i-1].time,to:masks[i].time});
    }
    const motion=combineMotionEstimates(est),latest=masks.at(-1),cx=(latest.width-1)/2,cy=(latest.height-1)/2,current=wetNear(latest.mask,latest.width,latest.height,cx,cy,1);
    const base={generatedAt:new Date().toISOString(),radarTime:new Date(latest.time*1000).toISOString(),location:{lat,lon},currentWetFraction:current,source:{name:'RainViewer',attribution:'Weather radar data by RainViewer'}};
    if(!motion||motion.samples<2||motion.confidence<.22)return reply(res,200,{...base,status:'motion_uncertain',event:null,confidence:motion?.confidence||0,diagnostics:{frameStepMinutes:step,decodedFrames:masks.length,motionSamples:motion?.samples||0}});
    const series=projectPointSeries(latest.mask,latest.width,latest.height,motion,{horizonMinutes:120,sourceStepMinutes:step,outputStepMinutes:5,radius:1});
    let event=detectNowcastEvent(series,{enterWetFraction:.11,exitWetFraction:.04,minConsecutive:2,stepMinutes:5});
    if(event){
      const t=latest.time*1000,u=nowcastUncertaintyMinutes(motion.confidence,event.startMinute);
      event={...event,start:new Date(t+event.startMinute*60000).toISOString(),end:new Date(t+event.endMinute*60000).toISOString(),uncertaintyMinutes:u};
    }
    return reply(res,200,{...base,status:'ok',rainingNow:current>=.11,event,confidence:motion.confidence,motion:{dxMaskPixelsPerFrame:motion.dx,dyMaskPixelsPerFrame:motion.dy,consistency:motion.consistency,samples:motion.samples,...geo(motion,lat,step)},series:series.map(x=>({minute:x.minute,probability:Math.round(x.probability*100),wetFraction:Number(x.wetFraction.toFixed(3))})),diagnostics:{frameStepMinutes:step,decodedFrames:masks.length,maskWidth:latest.width,maskHeight:latest.height,alphaThreshold:ALPHA,stride:STRIDE,elapsedMs:Date.now()-started}});
  }catch(e){return reply(res,502,{error:'nowcast_unavailable',message:String(e?.message||e),generatedAt:new Date().toISOString()},'no-store')}
}
