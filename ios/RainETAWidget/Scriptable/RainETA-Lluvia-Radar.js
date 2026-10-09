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


// Radar observado RainViewer: one tile centered on point, no proxy/server.
// RainViewer pixel colors use Universal Blue (2); >~12 dBZ alpha >170.
// This indicates echoes aloft; it does NOT prove rain reaches the ground.
const RADAR_OBS_CACHE="RainETAWidget:radar-observed:v1:";
function radarObsLabel(obs){
  if(obs.status==="echo")return"RADAR AHORA · Eco de precipitación · "+obs.time;
  if(obs.status==="clear")return"RADAR AHORA · Sin eco detectado · "+obs.time;
  if(obs.status==="stale")return"RADAR: última imagen demasiado antigua";
  if(obs.status==="outside")return"RADAR: sin cobertura confirmada";
  return"RADAR: sin datos fiables";
}
async function radarPngSample(data){
  // Decode a real radar PNG in isolated WebKit canvas to inspect image pixels.
  // A transparent radar tile alone is ambiguous without a coverage tile.
  const web=new WebView();
  await web.loadHTML("<!doctype html><html><body></body></html>");
  const uri="data:image/png;base64,"+data.toBase64String();
  const expression="(function(){"+
    "var im=new Image();im.onload=function(){try{"+
    "var c=document.createElement('canvas');c.width=im.width;c.height=im.height;"+
    "var context=c.getContext('2d',{willReadFrequently:true});context.drawImage(im,0,0);"+
    "var a=context.getImageData(0,0,c.width,c.height).data;"+
    "var cx=Math.floor(c.width/2),cy=Math.floor(c.height/2),strong=0,transparent=0,n=0;"+
    "for(var y=cy-4;y<=cy+4;y++)for(var x=cx-4;x<=cx+4;x++){"+
    "var i=(y*c.width+x)*4,alpha=a[i+3];n++;if(alpha>=180)strong++;if(alpha<=40)transparent++;}"+
    "completion({ok:true,strong:strong,transparent:transparent,total:n});"+
    "}catch(e){completion({ok:false,error:String(e)})}};"+
    "im.onerror=function(){completion({ok:false,error:'image decode'})};im.src="+JSON.stringify(uri)+";"+
    "})();";
  const value=await web.evaluateJavaScript(expression,true);
  if(!value?.ok||!Number.isFinite(value.total)||value.total<16)throw Error("radar_png_invalid");
  return value;
}
async function radarObservadoAt(place){
  const lat=Number(place.lat),lon=Number(place.lon);
  if(!Number.isFinite(lat)||!Number.isFinite(lon)||Math.abs(lat)>85||Math.abs(lon)>180)
    return{status:"outside"};
  const key=RADAR_OBS_CACHE+lat.toFixed(2)+","+lon.toFixed(2);
  try{
    if(Keychain.contains(key)){
      const recent=JSON.parse(Keychain.get(key));
      if(Date.now()-recent.checkedAt<5*60000&&Date.now()-recent.frameAt<25*60000)
        return recent;
    }
  }catch(_){}
  try{
    const req=new Request("https://api.rainviewer.com/public/weather-maps.json");
    req.timeoutInterval=9;
    const manifest=await req.loadJSON(),frames=manifest?.radar?.past||[];
    const newest=frames.filter(f=>Number.isFinite(Number(f.time))).sort((a,b)=>a.time-b.time).at(-1);
    if(!newest||!manifest?.host||!/^https:\/\/[a-z0-9.-]+\.rainviewer\.com$/i.test(manifest.host))
      return{status:"unavailable"};
    const frameAt=Number(newest.time)*1000,age=Date.now()-frameAt;
    if(age < -3*60000||age>25*60000)return{status:"stale"};
    const center=lat.toFixed(4)+"/"+lon.toFixed(4);
    const base=manifest.host.replace(/\/$/,"");
    const prefix=base+String(newest.path)+"/256/7/"+center;
    const coverageUrl=base+"/v2/coverage/0/256/7/"+center+"/0/0_0.png";
    const radarRequest=new Request(prefix+"/2/0_0.png");
    const coverageRequest=new Request(coverageUrl);
    radarRequest.timeoutInterval=12;
    coverageRequest.timeoutInterval=12;
    const blobs=await Promise.all([radarRequest.load(),coverageRequest.load()]);
    const coverage=await radarPngSample(blobs[1]);
    if(coverage.transparent/coverage.total<.7)return{status:"outside"};
    const sample=await radarPngSample(blobs[0]);
    const isEcho=sample.strong>=3;
    const value={status:isEcho?"echo":"clear",
      frameAt,checkedAt:Date.now(),time:hhmm(frameAt),
      radarPoints:sample.strong,radarTotal:sample.total};
    try{Keychain.set(key,JSON.stringify(value))}catch(_){}
    return value;
  }catch(error){
    return{status:"unavailable",error:String(error)};
  }
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
  const observationPromise=radarObservadoAt(place);
  const d=await freshOrCache(place);
  const obs=await observationPromise;
  const now=Date.now(),ageMin=Math.max(0,Math.floor((now-d.updatedAt)/60000));
  label('RainETA  ·  '+place.name,SMALL?11:12,'#89d2f6',true);
  label(radarObsLabel(obs),SMALL?9:10,
    obs.status==='echo'?'#a6e9fd':obs.status==='clear'?'#bad5e1':'#ffd09b',true);
  widget.addSpacer(SMALL?8:2);
  const target=d.targetAt?new Date(d.targetAt):null;
  const upcoming=target&&Number.isFinite(target.getTime())&&target.getTime()>now&&d.action!=='none';
  const stale=d.fromCache&&ageMin>30;
  if(stale){
    label('Datos guardados antiguos',SMALL?12:16,'#ffd09b',true);
    if(SMALL)label('Sin ETA fiable',11,'#c9e0ed');
  }else if(upcoming){
    if(SMALL){
      label(d.action==='starts'?'EMPIEZA EN':'FIN MODELO EN',10,'#c6e5f5',true);
      const timer=widget.addDate(target);
      timer.applyTimerStyle();
      timer.font=Font.boldSystemFont(31);
      timer.textColor=new Color('#ffffff');
      timer.lineLimit=1;timer.minimumScaleFactor=.5;
      label('±'+(d.precisionMinutes||30)+' min · estimación',9,'#a2c6db');
    }else{
      const stack=widget.addStack();
      stack.layoutHorizontally();stack.centerAlignContent();
      const prefix=stack.addText(d.action==='starts'?'Empieza en ':'Fin modelo en ');
      prefix.font=Font.systemFont(13);prefix.textColor=new Color('#dceffa');
      const timer=stack.addDate(target);timer.applyTimerStyle();
      timer.font=Font.boldSystemFont(LARGE?29:23);
      timer.textColor=new Color('#ffffff');
      timer.lineLimit=1;timer.minimumScaleFactor=.6;
    }
    if(LARGE)label('Hora estimada '+hhmm(target.getTime())+' · margen ±'+(d.precisionMinutes||30)+' min',10,'#a9cedf');
  }else{
    label(d.phase==='raining'?'Modelo señala lluvia':'Modelos: sin lluvia cercana',SMALL?16:18,'#ffffff',true);
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
