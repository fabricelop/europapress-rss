import {wmsCapabilitiesHasLayer} from '../../vercel-webhook/rain/radar-core.js';
import {inflateSync} from 'node:zlib';
import {buildRainViewerSourceTileUrl,reconstructRadarTileRgba,decodeRadarTileField,buildSyntheticFutureField} from '../../vercel-webhook/lib/rain-radar-synthetic.js';
const loc={lat:'40.4168',lon:'-3.7038'};
const det=['ecmwf_ifs','ecmwf_aifs025','icon_seamless','gfs_seamless','meteofrance_seamless','gem_seamless','ukmo_global_deterministic_10km'];
const ens=['ecmwf_ifs_europe_ensemble','ecmwf_aifs025_ensemble','dwd_icon_eu_eps','ncep_gefs025','ukmo_global_ensemble_20km','gem_global_ensemble','bom_access_global_ensemble','google_weathernext2_ensemble'];
async function check(url){const c=new AbortController(),t=setTimeout(()=>c.abort(),12000);try{const r=await fetch(url,{signal:c.signal});const text=await r.text();if(!r.ok)throw Error(r.status+' '+text.slice(0,180));return JSON.parse(text)}finally{clearTimeout(t)}}
let ok=0;
for(const model of det){
 const p=new URLSearchParams({latitude:loc.lat,longitude:loc.lon,hourly:'precipitation',forecast_hours:'6',timeformat:'unixtime',timezone:'GMT',models:model});
 try{const d=await check('https://api.open-meteo.com/v1/forecast?'+p);if(!d.hourly?.time?.length)throw Error('no hourly');console.log('DET_OK',model,d.hourly.time.length);ok++}catch(e){console.log('DET_FAIL',model,String(e.message||e))}
}
let ensOk=0;
for(const model of ens){
 const p=new URLSearchParams({latitude:loc.lat,longitude:loc.lon,hourly:'precipitation',forecast_hours:'6',timeformat:'unixtime',timezone:'GMT',models:model});
 try{const d=await check('https://ensemble-api.open-meteo.com/v1/ensemble?'+p);const members=Object.keys(d.hourly||{}).filter(k=>k.startsWith('precipitation')&&Array.isArray(d.hourly[k])).length;if(!members)throw Error('no members');console.log('ENS_OK',model,members);ensOk++}catch(e){console.log('ENS_FAIL',model,String(e.message||e))}
}
const q=new URLSearchParams({latitude:loc.lat,longitude:loc.lon,minutely_15:'precipitation',forecast_minutely_15:'8',timeformat:'unixtime',timezone:'GMT'});
const qh=await check('https://api.open-meteo.com/v1/forecast?'+q);console.log('QH_OK',qh.minutely_15?.time?.length||0);
const radar=await check('https://api.rainviewer.com/public/weather-maps.json');if(!(radar.radar?.past||[]).length)throw Error('RainViewer sin frames');console.log('RADAR_OK',radar.radar.past.length,radar.host);


