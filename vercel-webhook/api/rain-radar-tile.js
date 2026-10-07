import sharp from 'sharp';
import {
  buildRainViewerSourceTileUrl,
  reconstructRadarTileRgba
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
export default async function handler(req,res){
  if(req.method!=='GET')return res.status(405).json({ok:false,error:'method_not_allowed'});
  try{
    const frame=q(req,'frame'),z=q(req,'z'),x=q(req,'x'),y=q(req,'y');
    const upstreamUrl=buildRainViewerSourceTileUrl({frame,z:Number(z),x:Number(x),y:Number(y),size:256});
    const upstream=await fetchTimed(upstreamUrl,12000);
    const bytes=Buffer.from(await upstream.arrayBuffer());
    const type=String(upstream.headers.get('content-type')||'').toLowerCase();
    if(!upstream.ok||!type.includes('image/png'))throw new Error('rainviewer_tile_'+upstream.status);
    const decoded=await sharp(bytes).ensureAlpha().raw().toBuffer({resolveWithObject:true});
    const rebuilt=reconstructRadarTileRgba(decoded.data,decoded.info.width,decoded.info.height,decoded.info.channels);
    const action=q(req,'action');
    if(action==='stats'){
      res.setHeader('Cache-Control','no-store');
      return res.status(200).json({
        ok:true,
        frame,z:Number(z),x:Number(x),y:Number(y),
        width:decoded.info.width,height:decoded.info.height,
        sourceAlphaPixels:rebuilt.sourceAlphaPixels,
        sourceAlphaFraction:rebuilt.sourceAlphaFraction,
        wetPixels:rebuilt.wetPixels,
        wetFraction:rebuilt.wetFraction
      });
    }
    const png=await sharp(Buffer.from(rebuilt.rgba),{
      raw:{width:decoded.info.width,height:decoded.info.height,channels:4}
    }).png({compressionLevel:7,palette:false}).toBuffer();
    res.setHeader('Content-Type','image/png');
    res.setHeader('Cache-Control','public, s-maxage=86400, immutable');
    res.setHeader('X-RainETA-Wet-Pixels',String(rebuilt.wetPixels));
    res.setHeader('X-RainETA-Source-Alpha-Pixels',String(rebuilt.sourceAlphaPixels));
    return res.status(200).end(png);
  }catch(error){
    const message=String(error?.name==='AbortError'?'rainviewer_timeout':error?.message||error||'radar_tile_error');
    return res.status(502).json({ok:false,error:message});
  }
}
