// Read-only diagnostic for PUBLIC HTTP routes. No credentials, no POST requests.
const routes=[
 ["telegram-control-version","https://tt-control.fabricelop.workers.dev/api/ttittulares-webhook-version"],
 ["telegram-control-webhook-get","https://tt-control.fabricelop.workers.dev/api/telegram-webhook"],
 ["telegram-control-callback-get","https://tt-control.fabricelop.workers.dev/api/ttittulares-telegram-callback"],
 ["tti-worker-pipeline","https://ttittulares-no-vercel-test.fabricelop.workers.dev/api/ttittulares-telegram-pipeline-version"],
 ["tti-worker-health","https://ttittulares-no-vercel-test.fabricelop.workers.dev/health"],
 ["ttendencias-worker-health","https://ttendencias-no-vercel-test.fabricelop.workers.dev/health"],
 ["instagram-publisher-health","https://tt-actualidad-instagram-pilot.fabricelop.workers.dev/health"]
];
for(const [name,url] of routes){
  const entry={probe:name};
  try {
    const r=await fetch(url,{method:"GET",redirect:"manual",signal:AbortSignal.timeout(12000),headers:{accept:"application/json"}});
    entry.http=r.status;
    entry.content_type=String(r.headers.get("content-type")||"").split(";")[0].slice(0,55);
    if(entry.content_type==="application/json"){
      const data=await r.json().catch(()=>({}));
      for(const k of ["service","mode","version","error","ok","active"])if(["string","number","boolean"].includes(typeof data?.[k]))entry[k]=String(data[k]).slice(0,70);
    }
  }catch(err){entry.network_error=String(err?.name||"Error").slice(0,65);}
  console.log("TT_ACTUALIDAD_PUBLIC_ROUTE",JSON.stringify(entry));
}
