import {gunzipSync} from "node:zlib";
import {parseTarEntries,decodeHarmoniePrecipRgba,HARMONIE_MAX_TAR_BYTES} from "../rain/harmonie-core.js";

const HARMONIE_PB_URL="https://www.aemet.es/es/api-eltiempo/modelos/download/harmonie/PB";
const ARCHIVE_TTL_MS=30*60_000;
const MAX_ARCHIVE_BYTES=80*1024*1024;
const MAX_TAR_BYTES=HARMONIE_MAX_TAR_BYTES;

let archiveCache=null;

function abortAfter(ms){
  if(typeof AbortSignal!=="undefined"&&typeof AbortSignal.timeout==="function")return AbortSignal.timeout(ms);
  return undefined;
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
  const {fromArrayBuffer}=await import("geotiff");
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
