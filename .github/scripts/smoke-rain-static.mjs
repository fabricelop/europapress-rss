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
const geo=await check('https://geocoding-api.open-meteo.com/v1/search?name=Madrid&count=2&language=es&format=json');if(!geo.results?.length)throw Error('geocode vacío');console.log('GEO_OK',geo.results[0].name);
if(ok<3)throw Error('Solo '+ok+' modelos deterministas disponibles');
if(ensOk<5)throw Error('Solo '+ensOk+' ensembles disponibles');
