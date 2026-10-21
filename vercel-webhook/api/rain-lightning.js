import {
  DWD_LIGHTNING_LAYERS,
  buildDwdLightningCapabilitiesUrl,
  buildDwdLightningGetMapUrl,
  wmsCapabilitiesHasLayer
} from '../lib/rain-lightning.js';

async function fetchTimed(url,timeoutMs,options={}){
  const controller=new AbortController();
  const timer=setTimeout(()=>controller.abort(),timeoutMs);
  try{return await fetch(url,{...options,signal:controller.signal})}
  finally{clearTimeout(timer)}
}
function actionOf(req){
  const direct=req?.query?.action;
  if(typeof direct==='string'&&direct)return direct;
  try{return new URL(req.url||'/','http://localhost').searchParams.get('action')||'capabilities'}catch{return'capabilities'}
}
function queryValue(req,key){
  const direct=req?.query?.[key];
  if(typeof direct==='string')return direct;
  try{return new URL(req.url||'/','http://localhost').searchParams.get(key)||''}catch{return''}
}
export default async function handler(req,res){
  if(req.method!=='GET')return res.status(405).json({ok:false,error:'method_not_allowed'});
  const action=actionOf(req);
  try{
    if(action==='capabilities'){
      const upstream=await fetchTimed(buildDwdLightningCapabilitiesUrl(),35_000,{headers:{Accept:'application/xml,text/xml,*/*'}});
      const xml=await upstream.text();
      if(!upstream.ok)throw new Error('dwd_capabilities_http_'+upstream.status);
      const layers=DWD_LIGHTNING_LAYERS.filter(layer=>wmsCapabilitiesHasLayer(xml,layer));
      if(layers.length!==DWD_LIGHTNING_LAYERS.length)throw new Error('dwd_layers_missing');
      res.setHeader('Cache-Control','public, s-maxage=300, stale-while-revalidate=900');
      return res.status(200).json({ok:true,provider:'DWD',layers});
    }
    if(action==='tile'){
      const url=buildDwdLightningGetMapUrl({
        layer:queryValue(req,'layer'),
        bbox:queryValue(req,'bbox'),
        width:queryValue(req,'width')||256,
        height:queryValue(req,'height')||256
      });
      const upstream=await fetchTimed(url,20_000,{headers:{Accept:'image/png'}});
      const bytes=Buffer.from(await upstream.arrayBuffer());
      const type=String(upstream.headers.get('content-type')||'');
      const png=bytes.length>=8&&bytes[0]===0x89&&bytes[1]===0x50&&bytes[2]===0x4e&&bytes[3]===0x47;
      if(!upstream.ok||!png||!type.toLowerCase().includes('image/png'))throw new Error('dwd_tile_invalid_'+upstream.status);
      res.setHeader('Content-Type','image/png');
      res.setHeader('Cache-Control','public, s-maxage=120, stale-while-revalidate=300');
      res.setHeader('Content-Length',String(bytes.length));
      return res.status(200).end(bytes);
    }
    return res.status(400).json({ok:false,error:'invalid_action'});
  }catch(error){
    const message=String(error?.name==='AbortError'?'dwd_timeout':error?.message||error||'dwd_error');
    return res.status(502).json({ok:false,provider:'DWD',error:message});
  }
}
