import {estimateTranslation,combineMotionEstimates,projectPointSeries,detectNowcastEvent,nowcastUncertaintyMinutes} from "../rain/radar-core.js";
const S3='https://s3.waw3-1.cloudferro.com/openradar-24h';

function floor5(date){
  const d=new Date(date);
  d.setUTCSeconds(0,0);
  d.setUTCMinutes(Math.floor(d.getUTCMinutes()/5)*5);
  return d;
}
function pad(n){return String(n).padStart(2,'0')}
function operaRateUrl(date){
  const y=date.getUTCFullYear(),m=pad(date.getUTCMonth()+1),d=pad(date.getUTCDate());
  const hh=pad(date.getUTCHours()),mm=pad(date.getUTCMinutes());
  return `${S3}/${y}/${m}/${d}/OPERA/COMP/OPERA@${y}${m}${d}T${hh}${mm}@0@RATE.tiff`;
}
async function exists(url){
  try{
    const r=await fetch(url,{method:'HEAD',signal:AbortSignal.timeout(5000)});
    return r.ok;
  }catch{return false}
}
async function readOperaWindow(url,lat,lon,radius=1){
  const [{fromUrl},{default:proj4}]=await Promise.all([import('geotiff'),import('proj4')]);
  const tiff=await fromUrl(url);
  const image=await tiff.getImage();
  const keys=image.getGeoKeys();
  const proj=`+proj=laea +lat_0=${Number(keys.ProjCenterLatGeoKey)||55} +lon_0=${Number(keys.ProjCenterLongGeoKey)||10} +x_0=${Number(keys.ProjFalseEastingGeoKey)||1950000} +y_0=${Number(keys.ProjFalseNorthingGeoKey)||-2100000} +ellps=WGS84 +units=m +no_defs`;
  const [x,y]=proj4('EPSG:4326',proj,[lon,lat]);
  const [ox,oy]=image.getOrigin(),[rx,ry]=image.getResolution();
  const px=Math.floor((x-ox)/rx),py=Math.floor((y-oy)/ry);
  if(px<0||py<0||px>=image.getWidth()||py>=image.getHeight())return{ok:false,error:'outside_composite'};
  const x0=Math.max(0,px-radius),y0=Math.max(0,py-radius),x1=Math.min(image.getWidth(),px+radius+1),y1=Math.min(image.getHeight(),py+radius+1);
  const rasters=await image.readRasters({window:[x0,y0,x1,y1]});
  const width=x1-x0,height=y1-y0;
  return{
    ok:true,
    rates:new Float32Array(Array.from(rasters[0]||[],v=>Number.isFinite(Number(v))?Math.max(0,Number(v)):0)),
    qualities:new Float32Array(Array.from(rasters[1]||[],v=>Number.isFinite(Number(v))?Number(v):0)),
    width,height,centerX:px-x0,centerY:py-y0,
    pixel:{x:px,y:py},
    resolution:{x:Number(rx),y:Number(ry)},
    grid:{width:image.getWidth(),height:image.getHeight(),resolutionM:Math.abs(rx)}
  };
}
function medianFinite(values=[]){
  const a=values.filter(Number.isFinite).sort((x,y)=>x-y);
  if(!a.length)return null;
  const m=Math.floor(a.length/2);
  return a.length%2?a[m]:(a[m-1]+a[m])/2;
}
function summarizeOperaPoint(win){
  if(!win?.ok)return win||{ok:false,error:'window_unavailable'};
  const rates=[],qualities=[];
  for(let y=Math.max(0,Math.floor(win.centerY)-1);y<=Math.min(win.height-1,Math.floor(win.centerY)+1);y++){
    for(let x=Math.max(0,Math.floor(win.centerX)-1);x<=Math.min(win.width-1,Math.floor(win.centerX)+1);x++){
      const i=y*win.width+x,rate=Number(win.rates[i]),quality=Number(win.qualities[i]);
      if(Number.isFinite(rate))rates.push(rate);
      if(Number.isFinite(quality))qualities.push(quality);
    }
  }
  const rate=medianFinite(rates);
  const quality=qualities.length?qualities.reduce((a,b)=>a+b,0)/qualities.length:null;
  if(rate==null&&!(quality>=.5))return{ok:false,error:'no_valid_pixel',quality};
  return{
    ok:true,
    rateMmH:Math.max(0,Number(rate)||0),
    quality,
    pixel:win.pixel,
    grid:win.grid
  };
}
async function sampleOperaPoint(url,lat,lon){
  return summarizeOperaPoint(await readOperaWindow(url,lat,lon,1));
}
function operaMask(win){
  const mask=new Uint8Array(win.width*win.height);
  for(let i=0;i<mask.length;i++){
    const rate=Number(win.rates[i])||0,quality=Number(win.qualities[i]);
    mask[i]=rate>=.05&&(!Number.isFinite(quality)||quality>=.30)?1:0;
  }
  return mask;
}
function operaMotionGeo(motion,resolution,stepMinutes=5){
  const eastM=Number(motion.dx)*(Number(resolution?.x)||0);
  const northM=Number(motion.dy)*(Number(resolution?.y)||0);
  const hours=Math.max(1/60,Number(stepMinutes)/60);
  const speedKmh=Math.hypot(eastM,northM)/1000/hours;
  const bearingDegrees=(Math.atan2(eastM,northM)*180/Math.PI+360)%360;
  return{speedKmh,bearingDegrees};
}
async function buildOperaNowcast(frames,lat,lon){
  if(!Array.isArray(frames)||frames.length<2)return{status:'insufficient_frames',confidence:0,event:null};
  const selected=frames.slice(0,3).sort((a,b)=>a.observedAt-b.observedAt);
  const settled=await Promise.allSettled(selected.map(async frame=>({
    ...frame,
    window:await readOperaWindow(frame.url,lat,lon,70)
  })));
  const grids=settled.filter(x=>x.status==='fulfilled'&&x.value.window?.ok).map(x=>x.value);
  if(grids.length<2)return{status:'insufficient_data',confidence:0,event:null,decodedFrames:grids.length};
  const latest=grids.at(-1),latestMask=operaMask(latest.window),norm=[];
  for(let i=1;i<grids.length;i++){
    const prev=grids[i-1],cur=grids[i];
    if(prev.window.width!==cur.window.width||prev.window.height!==cur.window.height)continue;
    const dt=(cur.observedAt-prev.observedAt)/60_000;
    if(!(dt>=4&&dt<=20))continue;
    const estimate=estimateTranslation(operaMask(prev.window),operaMask(cur.window),cur.window.width,cur.window.height,{maxShift:10});
    if(estimate){
      const scale=5/dt;
      norm.push({...estimate,dx:estimate.dx*scale,dy:estimate.dy*scale,stepMinutes:dt});
    }
  }
  const motion=combineMotionEstimates(norm);
  const point=summarizeOperaPoint(latest.window),base={
    status:'motion_uncertain',
    confidence:motion?.confidence||0,
    event:null,
    observedAt:latest.observedAt.toISOString(),
    decodedFrames:grids.length,
    currentRateMmH:point?.ok?point.rateMmH:0
  };
  if(!motion||motion.confidence<.20)return base;
  const geo=operaMotionGeo(motion,latest.window.resolution,5);
  if(!Number.isFinite(geo.speedKmh)||geo.speedKmh<2||geo.speedKmh>220)return{...base,motion:{...geo,samples:motion.samples,consistency:motion.consistency}};
  const series=projectPointSeries(
    latestMask,latest.window.width,latest.window.height,motion,
    {horizonMinutes:120,sourceStepMinutes:5,outputStepMinutes:5,radius:1,intensityGrid:latest.window.rates}
  ).map(row=>({
    minute:row.minute,
    wetFraction:row.wetFraction,
    probability:row.probability,
    rateMmH:row.radarRate,
    sampleX:row.sampleX,
    sampleY:row.sampleY
  }));
  let event=detectNowcastEvent(
    series.map(row=>({...row,radarRate:row.rateMmH})),
    {enterWetFraction:.10,exitWetFraction:.035,minConsecutive:2,stepMinutes:5}
  );
  const qualityValues=Array.from(latest.window.qualities||[]).filter(v=>Number.isFinite(v)&&v>0);
  const patchQuality=qualityValues.length?medianFinite(qualityValues):null;
  const confidence=Math.max(0,Math.min(.95,motion.confidence*(patchQuality==null?1:(.72+.28*Math.max(0,Math.min(1,patchQuality))))));
  if(event){
    const baseMs=latest.observedAt.getTime();
    event={
      ...event,
      start:new Date(baseMs+event.startMinute*60_000).toISOString(),
      end:new Date(baseMs+event.endMinute*60_000).toISOString(),
      uncertaintyMinutes:nowcastUncertaintyMinutes(confidence,event.startMinute)
    };
  }
  return{
    ...base,
    status:'ok',
    confidence,
    event,
    motion:{...geo,samples:motion.samples,consistency:motion.consistency,gridDxPer5Min:motion.dx,gridDyPer5Min:motion.dy},
    series,
    patchQuality
  };
}

