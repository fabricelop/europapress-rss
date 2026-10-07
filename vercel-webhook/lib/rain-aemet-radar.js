import {gunzipSync} from "node:zlib";
import {parseTarEntries,HARMONIE_MAX_TAR_BYTES} from "../rain/harmonie-core.js";
import {
  estimateTranslation,combineMotionEstimates,projectPointSeries,
  estimateLocalFlow,combineLocalFlows,projectPointSeriesFlow,
  evolutionReliability,detectNowcastEvent,nowcastUncertaintyMinutes
} from "../rain/radar-core.js";

const AEMET_RADAR_URL="https://www.aemet.es/es/api-eltiempo/radar/download/compo";
const ARCHIVE_TTL_MS=4*60_000;
const MAX_ARCHIVE_BYTES=8*1024*1024;
const MAX_TAR_BYTES=Math.min(HARMONIE_MAX_TAR_BYTES,64*1024*1024);
let radarCache=null;

function abortAfter(ms){
  if(typeof AbortSignal!=="undefined"&&typeof AbortSignal.timeout==="function")return AbortSignal.timeout(ms);
  return undefined;
}
function generatedAt(disposition){
  const m=String(disposition||"").match(/descargas_(\d{9,13})/);
  if(!m)return null;
  const raw=Number(m[1]),ms=raw>1e12?raw:raw*1000;
  return Number.isFinite(ms)?new Date(ms).toISOString():null;
}
function frameTime(name){
  const m=String(name).match(/radw(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})_4326\.tif$/i);
  if(!m)return null;
  const [,y,mo,d,h,mi]=m;
  return new Date(Date.UTC(Number(y),Number(mo)-1,Number(d),Number(h),Number(mi))).toISOString();
}
async function fetchArchive(){
  const now=Date.now();
  if(radarCache&&now-radarCache.fetchedAt<ARCHIVE_TTL_MS)return radarCache;
  const response=await fetch(AEMET_RADAR_URL,{
    headers:{Accept:"application/tar+gzip,application/gzip,application/octet-stream,*/*"},
    signal:abortAfter(20_000)
  });
  if(!response.ok)throw new Error("AEMET radar HTTP "+response.status);
  const compressed=Buffer.from(await response.arrayBuffer());
  if(!compressed.length||compressed.length>MAX_ARCHIVE_BYTES)throw new Error("AEMET radar: paquete inesperado ("+compressed.length+" bytes)");
  const tar=gunzipSync(compressed,{maxOutputLength:MAX_TAR_BYTES});
  const entries=parseTarEntries(tar,{maxEntryBytes:8*1024*1024})
    .filter(entry=>/down_radw\d{12}_4326\.tif$/i.test(entry.name))
    .map(entry=>({...entry,time:frameTime(entry.name)}))
    .filter(entry=>entry.time)
    .sort((a,b)=>Date.parse(a.time)-Date.parse(b.time));
  if(entries.length<6)throw new Error("AEMET radar: solo "+entries.length+" barridos");
  radarCache={fetchedAt:now,generatedAt:generatedAt(response.headers.get("content-disposition")),tar,entries,compressedBytes:compressed.length};
  return radarCache;
}
function toArrayBuffer(buffer){
  return buffer.buffer.slice(buffer.byteOffset,buffer.byteOffset+buffer.byteLength);
}
async function imageFor(archive,entry){
  const {fromArrayBuffer}=await import("geotiff");
  const bytes=archive.tar.subarray(entry.start,entry.end);
  const tiff=await fromArrayBuffer(toArrayBuffer(bytes));
  return tiff.getImage();
}
function pixelFor(image,lat,lon){
  const [ox,oy]=image.getOrigin(),[rx,ry]=image.getResolution();
  const x=Math.floor((lon-ox)/rx),y=Math.floor((lat-oy)/ry);
  if(x<0||y<0||x>=image.getWidth()||y>=image.getHeight())throw new Error("outside_aemet_radar");
  return{x,y,rx:Number(rx),ry:Number(ry)};
}
function radarDbz(index){
  const v=Number(index);
  if(v>=2&&v<=12)return v*6;
  return null;
}
function dbzToRainRate(dbz){
  if(!Number.isFinite(dbz)||dbz<12)return 0;
  const z=10**(dbz/10);
  return Math.min(120,(z/200)**(1/1.6));
}
function median(values=[]){
  const a=values.filter(Number.isFinite).sort((x,y)=>x-y);
  if(!a.length)return 0;
  const m=Math.floor(a.length/2);
  return a.length%2?a[m]:(a[m-1]+a[m])/2;
}
async function readWindow(archive,entry,lat,lon,radius=45){
  const image=await imageFor(archive,entry),p=pixelFor(image,lat,lon);
  const width=image.getWidth(),height=image.getHeight();
  const x0=Math.max(0,p.x-radius),y0=Math.max(0,p.y-radius),x1=Math.min(width,p.x+radius+1),y1=Math.min(height,p.y+radius+1);
  const rasters=await image.readRasters({window:[x0,y0,x1,y1],interleave:true});
  const w=x1-x0,h=y1-y0,mask=new Uint8Array(w*h),rates=new Float32Array(w*h),indices=new Uint8Array(w*h);
  for(let i=0;i<indices.length;i++){
    const v=Number(rasters[i])||0,dbz=radarDbz(v);
    indices[i]=v;
    mask[i]=Number.isFinite(dbz)?1:0;
    rates[i]=dbzToRainRate(dbz);
  }
  return{
    entry,image,mask,rates,indices,width:w,height:h,
    centerX:p.x-x0,centerY:p.y-y0,
    resolution:{x:p.rx,y:p.ry},
    fullGrid:{width,height},
    bounds:{
      west:image.getOrigin()[0],
      north:image.getOrigin()[1],
      east:image.getOrigin()[0]+image.getResolution()[0]*width,
      south:image.getOrigin()[1]+image.getResolution()[1]*height
    }
  };
}
function pointSummary(win,radius=1){
  const rates=[],dbzs=[],wet=[];
  const cx=Math.round(win.centerX),cy=Math.round(win.centerY);
  for(let y=Math.max(0,cy-radius);y<=Math.min(win.height-1,cy+radius);y++){
    for(let x=Math.max(0,cx-radius);x<=Math.min(win.width-1,cx+radius);x++){
      const i=y*win.width+x,dbz=radarDbz(win.indices[i]);
      rates.push(Number(win.rates[i])||0);
      if(Number.isFinite(dbz))dbzs.push(dbz);
      wet.push(Number.isFinite(dbz)?1:0);
    }
  }
  return{
    rateMmH:median(rates),
    maxRateMmH:rates.length?Math.max(...rates):0,
    dbzMedian:median(dbzs),
    dbzMax:dbzs.length?Math.max(...dbzs):null,
    wetFraction:wet.length?wet.reduce((a,b)=>a+b,0)/wet.length:0
  };
}
function motionGeo(motion,resolution,lat,stepMinutes=10){
  const eastKm=Number(motion.dx)*Math.abs(Number(resolution?.x)||0)*111.32*Math.max(.25,Math.cos(lat*Math.PI/180));
  const northKm=-Number(motion.dy)*Math.abs(Number(resolution?.y)||0)*111.32;
  const hours=Math.max(1/60,stepMinutes/60);
  return{speedKmh:Math.hypot(eastKm,northKm)/hours,bearingDegrees:(Math.atan2(eastKm,northKm)*180/Math.PI+360)%360};
}
async function buildNowcast(archive,lat,lon){
  const selected=archive.entries.slice(-6);
  const settled=await Promise.allSettled(selected.map(entry=>readWindow(archive,entry,lat,lon,45)));
  const frames=settled.filter(x=>x.status==="fulfilled").map(x=>x.value);
  if(frames.length<3)return{status:"insufficient_data",confidence:0,event:null,decodedFrames:frames.length};
  const latest=frames.at(-1),previous=frames.at(-2),estimates=[];
  for(let i=1;i<frames.length;i++){
    const dt=(Date.parse(frames[i].entry.time)-Date.parse(frames[i-1].entry.time))/60_000;
    if(!(dt>=5&&dt<=20)||frames[i].width!==frames[i-1].width||frames[i].height!==frames[i-1].height)continue;
    const e=estimateTranslation(frames[i-1].mask,frames[i].mask,frames[i].width,frames[i].height,{maxShift:10});
    if(e){
      const scale=10/dt;
      estimates.push({...e,dx:e.dx*scale,dy:e.dy*scale});
    }
  }
  const motion=combineMotionEstimates(estimates);
  const point=pointSummary(latest,1);
  const evolution=motion?evolutionReliability(previous.mask,latest.mask,latest.width,latest.height,motion):{score:0,overlap:0,densityStable:0};
  const confidence=Math.max(0,Math.min(.98,(motion?.confidence||0)*(.72+.28*(Number(evolution.score)||0))));
  const reliableHorizonMinutes=Math.round(20+55*Math.max(0,Math.min(1,(Number(evolution.score)||0)*.7+confidence*.3)));
  const base={
    status:"motion_uncertain",confidence,event:null,
    observedAt:latest.entry.time,decodedFrames:frames.length,
    currentRateMmH:point.rateMmH,currentMaxRateMmH:point.maxRateMmH,
    currentDbz:point.dbzMedian,currentDbzMax:point.dbzMax,
    currentWetFraction:point.wetFraction,evolution,reliableHorizonMinutes
  };
  if(!motion||motion.samples<2||confidence<.22)return base;
  const geo=motionGeo(motion,latest.resolution,lat,10);
  if(!Number.isFinite(geo.speedKmh)||geo.speedKmh<1||geo.speedKmh>180)return{...base,rejectedMotion:geo};
  const flows=[];
  for(let i=Math.max(1,frames.length-3);i<frames.length;i++){
    const flow=estimateLocalFlow(frames[i-1].mask,frames[i].mask,latest.width,latest.height,{maxShift:8,grid:5,patchRadius:9});
    if(flow)flows.push(flow);
  }
  const localFlow=combineLocalFlows(flows);
  const series=localFlow
    ? projectPointSeriesFlow(latest.mask,latest.width,latest.height,localFlow,motion,{horizonMinutes:120,sourceStepMinutes:10,outputStepMinutes:5,radius:1,intensityGrid:latest.rates,reliability:evolution.score})
    : projectPointSeries(latest.mask,latest.width,latest.height,motion,{horizonMinutes:120,sourceStepMinutes:10,outputStepMinutes:5,radius:1,intensityGrid:latest.rates});
  let event=detectNowcastEvent(series,{enterWetFraction:.10,exitWetFraction:.035,minConsecutive:2,stepMinutes:5});
  if(event){
    const t=Date.parse(latest.entry.time);
    event={...event,start:new Date(t+event.startMinute*60_000).toISOString(),end:new Date(t+event.endMinute*60_000).toISOString(),uncertaintyMinutes:nowcastUncertaintyMinutes(confidence,event.startMinute)};
  }
  return{
    ...base,status:"ok",confidence,event,series,
    localFlowCoverage:Number(localFlow?.coverage)||0,
    motion:{...geo,samples:motion.samples,consistency:motion.consistency,localFlow:Boolean(localFlow)}
  };
}
export async function getAemetRadarData(lat,lon,{motion=true}={}){
  lat=Number(lat);lon=Number(lon);
  if(!Number.isFinite(lat)||!Number.isFinite(lon))throw new Error("invalid_coordinates");
  const archive=await fetchArchive(),latest=archive.entries.at(-1);
  const ageMinutes=Math.max(0,(Date.now()-Date.parse(latest.time))/60_000);
  const latestWindow=await readWindow(archive,latest,lat,lon,2);
  const sample=pointSummary(latestWindow,1);
  const nowcast=motion?await buildNowcast(archive,lat,lon):null;
  return{
    ok:true,provider:"AEMET",product:"Composición nacional radar PPI",unit:"dBZ",
    updateMinutes:10,observedAt:latest.time,ageMinutes,
    sourceGeneratedAt:archive.generatedAt,archiveBytes:archive.compressedBytes,
    frames:archive.entries.map(entry=>({time:entry.time,id:entry.name})),
    bounds:latestWindow.bounds,
    grid:{...latestWindow.fullGrid,resolutionDegrees:Math.abs(Number(latestWindow.resolution.x)||0)},
    sample,nowcast
  };
}
export async function getAemetRadarPng(frameId){
  const archive=await fetchArchive();
  const requested=String(frameId||"");
  const entry=archive.entries.find(x=>x.name===requested||x.time===requested)||archive.entries.at(-1);
  if(!entry)throw new Error("radar_frame_not_found");
  const image=await imageFor(archive,entry),width=image.getWidth(),height=image.getHeight();
  const raster=await image.readRasters({interleave:true});
  const fd=image.getFileDirectory(),cm=fd.ColorMap;
  const rgba=Buffer.alloc(width*height*4);
  for(let i=0;i<raster.length;i++){
    const idx=Number(raster[i])||0,o=i*4;
    const visible=idx>=2&&idx<=12;
    rgba[o]=cm?Math.round(Number(cm[idx]||0)/257):255;
    rgba[o+1]=cm?Math.round(Number(cm[256+idx]||0)/257):255;
    rgba[o+2]=cm?Math.round(Number(cm[512+idx]||0)/257):255;
    rgba[o+3]=visible?205:0;
  }
  const {default:sharp}=await import("sharp");
  const png=await sharp(rgba,{raw:{width,height,channels:4}}).png({compressionLevel:7}).toBuffer();
  const [ox,oy]=image.getOrigin(),[rx,ry]=image.getResolution();
  return{
    png,time:entry.time,id:entry.name,width,height,
    bounds:{west:ox,north:oy,east:ox+rx*width,south:oy+ry*height}
  };
}
