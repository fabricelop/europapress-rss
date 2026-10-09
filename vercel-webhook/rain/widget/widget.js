const by=id=>document.getElementById(id);
const storageKey='raineta.loc';
let loc={name:'Madrid',lat:40.4168,lon:-3.7038};
let decision=null,lastLoaded=0,pending=null;
function validLoc(l){return l&&Number.isFinite(+l.lat)&&Number.isFinite(+l.lon)&&Math.abs(+l.lat)<=90&&Math.abs(+l.lon)<=180}
try{const stored=JSON.parse(localStorage.getItem(storageKey)||'null');if(validLoc(stored))loc=stored}catch{}
function save(place){
  loc={name:String(place.name||'Ubicación elegida'),lat:+place.lat,lon:+place.lon};
  try{localStorage.setItem(storageKey,JSON.stringify(loc))}catch{}
  by('place').textContent=loc.name;load();
}
function clock(ms){
 const secs=Math.max(0,Math.ceil(ms/1000)),h=Math.floor(secs/3600),m=Math.floor(secs%3600/60),s=secs%60;
 return h>0?h+':'+String(m).padStart(2,'0')+':'+String(s).padStart(2,'0'):String(m).padStart(2,'0')+':'+String(s).padStart(2,'0');
}
function tick(){
 if(!decision?.ok)return;
 const age=Date.now()-lastLoaded;
 if(age>30*60000){by('grade').textContent='Desactualizado';by('status').textContent='Previsión sin actualizar';by('count').textContent='--:--';return}
 const target=Date.parse(decision.targetAt||'');
 const active=Number.isFinite(target)&&target>Date.now()&&decision.action!=='none';
 by('status').textContent=active?(decision.action==='starts'?'Empieza a llover en':'Deja de llover en'):
   decision.phase==='raining'?'Está lloviendo':decision.action!=='none'?'Cambio de tiempo en revisión':'Sin llegada confirmada';
 by('count').textContent=active?clock(target-Date.now()):'—';
 by('target').textContent=active
   ? 'Alrededor de las '+new Intl.DateTimeFormat('es-ES',{hour:'2-digit',minute:'2-digit'}).format(target)+
     ' · margen aprox. ±'+decision.precisionMinutes+' min'
   : target<=Date.now()?'La hora prevista ya pasó; actualizando…':decision.summary;
 by('grade').textContent=active?(decision.confidence==='media'?'Confianza media':'Confianza baja'):'Estimación';
 by('meta').textContent='Fuente: '+(decision.sources||[]).join(' + ')+' · '+decision.caveat+
   ' · Actualizado '+new Intl.DateTimeFormat('es-ES',{hour:'2-digit',minute:'2-digit'}).format(Date.parse(decision.generatedAt));
 if(target<=Date.now()&&decision.action!=='none'&&!pending&&age>20000)load();
}
async function load(){
 if(pending)pending.abort();
 const controller=new AbortController();pending=controller;
 by('place').textContent=loc.name;
 by('notice').textContent='Actualizando señales meteorológicas…';
 try{
  const p=new URLSearchParams({lat:String(loc.lat),lon:String(loc.lon)});
  const response=await fetch('/api/rain-widget?'+p,{signal:controller.signal,cache:'no-store'});
  const data=await response.json();
  if(!response.ok||!data.ok)throw Error(data.error||'Sin datos');
  decision=data;lastLoaded=Date.now();by('notice').textContent='';tick();
 }catch(error){
  if(error.name==='AbortError')return;
  by('notice').textContent='La actualización falló: '+error.message+'. Puedes reintentarlo.';
  if(!decision){by('status').textContent='Datos no disponibles';by('count').textContent='--:--'}
 }finally{if(pending===controller)pending=null}
}
by('here').addEventListener('click',()=>{
 if(!navigator.geolocation){by('notice').textContent='Este navegador no permite ubicación';return}
 by('notice').textContent='Solicitando permiso de ubicación…';
 navigator.geolocation.getCurrentPosition(p=>save({name:'Mi ubicación',lat:p.coords.latitude,lon:p.coords.longitude}),
 e=>by('notice').textContent='No se pudo acceder a la ubicación: '+e.message,{enableHighAccuracy:false,timeout:13000,maximumAge:120000});
});
by('refresh').addEventListener('click',load);
async function search(){
 const name=by('city').value.trim().slice(0,80);
 if(name.length<2){by('notice').textContent='Escribe al menos dos letras';return}
 by('notice').textContent='Buscando ciudades…';by('places').replaceChildren();
 try{
  const response=await fetch('https://geocoding-api.open-meteo.com/v1/search?'+new URLSearchParams({name,count:'5',language:'es',format:'json'}));
  if(!response.ok)throw Error('Buscador temporalmente no disponible');
  const payload=await response.json();
  for(const city of payload.results||[]){
   const b=document.createElement('button');b.textContent=[city.name,city.admin1,city.country].filter(Boolean).join(' · ');
   b.addEventListener('click',()=>{by('city').value='';by('places').replaceChildren();save({name:city.name,lat:city.latitude,lon:city.longitude})});
   by('places').append(b);
  }
  by('notice').textContent=by('places').children.length?'Selecciona una ubicación':'No se encontraron lugares';
 }catch(e){by('notice').textContent=e.message}
}
by('find').addEventListener('click',search);
by('city').addEventListener('keydown',e=>{if(e.key==='Enter')search()});
by('place').textContent=loc.name;
load();
setInterval(tick,1000);
setInterval(()=>{if(document.visibilityState==='visible'&&!pending)load()},5*60000);
document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible'&&Date.now()-lastLoaded>5*60000)load()});
