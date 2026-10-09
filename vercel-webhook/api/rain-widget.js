import {getAemetRadarData} from '../lib/rain-aemet-radar.js';
import {buildRainWidget} from '../rain/widget-core.js';

async function timed(url,ms=6500){
  const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),ms);
  try{
    const response=await fetch(url,{signal:controller.signal,headers:{Accept:'application/json'}});
    if(!response.ok)throw new Error('forecast_http_'+response.status);
    return await response.json();
  }finally{clearTimeout(timer)}
}
function query(req,key){
  const value=req.query?.[key];
  if(typeof value==='string')return value;
  try{return new URL(req.url,'http://localhost').searchParams.get(key)}catch{return null}
}
async function radarWithDeadline(lat,lon){
  if(!(lat>=35&&lat<=44.5&&lon>=-10&&lon<=4.5))return null;
  return Promise.race([
    getAemetRadarData(lat,lon,{motion:true}).catch(()=>null),
    new Promise(resolve=>setTimeout(()=>resolve(null),6500))
  ]);
}
export default async function handler(req,res){
  res.setHeader('Access-Control-Allow-Origin','*');
  res.setHeader('Cache-Control','public, s-maxage=240, stale-while-revalidate=120');
  res.setHeader('X-Content-Type-Options','nosniff');
  if(req.method!=='GET')return res.status(405).json({ok:false,error:'method_not_allowed'});
  const lat=Number(query(req,'lat')),lon=Number(query(req,'lon'));
  if(!Number.isFinite(lat)||!Number.isFinite(lon)||lat < -90||lat > 90||lon < -180||lon > 180||
    query(req,'lat')==null||query(req,'lon')==null)
    return res.status(400).json({ok:false,error:'invalid_coordinates'});
  // Bound precision to ~100m, improving caching and avoiding unnecessary exact-coordinate storage.
  const latitude=Number(lat.toFixed(3)),longitude=Number(lon.toFixed(3));
  const params=new URLSearchParams({
    latitude:String(latitude),longitude:String(longitude),
    current:'precipitation,rain,showers',
    minutely_15:'precipitation',
    forecast_minutely_15:'20',
    timeformat:'unixtime',timezone:'GMT'
  });
  const [forecastResult,radarResult]=await Promise.allSettled([
    timed('https://api.open-meteo.com/v1/forecast?'+params,6500),
    radarWithDeadline(latitude,longitude)
  ]);
  const forecast=forecastResult.status==='fulfilled'?forecastResult.value:null;
  const radar=radarResult.status==='fulfilled'?radarResult.value:null;
  const decision=buildRainWidget(forecast,radar,{nowMs:Date.now(),lat:latitude,lon:longitude});
  if(!decision.ok)return res.status(503).json({ok:false,error:'no_fresh_forecast',generatedAt:new Date().toISOString()});
  res.status(200).json(decision);
}
