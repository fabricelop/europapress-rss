// RainETA — widget de lluvia para Scriptable (iPhone).
// Parámetro del widget: "Madrid", "Sevilla, España" o "40.4168,-3.7038|Madrid".
// Vacío = GPS actual. Consulta Open-Meteo directamente; no usa Vercel.
// En Iberia, los pasos de 15 min pueden estar interpolados de modelos horarios.
const PARAM = String(args.widgetParameter || "").trim();
const LOCATION_KEY = "RainETAWidget:lastLocation";
const REFRESH_MINUTES = 10;
const FALLBACK_CITY = null; // No inventar que Madrid es la ubicación del usuario
const CACHE_KEY = 'RainETAWidget:lastForecast:v3';
const FAMILY = String(config.widgetFamily||'medium');
const SMALL = FAMILY==='small'||FAMILY.startsWith('accessory');
const LARGE = FAMILY==='large'||FAMILY==='extraLarge';

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
    if(p)return p;
    return await geocodeCity(PARAM);
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
async function geocodeCity(name){
  const query=name.trim().slice(0,80);
  if(query.length<2)throw Error('Escribe una ciudad, por ejemplo Madrid');
  const key='RainETAWidget:city:'+query.toLocaleLowerCase('es');
  try{
    if(Keychain.contains(key)){
      const saved=JSON.parse(Keychain.get(key));
      if(Date.now()-saved.cachedAt<7*24*3600000 && Number.isFinite(saved.lat) && Number.isFinite(saved.lon))
        return {lat:saved.lat,lon:saved.lon,name:saved.name};
    }
  }catch(_){}
  const url='https://geocoding-api.open-meteo.com/v1/search?'+
    'name='+encodeURIComponent(query)+'&count=5&language=es&format=json';
  const data=await getJson(url);
  const candidates=Array.isArray(data.results)?data.results:[];
  if(!candidates.length)throw Error('No se encuentra "'+query+'". Prueba "Ciudad, País"');
  const city=candidates[0];
  const label=[city.name,city.admin1&&city.admin1!==city.name?city.admin1:null]
    .filter(Boolean).join(', ').slice(0,36);
  const result={lat:Number(city.latitude),lon:Number(city.longitude),name:label};
  if(!Number.isFinite(result.lat)||!Number.isFinite(result.lon))throw Error('Ubicación sin coordenadas');
  Keychain.set(key,JSON.stringify({...result,cachedAt:Date.now()}));
  return result;
}

function hourlyRainRows(data, nowMs) {
  const h=(data||{}).hourly||{};
  const times=Array.isArray(h.time)?h.time:[];
  const probs=h.precipitation_probability||[];
  const rains=h.rain||[], showers=h.showers||[], totals=h.precipitation||[];
  const rows=[];
  for(let i=0;i<times.length;i++){
    // Hourly precipitation is the accumulated rain in the preceding hour.
    const end=Number(times[i])*1000;
    if(!Number.isFinite(end)||end<=nowMs)continue;
    const r=rains[i]==null?NaN:Number(rains[i]);
    const s=showers[i]==null?NaN:Number(showers[i]);
    const t=totals[i]==null?NaN:Number(totals[i]);
    const amount=Number.isFinite(r)&&Number.isFinite(s)?r+s:t;
    const p=probs[i]==null?NaN:Number(probs[i]);
    rows.push({
      start:end-3600000,end,
      probability:Number.isFinite(p)?Math.max(0,Math.min(100,Math.round(p))):null,
      mm:Number.isFinite(amount)?Math.max(0,Math.round(amount*10)/10):null
    });
    if(rows.length>=12)break;
  }
  return rows;
}
function hhmm(ms){
  const date=new Date(ms);
  return String(date.getHours()).padStart(2,'0')+':'+String(date.getMinutes()).padStart(2,'0');
}
function rainColor(mm){
  if(mm==null)return '#637e91';
  if(mm<0.1)return '#3b5262';
  if(mm<0.5)return '#62caee';
  if(mm<2.5)return '#328dff';
  if(mm<7.5)return '#8b6aff';
  return '#ff796c';
}
function drawRainBars(rows,large){
  const W=720,H=large?252:210;
  const ctx=new DrawContext();
  ctx.size=new Size(W,H);
  ctx.opaque=false;
  const baseline=large?166:135,barMax=large?118:85;
  const cell=W/12;
  function write(str,x,y,w,size,color,bold){
    ctx.setTextAlignedCenter();
    ctx.setFont(bold?Font.boldSystemFont(size):Font.systemFont(size));
    ctx.setTextColor(new Color(color));
    ctx.drawTextInRect(str,new Rect(x,y,w,29));
  }
  ctx.setFillColor(new Color('#38536a'));
  ctx.fillRect(new Rect(0,baseline,W,2));
  for(let i=0;i<12;i++){
    const row=rows[i],x=i*cell+3,w=cell-6;
    if(!row)continue;
    write(row.probability==null?'—':String(row.probability)+'%',x,4,w,20,'#e3f2fc',true);
    const mm=row.mm;
    const barHeight=mm==null?2:mm<0.1?3:Math.min(barMax,Math.max(9,12+29*Math.sqrt(mm)));
    ctx.setFillColor(new Color(rainColor(mm)));
    ctx.fillRect(new Rect(x+9,baseline-barHeight,w-18,barHeight));
    write(mm==null?'—':mm.toFixed(1).replace('.',','),x,baseline+8,w,20,'#d0e3f0',true);
    write(String(new Date(row.start).getHours()).padStart(2,'0'),x,baseline+38,w,20,'#9ec2d7',false);
  }
  return ctx.getImage();
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
    caveat:'Modelo interpolado; sin radar',sources:['Open-Meteo'],generatedAt:new Date(now).toISOString(),hours:hourlyRainRows(d,now),updatedAt:now,fromCache:false};
}
async function rainForecast(pos){
  const q='latitude='+encodeURIComponent(pos.lat)+'&longitude='+encodeURIComponent(pos.lon)+
    '&current=precipitation,rain,showers&minutely_15=precipitation&forecast_minutely_15=20&hourly=precipitation_probability,rain,showers,precipitation&forecast_hours=16&timeformat=unixtime&timezone=GMT';
  const forecast=await getJson('https://api.open-meteo.com/v1/forecast?'+q);
  return forecastFallback(forecast,Date.now());
}
const widget=new ListWidget();
widget.backgroundColor=new Color('#0a2032');
widget.setPadding(14,14,13,14);
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
  label('Open-Meteo · previsión orientativa',9,'#83a3b8');
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
