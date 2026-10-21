import { TARGETS } from './catalog.mjs';
const ROOT='https://api.github.com/repos/fabricelop/europapress-rss/contents/';
const stale=(at,minutes,now=Date.now())=>{const t=Date.parse(at||'');return Number.isNaN(t)?null:(now-t)>minutes*60*1000;};
const age=(at,now=Date.now())=>{const t=Date.parse(at||'');return Number.isNaN(t)?null:Math.max(0,Math.round((now-t)/60000));};
function summary(status,message,more={}){return {status,message,...more};}
export function analyze(sources,now=Date.now()){
  const tt=sources.ttStatus, tq=sources.ttQueue, tr=sources.trRecent, rq=sources.trQueue, sl=sources.slrRequests, ss=sources.slrState;
  const data={};
  const missing=(x)=>x===null||x===undefined;
  if(missing(tt))data.ttRadar=summary('unknown','No se pudo leer el estado del radar');
  else {
    const a=age(tt.radar_at,now),isStale=stale(tt.radar_at,25,now);
    data.ttRadar=summary(isStale===null?'unknown':isStale?'warning':'ok',a===null?'Sin marca de tiempo':`Última captación hace ${a} min`,{at:tt.radar_at});
  }
  if(missing(tq))data.ttEditorial=summary('unknown','No se pudo leer la cola editorial');
  else {
    const pending=(tq.items||[]).filter(x=>['processing','rewrite_pending','preparing','update'].includes(String(x.status||'').toLowerCase())||x.rewrite_pending===true);
    const overdue=pending.filter(x=>stale(x.selected_at||x.requested_at||x.started_at,65,now)===true);
    data.ttEditorial=summary(overdue.length?'warning':'ok',`${pending.length} pendientes · ${overdue.length} >65 min`,{pending:pending.length,overdue:overdue.length});
  }
  data.ttImages=missing(tt)?summary('unknown','Sin estado de Listas'):summary((tt.problematic_count||0)>0?'warning':'ok',`${tt.ready_count||0} en Listas · ${tt.problematic_count||0} problemáticas`,{ready:tt.ready_count||0,problematic:tt.problematic_count||0});
  if(missing(tr))data.trRadar=summary('unknown','No se pudo leer Top 30');
  else {
    const a=age(tr.captured_at,now),isStale=stale(tr.captured_at,30,now);
    data.trRadar=summary(isStale===null?'unknown':isStale?'warning':'ok',a===null?'Sin fecha de captura':`Top 30 capturado hace ${a} min`,{at:tr.captured_at});
  }
  if(missing(rq))data.trEditorial=summary('unknown','Sin acceso a cola editorial');
  else {
    const pending=(rq.items||[]).filter(x=>['preparing','update'].includes(String(x.status||'').toLowerCase()));
    const overdue=pending.filter(x=>stale(x.requested_at,65,now)===true);
    data.trEditorial=summary(overdue.length?'warning':'ok',`${pending.length} pendientes · ${overdue.length} >65 min`,{pending:pending.length,overdue:overdue.length});
  }
  data.trImages=missing(rq)?summary('unknown','No hay datos visuales concluyentes'):summary('unknown','La cola editorial no permite confirmar entrega IA; usar reparación y verificar jobs');
  if(missing(sl)||missing(ss))data.slrEditorial=summary('unknown','Estado editorial de SeLoRecordamos no disponible');
  else {
    const processed=new Set(ss.processed||[]);
    const pend=(sl.requests||[]).filter(x=>!processed.has(x.type==='evaluate'?`evaluate:${x.tweet_id}`:`telegram_instruction:${x.telegram_update_id}`));
    data.slrEditorial=summary(pend.length?'warning':'ok',`${pend.length} solicitudes sin marcar como procesadas`,{pending:pend.length});
  }
  return data;
}
export async function gatherState(env,fetcher=fetch){
  const paths={ttStatus:'ttittulares/status.json',ttQueue:'ttittulares/editorial-queue.json',trRecent:'trends/recent.json',trQueue:'trends/editorial-queue.json',slrRequests:'selorecordamos/requests.json',slrState:'selorecordamos/assistant-state.json'};
  const healthPromise=(async()=>{
    try{
      const r=await fetcher('https://ttactualidad-decisions-pilot.fabricelop.workers.dev/health',{signal:AbortSignal.timeout(6500)});
      if(!r.ok)return {check:summary('warning',`Servicio HTTP ${r.status}`)};
      const doc=await r.json();const ok=doc.ok===true&&doc.production_connected===true;
      return {check:summary(ok?'ok':'warning',ok?`API disponible · ${String(doc.version||'versión desconocida')}`:'API responde pero su estado no es correcto')};
    }catch(e){return {check:summary('unknown','No se ha podido conectar con TTActualidad'),error:String(e.message).slice(0,100)};}
  })();
  const records=await Promise.all(Object.entries(paths).map(async ([key,path])=>{
    try {
      const res=await fetcher(ROOT+path+'?ref=main',{headers:{Authorization:`Bearer ${env.GITHUB_TOKEN}`,'Accept':'application/vnd.github.raw+json','X-GitHub-Api-Version':'2022-11-28','User-Agent':'Centro-Reparaciones'},signal:AbortSignal.timeout(8000)});
      if(!res.ok)return [key,null,`HTTP ${res.status}`];
      const body=await res.json();
      return [key,body,null];
    }catch(e){return [key,null,String(e.message).slice(0,100)];}
  }));

  const files=Object.fromEntries(records.map(x=>[x[0],x[1]]));
  const errors=records.filter(x=>x[2]).map(x=>({source:x[0],error:x[2]}));
  const checks=analyze(files);
  const health=await healthPromise;checks.ttWebsite=health.check;
  if(health.error)errors.push({source:'ttactualidadHealth',error:health.error});
  return {at:new Date().toISOString(),checks,errors};
}