function paeth(a,b,c){
  const p=a+b-c,pa=Math.abs(p-a),pb=Math.abs(p-b),pc=Math.abs(p-c);
  return pa<=pb&&pa<=pc?a:pb<=pc?b:c;
}
function decodePngRgba(bytes){
  const data=Buffer.from(bytes);
  if(data.length<24||data.readUInt32BE(0)!==0x89504e47)throw Error('PNG signature');
  let pos=8,width=0,height=0,bitDepth=0,colorType=0,palette=null,alphaTable=null;
  const idat=[];
  while(pos+12<=data.length){
    const len=data.readUInt32BE(pos),type=data.toString('ascii',pos+4,pos+8),chunk=data.subarray(pos+8,pos+8+len);
    if(type==='IHDR'){width=chunk.readUInt32BE(0);height=chunk.readUInt32BE(4);bitDepth=chunk[8];colorType=chunk[9]}
    else if(type==='PLTE')palette=chunk;
    else if(type==='tRNS')alphaTable=chunk;
    else if(type==='IDAT')idat.push(chunk);
    else if(type==='IEND')break;
    pos+=12+len;
  }
  if(bitDepth!==8)throw Error('PNG bitDepth '+bitDepth);
  const bpp=colorType===6?4:colorType===2?3:colorType===4?2:1;
  const stride=width*bpp,raw=inflateSync(Buffer.concat(idat)),scan=Buffer.alloc(stride*height);
  let src=0;
  for(let y=0;y<height;y++){
    const filter=raw[src++],row=y*stride,prev=(y-1)*stride;
    for(let x=0;x<stride;x++){
      const val=raw[src++],a=x>=bpp?scan[row+x-bpp]:0,b=y?scan[prev+x]:0,c=y&&x>=bpp?scan[prev+x-bpp]:0;
      scan[row+x]=filter===0?val:
        filter===1?(val+a)&255:
        filter===2?(val+b)&255:
        filter===3?(val+Math.floor((a+b)/2))&255:
        filter===4?(val+paeth(a,b,c))&255:
        (()=>{throw Error('PNG filter '+filter)})();
    }
  }
  const rgba=Buffer.alloc(width*height*4);
  for(let i=0,o=0;i<width*height;i++,o+=4){
    if(colorType===6){rgba[o]=scan[i*4];rgba[o+1]=scan[i*4+1];rgba[o+2]=scan[i*4+2];rgba[o+3]=scan[i*4+3]}
    else if(colorType===2){rgba[o]=scan[i*3];rgba[o+1]=scan[i*3+1];rgba[o+2]=scan[i*3+2];rgba[o+3]=255}
    else if(colorType===4){rgba[o]=rgba[o+1]=rgba[o+2]=scan[i*2];rgba[o+3]=scan[i*2+1]}
    else if(colorType===0){rgba[o]=rgba[o+1]=rgba[o+2]=scan[i];rgba[o+3]=255}
    else if(colorType===3){
      const idx=scan[i],p=idx*3;
      rgba[o]=palette?.[p]??0;rgba[o+1]=palette?.[p+1]??0;rgba[o+2]=palette?.[p+2]??0;rgba[o+3]=alphaTable&&idx<alphaTable.length?alphaTable[idx]:255;
    }else throw Error('PNG colorType '+colorType);
  }
  return{rgba,width,height,colorType};
}
async function fetchPng(url){
  const c=new AbortController(),t=setTimeout(()=>c.abort(),12000);
  try{
    const r=await fetch(url,{signal:c.signal,headers:{Accept:'image/png'}});
    const bytes=new Uint8Array(await r.arrayBuffer());
    if(!r.ok)throw Error('PNG HTTP '+r.status);
    return decodePngRgba(bytes);
  }finally{clearTimeout(t)}
}
async function checkRainViewerSyntheticDecode(radar){
  const latest=radar.radar?.past?.at(-1);
  if(!latest?.path)throw Error('RainViewer latest frame missing');
  console.log('RADAR_FRAME',latest.time,latest.path);
  let totalRaw=0,totalWet=0,totalSmoothRaw=0,totalSmoothWet=0;
  for(const [x,y] of [[3,2],[4,2],[3,3],[4,3]]){
    const rawUrl=buildRainViewerSourceTileUrl({frame:latest.path,z:3,x,y,size:256});
    const smoothUrl=rawUrl.replace('/0_0.png','/1_1.png');
    const [rawPng,smoothPng]=await Promise.all([fetchPng(rawUrl),fetchPng(smoothUrl)]);
    const rawStats=reconstructRadarTileRgba(rawPng.rgba,rawPng.width,rawPng.height,4);
    const smoothStats=reconstructRadarTileRgba(smoothPng.rgba,smoothPng.width,smoothPng.height,4);
    totalRaw+=rawStats.sourceAlphaPixels;totalWet+=rawStats.wetPixels;
    totalSmoothRaw+=smoothStats.sourceAlphaPixels;totalSmoothWet+=smoothStats.wetPixels;
    console.log('RADAR_TILE_DECODE',3,x,y,'rawAlpha',rawStats.sourceAlphaPixels,'rawWet',rawStats.wetPixels,'smoothAlpha',smoothStats.sourceAlphaPixels,'smoothWet',smoothStats.wetPixels,'types',rawPng.colorType,smoothPng.colorType);
  }
  if(totalSmoothRaw>0&&totalRaw===0)throw Error('RainViewer 0_0 vacío mientras 1_1 contiene radar');
  if(totalRaw>0&&totalWet===0)throw Error('RainViewer decoder descarta todos los píxeles 0_0');
  console.log('RADAR_SYNTHETIC_DECODE_OK','rawAlpha',totalRaw,'rawWet',totalWet,'smoothAlpha',totalSmoothRaw,'smoothWet',totalSmoothWet);
}
await checkRainViewerSyntheticDecode(radar);

async function checkRainViewerSyntheticFuture(radar){
  const frames=(radar.radar?.past||[]).slice(-4);
  if(frames.length<3)throw Error('RainViewer future history missing');
  const candidates=[[15,10],[16,10],[17,10],[15,11],[16,11],[17,11],[15,12],[16,12],[17,12]];
  let best=null;
  for(const [x,y] of candidates){
    const decoded=[];
    for(const frame of frames){
      const png=await fetchPng(buildRainViewerSourceTileUrl({frame:frame.path,z:5,x,y,size:256}));
      decoded.push({...decodeRadarTileField(png.rgba,png.width,png.height,4),time:frame.time});
    }
    const sourceWet=decoded.at(-1).wetPixels;
    if(!best||sourceWet>best.sourceWet)best={x,y,decoded,sourceWet};
  }
  const times=best.decoded.map(row=>row.time);
  const future4=buildSyntheticFutureField(best.decoded,times,4,{persistenceMinutes:5});
  const future10=buildSyntheticFutureField(best.decoded,times,10,{persistenceMinutes:5});
  const wet4=future4.field.mask.reduce((s,v)=>s+(v?1:0),0),wet10=future10.field.mask.reduce((s,v)=>s+(v?1:0),0);
  if(best.sourceWet>100&&wet4===0)throw Error('Synthetic +4 lost a wet live tile');
  console.log('RADAR_SYNTHETIC_FUTURE','tile',best.x,best.y,'sourceWet',best.sourceWet,'+4',future4.status,wet4,'+10',future10.status,wet10,'quality',Number(future10.localQuality||0).toFixed(3),'horizon',future10.horizon);
}
await checkRainViewerSyntheticFuture(radar);

