export const DWD_LIGHTNING_WMS_URL='https://maps.dwd.de/geoserver/dwd/wms';
export const DWD_LIGHTNING_LAYERS=['dwd:Accumulated_Flash_Geometry','dwd:NCEW_EU'];

export function normalizeLightningLayer(value){
  const raw=String(value||'').trim();
  const local=raw.includes(':')?raw.split(':').pop():raw;
  const match=DWD_LIGHTNING_LAYERS.find(layer=>layer===raw||layer.endsWith(':'+local));
  if(!match)throw new Error('layer_not_allowed');
  return match;
}
export function parseLightningBbox(value){
  const parts=String(value||'').split(',').map(Number);
  if(parts.length!==4||parts.some(v=>!Number.isFinite(v)))throw new Error('invalid_bbox');
  const [minX,minY,maxX,maxY]=parts;
  const limit=20037508.35+1000;
  if(!(minX<maxX&&minY<maxY)||parts.some(v=>Math.abs(v)>limit))throw new Error('invalid_bbox');
  return parts;
}
export function wmsCapabilitiesHasLayer(xml,layerName){
  const text=String(xml||''),full=String(layerName||'').trim(),local=full.includes(':')?full.split(':').pop():full;
  if(!local)return false;
  return text.includes('<Name>'+full+'</Name>')||text.includes('<Name>'+local+'</Name>');
}
export function buildDwdLightningCapabilitiesUrl(){
  return DWD_LIGHTNING_WMS_URL+'?service=WMS&version=1.3.0&request=GetCapabilities';
}
export function buildDwdLightningGetMapUrl({layer,bbox,width=256,height=256}){
  const selected=normalizeLightningLayer(layer),box=parseLightningBbox(bbox);
  const w=Math.max(64,Math.min(512,Math.round(Number(width)||256)));
  const h=Math.max(64,Math.min(512,Math.round(Number(height)||256)));
  const q=new URLSearchParams({
    service:'WMS',version:'1.1.1',request:'GetMap',layers:selected,styles:'',
    format:'image/png',transparent:'true',srs:'EPSG:3857',
    bbox:box.join(','),width:String(w),height:String(h)
  });
  return DWD_LIGHTNING_WMS_URL+'?'+q.toString();
}
