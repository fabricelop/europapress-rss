import {gunzipSync} from "node:zlib";
import {fromArrayBuffer} from "geotiff";

const HARMONIE_PB_URL="https://www.aemet.es/es/api-eltiempo/modelos/download/harmonie/PB";
const ARCHIVE_TTL_MS=30*60_000;
const MAX_ARCHIVE_BYTES=80*1024*1024;
const MAX_TAR_BYTES=180*1024*1024;

const PRECIP_PALETTE=[
  {low:300,high:null,rgba:[236,200,200,255]},
  {low:250,high:300,rgba:[219,141,140,255]},
  {low:180,high:250,rgba:[204,84,83,255]},
  {low:120,high:180,rgba:[255,0,0,255]},
  {low:100,high:120,rgba:[255,61,3,255]},
  {low:80,high:100,rgba:[255,122,8,255]},
  {low:60,high:80,rgba:[255,186,15,255]},
  {low:40,high:60,rgba:[255,255,0,255]},
  {low:30,high:40,rgba:[191,230,0,255]},
  {low:20,high:30,rgba:[128,204,0,255]},
  {low:10,high:20,rgba:[0,153,0,255]},
  {low:5,high:10,rgba:[0,178,64,255]},
  {low:2,high:5,rgba:[0,204,128,255]},
  {low:1,high:2,rgba:[51,245,222,255]},
  {low:.5,high:1,rgba:[176,224,230,255]},
  // AEMET renders 0.0–0.5 mm transparent. The product cannot distinguish
  // a truly dry pixel from sub-0.5 mm precipitation, so RainETA treats it
  // as below the usable onset threshold instead of inventing drizzle.
  {low:0,high:.5,rgba:[19,49,52,0]}
];

let archiveCache=null;

function abortAfter(ms){
  if(typeof AbortSignal!=="undefined"&&typeof AbortSignal.timeout==="function")return AbortSignal.timeout(ms);
  return undefined;
}

export function parseTarEntries(buffer){
  const out=[];
  for(let offset=0;offset+512<=buffer.length;){
    const header=buffer.subarray(offset,offset+512);
    const name=header.subarray(0,100).toString("utf8").replace(/\0.*$/,"");
    if(!name)break;
    const sizeText=header.subarray(124,136).toString("ascii").replace(/\0.*$/,"").trim();
    const size=parseInt(sizeText||"0",8)||0;
    if(size<0||size>MAX_TAR_BYTES)throw new Error("AEMET HARMONIE: tamaño TAR inválido");
    const start=offset+512,end=start+size;
    if(end>buffer.length)throw new Error("AEMET HARMONIE: TAR truncado");
    out.push({name,size,start,end});
    offset=start+Math.ceil(size/512)*512;
  }
  return out;
}

export function decodeHarmoniePrecipRgba(r,g,b,a){
  let best=PRECIP_PALETTE.at(-1),distance=Infinity;
  for(const item of PRECIP_PALETTE){
    const [pr,pg,pb,pa]=item.rgba;
    // JPEG compression perturbs RGB slightly. Alpha is lossless and is useful
    // to distinguish the transparent <0.5 mm class from visible bins.
    const d=(Number(r)-pr)**2+(Number(g)-pg)**2+(Number(b)-pb)**2+.10*(Number(a)-pa)**2;
    if(d<distance){distance=d;best=item}
  }
  const estimate=best.low<.5?0:best.high==null?best.low:(best.low+best.high)/2;
  return{low:best.low,high:best.high,estimate,distance};
}

function archiveGeneratedAt(disposition){
  const m=String(disposition||"").match(/descargas_(\d{9,13})/);
  if(!m)return null;
  const raw=Number(m[1]),ms=raw>1e12?raw:raw*1000;
  return Number.isFinite(ms)?new Date(ms).toISOString():null;
}

async function fetchLatestArchive(){
  const now=Date.now();
  if(archiveCache&&now-archiveCache.fetchedAt<ARCHIVE_TTL_MS)return archiveCache;
  const response=await fetch(HARMONIE_PB_URL,{
    headers:{Accept:"application/tar+gzip,application/gzip,application/octet-stream,*/*"},
    signal:abortAfter(35_000)
  });
  if(!response.ok)throw new Error("AEMET HARMONIE HTTP "+response.status);
  const compressed=Buffer.from(await response.arrayBuffer());
  if(!compressed.length||compressed.length>MAX_ARCHIVE_BYTES)throw new Error("AEMET HARMONIE: paquete inesperado ("+compressed.length+" bytes)");
  const tar=gunzipSync(compressed,{maxOutputLength:MAX_TAR_BYTES});
  const entries=parseTarEntries(tar).filter(entry=>/_61_1HH\.tif$/i.test(entry.name));
  if(entries.length<24)throw new Error("AEMET HARMONIE: solo "+entries.length+" campos horarios de precipitación");
  const generatedAt=archiveGeneratedAt(response.headers.get("content-disposition"));
  archiveCache={
    fetchedAt:now,
    generatedAt,
    tar,
    entries:entries.sort((a,b)=>a.name.localeCompare(b.name)),
    compressedBytes:compressed.length
  };
  return archiveCache;
}

