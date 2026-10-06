const S3='https://s3.waw3-1.cloudferro.com/openradar-24h';

function floor5(date){
  const d=new Date(date);
  d.setUTCSeconds(0,0);
  d.setUTCMinutes(Math.floor(d.getUTCMinutes()/5)*5);
  return d;
}
function pad(n){return String(n).padStart(2,'0')}
function rateUrl(date){
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

export default async function handler(req,res){
  if(req.method!=='GET')return res.status(405).json({error:'method_not_allowed'});
  res.setHeader('Cache-Control','public, s-maxage=240, stale-while-revalidate=900');
  const now=Date.now();
  const base=floor5(now-5*60_000);
  for(let i=0;i<18;i++){
    const observedAt=new Date(base.getTime()-i*5*60_000);
    const url=rateUrl(observedAt);
    if(await exists(url)){
      return res.status(200).json({
        ok:true,
        provider:'EUMETNET OPERA NIMBUS',
        product:'RATE',
        unit:'mm/h',
        resolutionKm:1,
        updateMinutes:5,
        observedAt:observedAt.toISOString(),
        url,
        ageMinutes:Math.round((now-observedAt.getTime())/60_000),
        license:'CC BY 4.0',
        sampling:'backend-ready'
      });
    }
  }
  return res.status(503).json({
    ok:false,
    provider:'EUMETNET OPERA NIMBUS',
    product:'RATE',
    error:'latest_rate_composite_not_found'
  });
}
