// TTendencias independent read-only Cloudflare Worker (phase 1).
// Never put control credentials in browser assets. Writes are deliberately disabled.
const REPO = "fabricelop/europapress-rss";
const PATHS = Object.freeze({
  recent: "trends/recent.json",
  requests: "trends/requests.json",
  explained: "trends/telegram-manual-explained.json",
  health: "trends/health-status.json",
  prepared: "trends/prepared.json",
  editorial_config: "trends/editorial-config.json",
  editorial_queue: "trends/editorial-queue.json"
});
const REQUIRED = ["recent", "requests", "explained", "health", "prepared", "editorial_config", "editorial_queue"];
const jsonHeaders = {"content-type":"application/json; charset=utf-8","cache-control":"no-store","x-content-type-options":"nosniff"};

function reply(data,status=200,extra={}) {
  return new Response(JSON.stringify(data),{status,headers:{...jsonHeaders,...extra}});
}

async function remoteJSON(path, requestFetch=fetch) {
  const url="https://raw.githubusercontent.com/"+REPO+"/main/"+path;
  const response=await requestFetch(url,{headers:{accept:"application/json"},cf:{cacheTtl:60,cacheEverything:true}});
  if(!response.ok)throw new Error(path+": GitHub HTTP "+response.status);
  // Never coerce a failed parse, an empty response, or an absent field into a valid empty queue.
  const parsed=await response.json();
  if(!parsed || typeof parsed!=="object" || Array.isArray(parsed)) throw new Error(path+": JSON inválido");
  return parsed;
}

async function stateSnapshot(requestFetch=fetch) {
  const data=await Promise.all(REQUIRED.map(key=>remoteJSON(PATHS[key],requestFetch)));
  const state=Object.fromEntries(REQUIRED.map((key,i)=>[key,data[i]]));
  if(!Array.isArray(state.recent.items) || !Array.isArray(state.recent.upcoming)
     || !Array.isArray(state.requests.requests)
     || !Array.isArray(state.explained.items)) {
    throw new Error("Estado incompatible: faltan arrays de radar, solicitudes o explicadas");
  }
  return {
    ok:true,
    service:"ttendencias-cloudflare-readonly",
    phase:"read-only-test",
    fetched_at:new Date().toISOString(),
    branch:"main",
    ...state
  };
}

export default {
  async fetch(request,env) {
    const url=new URL(request.url);
    const path=url.pathname.replace(/\/+$/,"")||"/";
    if(path==="/health") {
      if(request.method!=="GET")return reply({ok:false,error:"Método no permitido"},405,{allow:"GET"});
      return reply({ok:true,service:"ttendencias-cloudflare-readonly",phase:"read-only-test"});
    }
    if(path==="/api/ttendencias-control") {
      if(request.method!=="GET")return reply({ok:false,error:"Fase de lectura: las acciones editoriales todavía no están disponibles; el panel original no se ha sustituido"},501);
      if(url.searchParams.get("view")==="state") {
        try{return reply(await stateSnapshot(),200,{"cache-control":"public, max-age=0, s-maxage=60, stale-while-revalidate=60"});}
        catch(e){return reply({ok:false,error:"No se ha podido leer el estado íntegro de GitHub",detail:String(e.message||e).slice(0,160)},503);}
      }
      return reply({ok:true,service:"ttendencias-cloudflare-readonly",phase:"read-only-test"});
    }
    if(path==="/api/ttendencias-run" || path==="/api/ttendencias-run-status") {
      return reply({ok:false,error:"Pendiente de migración: no simular ejecuciones ni confirmaciones"},501);
    }
    if(env?.ASSETS && (request.method==="GET"||request.method==="HEAD"))return env.ASSETS.fetch(request);
    return reply({ok:false,error:"No encontrado"},404);
  }
};
export {stateSnapshot,remoteJSON};