async function checkOpenMeteoSpatial(){
  const meta=await check('https://openmeteo.s3.amazonaws.com/data_spatial/dwd_icon_seamless/latest.json');
  if(!Array.isArray(meta.valid_times)||meta.valid_times.length<24)throw Error('Open-Meteo spatial valid_times missing');
  if(Array.isArray(meta.variables)&&!meta.variables.includes('precipitation'))throw Error('Open-Meteo spatial precipitation missing');
  const mod=await fetch('https://unpkg.com/@openmeteo/weather-map-layer@0.2.2/dist/index.mjs');
  const text=await mod.text();
  if(!mod.ok||!text.includes('omProtocol'))throw Error('Open-Meteo weather-map-layer unavailable');
  console.log('OPENMETEO_SPATIAL_OK',meta.reference_time||'no-reference',meta.valid_times.length,'precipitation');
}
await checkOpenMeteoSpatial();

const geo=await check('https://geocoding-api.open-meteo.com/v1/search?name=Madrid&count=2&language=es&format=json');if(!geo.results?.length)throw Error('geocode vacío');console.log('GEO_OK',geo.results[0].name);

async function checkBinarySource(label,url){
 const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),12000);
 try{
   let r=await fetch(url,{method:'HEAD',signal:controller.signal,redirect:'follow'});
   if(!r.ok||r.status===405){
     r=await fetch(url,{headers:{Range:'bytes=0-1023'},signal:controller.signal,redirect:'follow'});
   }
   const type=String(r.headers.get('content-type')||'');
   if(!r.ok)throw Error(r.status+' '+r.statusText);
   if(!/(gzip|tar|octet-stream)/i.test(type))throw Error('content-type inesperado '+type);
   try{await r.body?.cancel()}catch{}
   console.log(label+'_OK',r.status,type,r.headers.get('content-length')||'sin-tamaño');
 }finally{clearTimeout(timer)}
}
await checkBinarySource('AEMET_RADAR','https://www.aemet.es/es/api-eltiempo/radar/download/compo');
await checkBinarySource('AEMET_HARMONIE','https://www.aemet.es/es/api-eltiempo/modelos/download/harmonie/PB');

async function checkDwdLightning(){
 const base='https://maps.dwd.de/geoserver/dwd/wms';
 const timedFetch=async(url,ms,opts={})=>{
   const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),ms);
   try{return await fetch(url,{...opts,signal:controller.signal})}finally{clearTimeout(timer)}
 };
 try{
   const caps=await timedFetch(base+'?service=WMS&version=1.3.0&request=GetCapabilities',40000,{headers:{Accept:'application/xml,text/xml,*/*'}});
   const xml=await caps.text();
   if(!caps.ok)throw Error('GetCapabilities '+caps.status);
   const layers=['dwd:Accumulated_Flash_Area','dwd:Accumulated_Flash_Geometry','dwd:NCEW_EU','dwd:Blitzdichte'];
   for(const layer of layers)if(!wmsCapabilitiesHasLayer(xml,layer))throw Error('DWD layer ausente '+layer);
   for(const layer of ['dwd:Accumulated_Flash_Geometry','dwd:NCEW_EU']){
     const q=new URLSearchParams({
       service:'WMS',version:'1.1.1',request:'GetMap',layers:layer,styles:'',format:'image/png',
       transparent:'true',srs:'EPSG:3857',bbox:'-1500000,3500000,3500000,8000000',width:'128',height:'128'
     });
     const r=await timedFetch(base+'?'+q,18000);
     const bytes=new Uint8Array(await r.arrayBuffer()),type=String(r.headers.get('content-type')||'');
     const png=bytes.length>=8&&bytes[0]===0x89&&bytes[1]===0x50&&bytes[2]===0x4e&&bytes[3]===0x47;
     if(!r.ok||!png||!type.includes('image/png'))throw Error(layer+' GetMap inválido '+r.status+' '+type);
   }
   console.log('DWD_LIGHTNING_OK',layers.join(','));
 }finally{}
}
await checkDwdLightning();

if(ok<3)throw Error('Solo '+ok+' modelos deterministas disponibles');
if(ensOk<5)throw Error('Solo '+ensOk+' ensembles disponibles');
