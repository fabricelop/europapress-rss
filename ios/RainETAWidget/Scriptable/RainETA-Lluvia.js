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

async function freshOrCache(pos){
  try{
    const value=await rainForecast(pos);
    if(!value.ok)throw Error('Previsión incompleta');
    try{Keychain.set(CACHE_KEY,JSON.stringify({lat:pos.lat,lon:pos.lon,value}))}catch(_){}
    return value;
  }catch(error){
    try{
      if(Keychain.contains(CACHE_KEY)){
        const saved=JSON.parse(Keychain.get(CACHE_KEY));
        const age=Date.now()-Number(saved.value?.updatedAt||0);
        if(Math.abs(saved.lat-pos.lat)<0.02&&Math.abs(saved.lon-pos.lon)<0.02&&age>=0&&age<60*60000)
          return {...saved.value,fromCache:true};
      }
    }catch(_){}
    throw error;
  }
}
const widget=new ListWidget();
widget.backgroundColor=new Color('#0a2032');
widget.setPadding(SMALL?13:8,SMALL?12:8,SMALL?12:8,SMALL?12:8);
widget.spacing=0;
function label(str,size,color,bold=false){
  const t=widget.addText(str);
  t.font=bold?Font.boldSystemFont(size):Font.systemFont(size);
  t.textColor=new Color(color);t.lineLimit=2;
  return t;
}
try{
  const place=await position();
  const d=await freshOrCache(place);
  const now=Date.now(),ageMin=Math.max(0,Math.floor((now-d.updatedAt)/60000));
  label('RainETA  ·  '+place.name,SMALL?11:12,'#89d2f6',true);
  widget.addSpacer(SMALL?8:2);
  const target=d.targetAt?new Date(d.targetAt):null;
  const upcoming=target&&Number.isFinite(target.getTime())&&target.getTime()>now&&d.action!=='none';
  const stale=d.fromCache&&ageMin>30;
  if(stale){
    label('Datos guardados antiguos',SMALL?12:16,'#ffd09b',true);
    if(SMALL)label('Sin ETA fiable',11,'#c9e0ed');
  }else if(upcoming){
    if(SMALL){
      label(d.action==='starts'?'EMPIEZA EN':'TERMINA EN',10,'#c6e5f5',true);
      const timer=widget.addDate(target);
      timer.applyTimerStyle();
      timer.font=Font.boldSystemFont(31);
      timer.textColor=new Color('#ffffff');
      timer.lineLimit=1;timer.minimumScaleFactor=.5;
      label('±'+(d.precisionMinutes||30)+' min · estimación',9,'#a2c6db');
    }else{
      const stack=widget.addStack();
      stack.layoutHorizontally();stack.centerAlignContent();
      const prefix=stack.addText(d.action==='starts'?'Empieza en ':'Termina en ');
      prefix.font=Font.systemFont(13);prefix.textColor=new Color('#dceffa');
      const timer=stack.addDate(target);timer.applyTimerStyle();
      timer.font=Font.boldSystemFont(LARGE?29:23);
      timer.textColor=new Color('#ffffff');
      timer.lineLimit=1;timer.minimumScaleFactor=.6;
    }
    if(LARGE)label('Hora estimada '+hhmm(target.getTime())+' · margen ±'+(d.precisionMinutes||30)+' min',10,'#a9cedf');
  }else{
    label(d.phase==='raining'?'Llueve; fin incierto':'Sin lluvia inminente',SMALL?16:18,'#ffffff',true);
    if(SMALL)label(d.summary,10,'#b3ccda');
  }
  if(!SMALL){
    widget.addSpacer(LARGE?12:3);
    label('PRÓXIMAS 12 H · % PROB. / LLUVIA MM/H',LARGE?11:9,'#b6d6ec',true);
    widget.addSpacer(2);
    const hours=Array.isArray(d.hours)?d.hours:[];
    if(hours.length){
      const chart=widget.addImage(drawRainBars(hours,LARGE));
      const width=LARGE?312:300;
      chart.imageSize=new Size(width,width*(LARGE?252:210)/720);
      chart.centerAlignImage();chart.applyFittingContentMode();
      if(LARGE){
        widget.addSpacer(9);
        label('CADA BARRA: hora inferior · % superior · lluvia mm/h intermedia',10,'#b2ccdc');
        label('Celeste: débil  Azul: moderada  Violeta: fuerte  Coral: intensa',10,'#b2ccdc');
      }
    }else{
      label('Probabilidad horaria no disponible',11,'#ffd09b');
    }
  }
  widget.addSpacer();
  const updateText=(d.fromCache?'Guardado ':'Actualizado ')+hhmm(d.updatedAt);
  label(updateText+' · '+(SMALL?'12 h: widget mediano':'Open-Meteo (modelo)'),9,'#8eafc4');
  widget.refreshAfterDate=new Date(now+(d.fromCache?5:REFRESH_MINUTES)*60000);
}catch(error){
  widget.addSpacer(9);
  label('No se pudo actualizar',15,'#ffffff',true);
  widget.addSpacer(5);
  label(String(error.message||error).slice(0,116),10,'#c6dce8');
  widget.refreshAfterDate=new Date(Date.now()+5*60000);
}
Script.setWidget(widget);
if(!config.runsInWidget){
  if(LARGE)await widget.presentLarge();
  else await widget.presentMedium();
}
Script.complete();