async function rainOpera(req,res){
  if(req.method!=='GET')return res.status(405).json({error:'method_not_allowed'});
  res.setHeader('Cache-Control','public, s-maxage=240, stale-while-revalidate=900');
  const now=Date.now(),base=floor5(now-5*60_000),wantMotion=String(req.query?.motion||'')==='1';
  const candidates=Array.from({length:18},(_,i)=>{
    const observedAt=new Date(base.getTime()-i*5*60_000);
    return{observedAt,url:operaRateUrl(observedAt)};
  });
  const foundFrames=[];
  for(let offset=0;offset<candidates.length;offset+=6){
    const batch=candidates.slice(offset,offset+6);
    const checks=await Promise.all(batch.map(async item=>({...item,ok:await exists(item.url)})));
    for(const item of checks)if(item.ok)foundFrames.push(item);
    if(foundFrames.length>=(wantMotion?3:1))break;
  }
  const found=foundFrames[0];
  if(found){
    const lat=Number(req.query?.lat),lon=Number(req.query?.lon);
    let sample=null,nowcast=null;
    if(Number.isFinite(lat)&&Number.isFinite(lon)&&lat>=-90&&lat<=90&&lon>=-180&&lon<=180){
      try{sample=await sampleOperaPoint(found.url,lat,lon)}catch(e){sample={ok:false,error:String(e?.message||e)}}
      if(wantMotion&&foundFrames.length>=2){
        try{nowcast=await buildOperaNowcast(foundFrames,lat,lon)}catch(e){nowcast={status:'error',confidence:0,event:null,error:String(e?.message||e)}}
      }
    }
    return res.status(200).json({
      ok:true,
      provider:'EUMETNET OPERA NIMBUS',
      product:'RATE',
      unit:'mm/h',
      resolutionKm:sample?.grid?.resolutionM?sample.grid.resolutionM/1000:2,
      updateMinutes:5,
      observedAt:found.observedAt.toISOString(),
      url:found.url,
      ageMinutes:Math.round((now-found.observedAt.getTime())/60_000),
      license:'CC BY 4.0',
      sample,
      nowcast,
      motionFrames:wantMotion?foundFrames.slice(0,3).map(x=>x.observedAt.toISOString()):undefined
    });
  }
  return res.status(503).json({ok:false,provider:'EUMETNET OPERA NIMBUS',product:'RATE',error:'latest_rate_composite_not_found'});
}

export default async function handler(req,res){
  if(String(req.query?.mode||'')==='rain-opera')return rainOpera(req,res);
  res.setHeader("cache-control","no-store");
  return res.status(410).json({
    ok:false,
    disabled:true,
    error:"Avisos TTiTTulares retirados"
  });
}
