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
async function sampleOperaPoint(url,lat,lon){
  const [{fromUrl},{default:proj4}]=await Promise.all([import('geotiff'),import('proj4')]);
  const tiff=await fromUrl(url);
  const image=await tiff.getImage();
  const keys=image.getGeoKeys();
  const proj=`+proj=laea +lat_0=${Number(keys.ProjCenterLatGeoKey)||55} +lon_0=${Number(keys.ProjCenterLongGeoKey)||10} +x_0=${Number(keys.ProjFalseEastingGeoKey)||1950000} +y_0=${Number(keys.ProjFalseNorthingGeoKey)||-2100000} +ellps=WGS84 +units=m +no_defs`;
  const [x,y]=proj4('EPSG:4326',proj,[lon,lat]);
  const [ox,oy]=image.getOrigin(),[rx,ry]=image.getResolution();
  const px=Math.floor((x-ox)/rx),py=Math.floor((y-oy)/ry);
  if(px<0||py<0||px>=image.getWidth()||py>=image.getHeight())return{ok:false,error:'outside_composite'};
  const radius=1,x0=Math.max(0,px-radius),y0=Math.max(0,py-radius),x1=Math.min(image.getWidth(),px+radius+1),y1=Math.min(image.getHeight(),py+radius+1);
  const rasters=await image.readRasters({window:[x0,y0,x1,y1]});
  const rates=Array.from(rasters[0]||[]).filter(Number.isFinite);
  const qualities=Array.from(rasters[1]||[]).filter(Number.isFinite);
  const quality=qualities.length?qualities.reduce((a,b)=>a+b,0)/qualities.length:null;
  let rate=0;
  if(rates.length){
    const sorted=rates.slice().sort((a,b)=>a-b);
    rate=sorted[Math.floor(sorted.length/2)];
  }else if(!(quality>=.5)){
    return{ok:false,error:'no_valid_pixel',quality};
  }
  return{
    ok:true,
    rateMmH:Math.max(0,Number(rate)||0),
    quality,
    pixel:{x:px,y:py},
    grid:{width:image.getWidth(),height:image.getHeight(),resolutionM:Math.abs(rx)}
  };
}

async function rainOpera(req,res){
  if(req.method!=='GET')return res.status(405).json({error:'method_not_allowed'});
  res.setHeader('Cache-Control','public, s-maxage=240, stale-while-revalidate=900');
  const now=Date.now(),base=floor5(now-5*60_000);
  const candidates=Array.from({length:18},(_,i)=>{
    const observedAt=new Date(base.getTime()-i*5*60_000);
    return{observedAt,url:operaRateUrl(observedAt)};
  });
  for(let offset=0;offset<candidates.length;offset+=6){
    const batch=candidates.slice(offset,offset+6);
    const checks=await Promise.all(batch.map(async item=>({...item,ok:await exists(item.url)})));
    const found=checks.find(x=>x.ok);
    if(found){
      const lat=Number(req.query?.lat),lon=Number(req.query?.lon);
      let sample=null;
      if(Number.isFinite(lat)&&Number.isFinite(lon)&&lat>=-90&&lat<=90&&lon>=-180&&lon<=180){
        try{sample=await sampleOperaPoint(found.url,lat,lon)}catch(e){sample={ok:false,error:String(e?.message||e)}}
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
        sample
      });
    }
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
