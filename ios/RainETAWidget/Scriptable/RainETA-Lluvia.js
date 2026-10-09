// RainETA — widget de lluvia para Scriptable (iPhone).
// Parámetro opcional del widget: "40.4168,-3.7038|Madrid". Vacío = ubicación actual.
// El endpoint RainETA tiene preferencia. Hasta su despliegue, Open-Meteo aporta una
// predicción alternativa (interpolada a 15 min en Iberia; NO precisión de minuto).
const RAINETA_BASE = "https://europapress-rss.vercel.app";
const RAINETA_PREVIEW = ""; // Opcional: sustituir por la URL HTTPS de preview validada
const PARAM = String(args.widgetParameter || "").trim();
const LOCATION_KEY = "RainETAWidget:lastLocation";
const REFRESH_MINUTES = 10;
const FALLBACK_CITY = null; // No inventar que Madrid es la ubicación del usuario

function parsePosition(param) {
  const found=param.match(/^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)(?:\s*\|\s*(.+))?$/);
  if (!found) return null;
  const lat=Number(found[1]),lon=Number(found[2]);
  if(Math.abs(lat)>90||Math.abs(lon)>180)return null;
  return{lat,lon,name:(found[3]||"Lugar seleccionado").slice(0,35)};
}
async function position(){
  if(PARAM){
    const p=parsePosition(PARAM);
    if(!p)throw Error('Parámetro: lat,lon|Ciudad');
    return p;
  }
  try {
    Location.setAccuracyToKilometer();
    const p=await Location.current();
    const loc={lat:p.latitude,lon:p.longitude,name:'Mi ubicación'};
    Keychain.set(LOCATION_KEY,JSON.stringify(loc));
    return loc;
  }catch(e){
    if(Keychain.contains(LOCATION_KEY)){
      const cached=JSON.parse(Keychain.get(LOCATION_KEY));
      if(Number.isFinite(cached.lat)&&Number.isFinite(cached.lon))return {...cached,name:"Última ubicación"};
    }
    if(FALLBACK_CITY)return FALLBACK_CITY;
    throw Error('Permite ubicación en Scriptable o fija lat,lon en el widget');
  }
}
async function getJson(url){
  const request=new Request(url);request.timeoutInterval=12;
  return await request.loadJSON();
}
function forecastFallback(d,now){
  const t=d.minutely_15?.time||[],p=d.minutely_15?.precipitation||[];
  const current=d.current||{};
  const wet=Number(current.precipitation)>=.08 || Number(current.rain)>=.08 || Number(current.showers)>=.08;
  const rows=t.map((s,i)=>({ms:Number(s)*1000,wet:Number(p[i])>=.08}))
    .filter(r=>Number.isFinite(r.ms)&&r.ms>=now-15*60000&&r.ms<=now+4*3600000);
  let target=null,action='none';
  if(wet){
    for(let i=0;i<rows.length-1;i++)
      if(rows[i].ms>now&&!rows[i].wet&&!rows[i+1].wet){target=rows[i].ms;action='stops';break}
  }else{
    for(let i=0;i<rows.length-1;i++)
      if(rows[i].ms>now&&rows[i].wet&&rows[i+1].wet){target=rows[i].ms;action='starts';break}
  }
  return{ok:rows.length>0,phase:wet?'raining':'dry',action,
    targetAt:target?new Date(target).toISOString():null,
    precisionMinutes:30,confidence:'baja',summary:wet?'Llueve; fin incierto':'Sin lluvia próxima confirmada',
    caveat:'Modelo interpolado; sin radar',sources:['Open-Meteo'],generatedAt:new Date(now).toISOString()};
}
async function rainForecast(pos){
  const coords='lat='+encodeURIComponent(pos.lat.toFixed(3))+'&lon='+encodeURIComponent(pos.lon.toFixed(3));
  const origin=(RAINETA_PREVIEW||RAINETA_BASE).replace(/\/$/,'');
  try {
    const d=await getJson(origin+'/api/rain-widget?'+coords);
    if(d.ok)return d;
  }catch(_) { /* Fall back only while RainETA endpoint is not published/unavailable */ }
  const q='latitude='+encodeURIComponent(pos.lat)+'&longitude='+encodeURIComponent(pos.lon)+
    '&current=precipitation,rain,showers&minutely_15=precipitation&forecast_minutely_15=20&timeformat=unixtime&timezone=GMT';
  const forecast=await getJson('https://api.open-meteo.com/v1/forecast?'+q);
  return forecastFallback(forecast,Date.now());
}
const widget=new ListWidget();
widget.backgroundColor=new Color('#0a2032');
widget.setPadding(14,14,13,14);
widget.url=(RAINETA_PREVIEW||RAINETA_BASE).replace(/\/$/,'')+'/rain/widget/';
function label(text,size,color,bold=false){
  const t=widget.addText(text);
  t.font=bold?Font.boldSystemFont(size):Font.systemFont(size);
  t.textColor=new Color(color);t.lineLimit=2;return t;
}
label('RainETA  ·  CUENTA ATRÁS',11,'#85cbee',true);
widget.addSpacer(7);
try{
  const loc=await position();
  const d=await rainForecast(loc);
  label(loc.name,11,'#b9d3e1');
  widget.addSpacer(9);
  const when=d.targetAt?new Date(d.targetAt):null;
  const upcoming=when&&Number.isFinite(when.getTime())&&when.getTime()>Date.now()&&d.action!=='none';
  if(upcoming){
    label(d.action==='starts'?'EMPIEZA A LLOVER EN':'DEJA DE LLOVER EN',10,'#e3f3fd',true);
    const countdown=widget.addDate(when);
    countdown.applyTimerStyle();
    countdown.font=Font.boldSystemFont(33);
    countdown.textColor=new Color('#ffffff');
    countdown.lineLimit=1;countdown.minimumScaleFactor=.5;
    widget.addSpacer(5);
    label('±'+(d.precisionMinutes||30)+' min · '+(d.confidence==='media'?'Confianza media':'Confianza baja'),10,'#b5d1e0');
    const refreshMs=Math.max(60000,Math.min(REFRESH_MINUTES*60000,when.getTime()-Date.now()+1000));
    widget.refreshAfterDate=new Date(Date.now()+refreshMs);
  }else{
    label(d.phase==='raining'?'LLUEVE AHORA':'SIN LLUVIA INMINENTE',16,'#ffffff',true);
    widget.addSpacer(6);
    label(d.summary||'Sin evento confirmado',11,'#b5d1e0');
    widget.refreshAfterDate=new Date(Date.now()+REFRESH_MINUTES*60000);
  }
  widget.addSpacer();
  label((d.sources||[]).join(' + ')+' · previsión orientativa',9,'#83a3b8');
}catch(e){
  widget.addSpacer(12);
  label('Sin datos meteorológicos',15,'#ffffff',true);
  widget.addSpacer(7);
  label(String(e.message||e).slice(0,120),10,'#bfd6e3');
  widget.refreshAfterDate=new Date(Date.now()+REFRESH_MINUTES*60000);
}
Script.setWidget(widget);
if(!config.runsInWidget)await widget.presentSmall();
Script.complete();
