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


// Compare immutable, approved public assets with the currently deployed PWA.
// Purely read-only: no webhook, no Cloudflare API, no credentials, no deployment.
const {createHash}=await import("node:crypto");
const revision="3cc06e0025be8b59e8db915501569629a80fbb52";
for (const name of ["index.html","sw.js","manifest.webmanifest","icon.svg"]) {
  try{
    const prefix="vercel-webhook/ttittulares/";
    const [source,live]=await Promise.all([
      fetch("https://raw.githubusercontent.com/fabricelop/europapress-rss/"+revision+"/"+prefix+name,{signal:AbortSignal.timeout(25000)}),
      fetch("https://ttittulares-no-vercel-test.fabricelop.workers.dev/ttittulares/"+name,{signal:AbortSignal.timeout(25000)})
    ]);
    if(!source.ok||!live.ok){console.log("TTI_LIVE_ASSET_MATCH",name,"NOT_VERIFIABLE",source.status,live.status);continue;}
    const [a,b]=await Promise.all([source.arrayBuffer(),live.arrayBuffer()]);
    const sha=arr=>createHash("sha256").update(Buffer.from(arr)).digest("hex");
    console.log("TTI_LIVE_ASSET_MATCH",name,sha(a)===sha(b)?"YES":"NO","bytes",a.byteLength,b.byteLength);
  }catch(err){console.log("TTI_LIVE_ASSET_MATCH",name,"ERROR",String(err?.name||"UnknownError").slice(0,50));}
}
