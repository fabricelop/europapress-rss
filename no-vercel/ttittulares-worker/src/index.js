// TTiTTulares: Cloudflare Worker adapter for the ORIGINAL editorial handlers.
// Generated handler files are copied from production sources at build time.
// No secrets are exposed to the browser. No Vercel requests are performed here.
import controlHandler from "../generated/lib/ttittulares-control-handler.js";
import runHandler from "../generated/lib/ttittulares-run-handler.js";
import statusHandler from "../generated/lib/ttittulares-run-status-handler.js";

const MAX_BODY_BYTES = 5*1024*1024;
// No Telegram webhook here: the shared tt-control Worker remains independent.
const ROUTES = {
  "/api/ttittulares-control": controlHandler,
  "/api/ttittulares-run": runHandler,
  "/api/ttittulares-run-status": statusHandler
};
function json(value,status=200,headers={}) {
  return new Response(JSON.stringify(value),{status,headers:{"content-type":"application/json; charset=utf-8","cache-control":"no-store","x-content-type-options":"nosniff",...headers}});
}
function configureRuntime(env) {
  // GITHUB_TOKEN and optional control token are encrypted Worker secrets.
  // process.env is provided by Cloudflare nodejs_compat, NOT shipped to assets.
  for(const key of ["GITHUB_TOKEN","GITHUB_REPO","GITHUB_BRANCH","TTITTULARES_CONTROL_TOKEN"]){
    if(typeof env[key]==="string"&&env[key])process.env[key]=env[key];
  }
  if(!process.env.GITHUB_REPO)process.env.GITHUB_REPO="fabricelop/europapress-rss";
  if(!process.env.GITHUB_BRANCH)process.env.GITHUB_BRANCH="main";
  // Legacy code has a preview-specific authentication bypass; always enforce production.
  process.env.VERCEL_ENV="production";
}
function responseAdapter() {
  let code=200,answer=null;
  const headers=new Headers({"x-content-type-options":"nosniff"});
  const res={
    setHeader(name,value){headers.set(String(name),String(value));return res},
    getHeader(name){return headers.get(String(name))},
    status(value){code=Number(value)||200;return res},
    json(data){
      headers.set("content-type","application/json; charset=utf-8");
      answer=new Response(JSON.stringify(data),{status:code,headers});
      return answer;
    },
    send(data){
      if(!headers.has("content-type"))headers.set("content-type","application/octet-stream");
      answer=new Response(data??null,{status:code,headers});
      return answer;
    },
    end(data){answer=new Response(data??null,{status:code,headers});return answer},
    redirect(statusOrUrl,target){
      const status=typeof statusOrUrl==="number"?statusOrUrl:302;
      const location=typeof statusOrUrl==="string"?statusOrUrl:target;
      headers.set("location",location);
      answer=new Response(null,{status,headers});return answer;
    }
  };
  return {res,get response(){return answer}};
}
async function handlerRequest(request, env, url,handler) {
  configureRuntime(env);
  const headers=Object.fromEntries(request.headers.entries());
  const query=Object.fromEntries(url.searchParams.entries());
  const len=Number(request.headers.get("content-length")||0);
  if(len>MAX_BODY_BYTES)return json({ok:false,error:"Carga demasiado grande"},413);
  let body={};
  if(!["GET","HEAD"].includes(request.method)){
    const t=await request.text();
    if(t.length>MAX_BODY_BYTES)return json({ok:false,error:"Carga demasiado grande"},413);
    if(t){
      try{body=JSON.parse(t)}
      catch{return json({ok:false,error:"JSON inválido"},400)}
      if(!body||Array.isArray(body)||typeof body!=="object")return json({ok:false,error:"JSON inválido"},400);
    }
  }
  const req={method:request.method,body,headers,query,url:url.pathname+url.search};
  const adapter=responseAdapter();
  try {
    const result=await handler(req,adapter.res);
    return result instanceof Response ? result : (adapter.response||json({ok:false,error:"Respuesta del controlador ausente"},502));
  }catch(e){
    console.error("TTiTTulares handler error",url.pathname,String(e?.message||e));
    return json({ok:false,error:"No se pudo completar la operación"},503);
  }
}
// TEMPORARY staging-only write probe. Must be removed before a production merge.
async function stagingWriteProbe(request,env){
  if(request.method!=="POST")return json({ok:false,error:"Método no permitido"},405);
  const token=String(env.TTITTULARES_CONTROL_TOKEN||"");
  const supplied=String(request.headers.get("authorization")||"");
  if(!token||supplied!=="Bearer "+token)return json({ok:false,error:"No autorizado"},401);
  if(!env.GITHUB_TOKEN)return json({ok:false,error:"GitHub no configurado"},503);
  const repo="fabricelop/europapress-rss";
  const branch="control/ttittulares-cloudflare-probe";
  const path="ttittulares/cloudflare-staging-probe.json";
  const url="https://api.github.com/repos/"+repo+"/contents/"+path;
  const headers={
    "accept":"application/vnd.github+json",
    "authorization":"Bearer "+env.GITHUB_TOKEN,
    "x-github-api-version":"2022-11-28",
    "user-agent":"ttittulares-cloudflare-staging-probe",
    "content-type":"application/json"
  };
  const previous=await fetch(url+"?ref="+encodeURIComponent(branch),{headers,cache:"no-store"});
  if(!previous.ok&&previous.status!==404)return json({ok:false,phase:"read",github_status:previous.status},503);
  const old=previous.ok?await previous.json():{};
  const content=JSON.stringify({ok:true,project:"TTiTTulares",source:"cloudflare_staging",checked_at:new Date().toISOString()},null,2)+"\n";
  const update={branch,message:"TTiTTulares: verificar escritura Cloudflare staging",content:Buffer.from(content).toString("base64")};
  if(old.sha)update.sha=old.sha;
  const saved=await fetch(url,{method:"PUT",headers,body:JSON.stringify(update)});
  if(!saved.ok)return json({ok:false,phase:"write",github_status:saved.status},503);
  const answer=await saved.json();
  return json({ok:true,phase:"persisted",branch,path,commit_sha:answer.commit?.sha||null});
}

export default {
  async fetch(request,env){
    const url=new URL(request.url),path=url.pathname.replace(/\/+$/,"")||"/";
    if(path==="/health")return json({ok:true,service:"ttittulares-cloudflare",mode:"legacy-handlers"});
    if(path==="/api/ttittulares-staging-write-test")return stagingWriteProbe(request,env);
    if(Object.prototype.hasOwnProperty.call(ROUTES,path)){
      return handlerRequest(request,env,url,ROUTES[path]);
    }
    if(path==="/")return Response.redirect(url.origin+"/ttittulares/",302);
    if(env.ASSETS&&["GET","HEAD"].includes(request.method))return env.ASSETS.fetch(request);
    return json({ok:false,error:"No encontrado"},404);
  }
};
export {handlerRequest,responseAdapter};