function entryValidTime(name){
  const m=String(name).match(/^down_(.+)_61_1HH\.tif$/i);
  if(!m)return null;
  const ms=Date.parse(m[1]);
  return Number.isFinite(ms)?new Date(ms).toISOString():null;
}

function clamp(value,min,max){return Math.max(min,Math.min(max,value))}

async function sampleEntry(archive,entry,lat,lon,radius=2){
  const bytes=archive.tar.subarray(entry.start,entry.end);
  const ab=bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength);
  const tiff=await fromArrayBuffer(ab);
  const image=await tiff.getImage();
  const [originX,originY]=image.getOrigin(),[resX,resY]=image.getResolution();
  const width=image.getWidth(),height=image.getHeight();
  const px=Math.floor((lon-originX)/resX),py=Math.floor((lat-originY)/resY);
  if(px<0||py<0||px>=width||py>=height)throw new Error("outside_harmonie_pb");
  const x0=clamp(px-radius,0,width-1),y0=clamp(py-radius,0,height-1);
  const x1=clamp(px+radius+1,1,width),y1=clamp(py+radius+1,1,height);
  const raster=await image.readRasters({window:[x0,y0,x1,y1],interleave:true});
  const sampleWidth=x1-x0,sampleHeight=y1-y0,samples=Math.max(1,Math.round(raster.length/(sampleWidth*sampleHeight)));
  const decoded=[];
  for(let i=0;i<raster.length;i+=samples){
    const r=raster[i],g=raster[i+1]??r,b=raster[i+2]??r,a=raster[i+3]??255;
    decoded.push(decodeHarmoniePrecipRgba(r,g,b,a));
  }
  const centerX=px-x0,centerY=py-y0,centerIndex=centerY*sampleWidth+centerX;
  const center=decoded[centerIndex]||{low:0,high:.5,estimate:0,distance:null};
  const visibleWet=decoded.filter(v=>v.low>=.5);
  const strongWet=decoded.filter(v=>v.low>=1);
  const maxLower=decoded.length?Math.max(...decoded.map(v=>Number(v.low)||0)):0;
  const maxEstimate=decoded.length?Math.max(...decoded.map(v=>Number(v.estimate)||0)):0;
  return{
    time:entryValidTime(entry.name),
    precipitation:center.estimate,
    precipitationLower:center.low,
    precipitationUpper:center.high,
    colorDistance:Number.isFinite(center.distance)?Math.round(center.distance):null,
    nearbyWetFraction:decoded.length?visibleWet.length/decoded.length:0,
    nearbyStrongFraction:decoded.length?strongWet.length/decoded.length:0,
    nearbyMaxLower:maxLower,
    nearbyMaxEstimate:maxEstimate,
    grid:{resolutionDegrees:Math.abs(Number(resX)||.025),width,height},
    sample:{radiusCells:radius,width:sampleWidth,height:sampleHeight}
  };
}

export async function sampleAemetHarmonie(lat,lon,{hours=48,radius=2}={}){
  lat=Number(lat);lon=Number(lon);
  if(!Number.isFinite(lat)||!Number.isFinite(lon))throw new Error("invalid_coordinates");
  // Actual PB GeoTIFF footprint: ~34.49–44.49N, -11.01–4.99E.
  if(lat<34.45||lat>44.55||lon<-11.1||lon>5.1)throw new Error("outside_harmonie_pb");
  const archive=await fetchLatestArchive();
  const limit=Math.max(1,Math.min(48,Math.round(Number(hours)||48)));
  const entries=archive.entries.slice(0,limit);
  const rows=[];
  // Decode a few small GeoTIFFs at a time. This bounds memory and CPU while
  // still keeping endpoint latency low.
  for(let i=0;i<entries.length;i+=6){
    const batch=entries.slice(i,i+6);
    rows.push(...await Promise.all(batch.map(entry=>sampleEntry(archive,entry,lat,lon,Math.max(0,Math.min(4,Math.round(radius)))))));
  }
  return{
    ok:true,
    provider:"AEMET",
    model:"HARMONIE-AROME",
    domain:"Península y Baleares",
    resolutionKm:2.5,
    temporalResolutionMinutes:60,
    horizonHours:rows.length,
    sourceGeneratedAt:archive.generatedAt,
    fetchedAt:new Date(archive.fetchedAt).toISOString(),
    archiveBytes:archive.compressedBytes,
    rows
  };
}
