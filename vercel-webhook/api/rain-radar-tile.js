import sharp from 'sharp';
import {
  buildRainViewerSourceTileUrl,decodeRadarTileField,buildSyntheticFutureField,
  renderRadarFieldRgba,validateRainViewerFramePath
} from '../lib/rain-radar-synthetic.js';

async function fetchTimed(url,ms=12000){
  const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),ms);
  try{return await fetch(url,{signal:controller.signal,headers:{Accept:'image/png'}})}
  finally{clearTimeout(timer)}
}
function q(req,key){
  const v=req?.query?.[key];
  if(typeof v==='string')return v;
  try{return new URL(req.url||'/','http://localhost').searchParams.get(key)||''}catch{return''}
}
function frameInputs(req){
  const rows=[];
  for(let i=0;i<4;i++){
    const frame=q(req,'f'+i),time=Number(q(req,'t'+i));
    if(!frame)continue;
    rows.push({frame:validateRainViewerFramePath(frame),time:Number.isFinite(time)?time:null});
  }
  if(!rows.length){
    const frame=q(req,'frame');
    if(frame)rows.push({frame:validateRainViewerFramePath(frame),time:Number(q(req,'time'))||null});
  }
  return rows.slice(-4);
}
async function decodeSourceTile(input,z,x,y){
  const upstreamUrl=buildRainViewerSourceTileUrl({frame:input.frame,z,x,y,size:256});
  const upstream=await fetchTimed(upstreamUrl,12000);
  const bytes=Buffer.from(await upstream.arrayBuffer());
  const type=String(upstream.headers.get('content-type')||'').toLowerCase();
  if(!upstream.ok||!type.includes('image/png'))throw new Error('rainviewer_tile_'+upstream.status);
  const decoded=await sharp(bytes).ensureAlpha().raw().toBuffer({resolveWithObject:true});
  return{...decodeRadarTileField(decoded.data,decoded.info.width,decoded.info.height,decoded.info.channels),frame:input.frame,time:input.time};
}
export default async function handler(req,res){
  if(req.method!=='GET')return res.status(405).json({ok:false,error:'method_not_allowed'});
  try{
    const z=Number(q(req,'z')),x=Number(q(req,'x')),y=Number(q(req,'y')),minutes=Math.max(0,Math.min(90,Number(q(req,'minutes'))||0));
    const inputs=frameInputs(req);
    if(!inputs.length)throw new Error('missing_frames');
    const needed=minutes<=3?[inputs.at(-1)]:inputs;
    const fields=await Promise.all(needed.map(input=>decodeSourceTile(input,z,x,y)));
    let result;
    if(minutes<=0){
      const latest=fields.at(-1);
      result={status:'observed_rebuild',field:latest,...renderRadarFieldRgba(latest),horizon:0,localQuality:0,flowVectors:0};
    }else{
      result=buildSyntheticFutureField(fields,needed.map(row=>row.time),minutes,{persistenceMinutes:5});
      const alphaScale=result.status==='flow'?Math.max(.48,1-.012*minutes):Math.max(.42,1-.07*Math.max(0,minutes-3));
      result={...result,...renderRadarFieldRgba(result.field,{alphaScale})};
    }
    const latest=fields.at(-1),action=q(req,'action');
    if(action==='stats'){
      res.setHeader('Cache-Control','no-store');
      return res.status(200).json({
        ok:true,status:result.status,minutes,z,x,y,sourceWetPixels:latest.wetPixels,wetPixels:result.wetPixels,
        sourceAlphaPixels:latest.sourceAlphaPixels,localQuality:result.localQuality,horizon:result.horizon,
        flowVectors:result.flowVectors,evolution:result.evolution??null,sourceStepMinutes:result.sourceStepMinutes??null
      });
    }
    const png=await sharp(Buffer.from(result.rgba),{raw:{width:result.field.width,height:result.field.height,channels:4}}).png({compressionLevel:7,palette:false}).toBuffer();
    res.setHeader('Content-Type','image/png');
    res.setHeader('Cache-Control','public, s-maxage=86400, immutable');
    res.setHeader('X-RainETA-Status',String(result.status));
    res.setHeader('X-RainETA-Wet-Pixels',String(result.wetPixels));
    res.setHeader('X-RainETA-Source-Wet-Pixels',String(latest.wetPixels));
    res.setHeader('X-RainETA-Horizon',String(result.horizon||0));
    res.setHeader('X-RainETA-Flow-Quality',String(Number(result.localQuality||0).toFixed(3)));
    return res.status(200).end(png);
  }catch(error){
    const message=String(error?.name==='AbortError'?'rainviewer_timeout':error?.message||error||'radar_tile_error');
    return res.status(502).json({ok:false,error:message});
  }
}
