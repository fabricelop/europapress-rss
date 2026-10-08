// TTiTTulares: Cloudflare Worker adapter for the ORIGINAL editorial handlers.
// Generated handler files are copied from production sources at build time.
// No secrets are exposed to the browser. No Vercel requests are performed here.
import controlHandler from "../generated/lib/ttittulares-control-handler.js";
import runHandler from "../generated/lib/ttittulares-run-handler.js";
import statusHandler from "../generated/lib/ttittulares-run-status-handler.js";

const MAX_BODY_BYTES = 5*1024*1024;
// TT Control forwards only tt:p and tt:d callbacks through its internal service binding.
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
// Telegram callbacks for TTiTTulares are ingested here because this Worker
// already has the scoped GitHub write credential. The Telegram bot credential
// stays in GitHub Actions. Never trust callback data until Telegram confirms
// callback_query_id in the consumer workflow.
const TT_CALLBACK_INBOX="telegram/ttittulares-callback-inbox.json";
function parseTtiCallback(update){
  const cq=update?.callback_query;
  const data=String(cq?.data||"");
  const match=data.match(/^tt:([pd]):([a-zA-Z0-9_-]{5,64})$/);
  const uid=Number(update?.update_id);
  const mid=Number(cq?.message?.message_id);
  const chat=String(cq?.message?.chat?.id||"");
  const qid=String(cq?.id||"");
  if(!match||!Number.isSafeInteger(uid)||uid<=0||
     !Number.isSafeInteger(mid)||mid<=0||
     !/^-?[0-9]{3,20}$/.test(chat)||
     !/^[a-zA-Z0-9_-]{6,128}$/.test(qid))return null;
  return {update_id:uid,type:"emergency_action",text:(match[1]==="p"?"ttp":"ttd")+"|"+match[2],
    callback_query_id:qid,chat_id:chat,message_id:mid,
    source:"ttittulares_cloudflare_callback_v1",received_at:new Date().toISOString()};
}
async function enqueueTtiTelegramCallback(request,env){
  if(request.method!=="POST")return json({ok:false,error:"Method Not Allowed"},405);
  const raw=await request.text();
  if(raw.length>20000)return json({ok:false,error:"Update too large"},413);
  let update;
  try{update=JSON.parse(raw)}catch{return json({ok:false,error:"Invalid JSON"},400)}
  const event=parseTtiCallback(update);
  if(!event)return json({ok:true,ignored:true});
  if(!env.GITHUB_TOKEN)return json({ok:false,error:"Callback routing unavailable"},503);
  const api="https://api.github.com/repos/fabricelop/europapress-rss/contents/"+TT_CALLBACK_INBOX;
  const h={"accept":"application/vnd.github+json","authorization":"Bearer "+env.GITHUB_TOKEN,
    "x-github-api-version":"2022-11-28","user-agent":"ttittulares-telegram-callback-v1",
    "content-type":"application/json"};
  for(let n=0;n<5;n++){
    const r=await fetch(api+"?ref=main",{headers:h,cache:"no-store"});
    if(!r.ok&&r.status!==404)return json({ok:false,phase:"read",status:r.status},503);
    const existing=r.ok?await r.json():null;
    let state={version:1,requests:[]};
    if(existing?.content){
      try{state=JSON.parse(Buffer.from(existing.content.replace(/\s/g,""),"base64").toString("utf8"))}
      catch{return json({ok:false,error:"Callback inbox invalid"},503)}
    }
    const list=Array.isArray(state.requests)?state.requests:[];
    if(list.some(x=>Number(x.update_id)===event.update_id))return json({ok:true,queued:true,duplicate:true});
    const updated={version:1,updated_at:new Date().toISOString(),requests:[...list,event].slice(-350)};
    const payload={message:"Recibir callback Telegram TTiTTulares "+event.update_id,
      branch:"main",content:Buffer.from(JSON.stringify(updated,null,2)+"\n","utf8").toString("base64")};
    if(existing?.sha)payload.sha=existing.sha;
    const w=await fetch(api,{method:"PUT",headers:h,body:JSON.stringify(payload)});
    if(w.ok)return json({ok:true,queued:true,update_id:event.update_id});
    if(![409,422].includes(w.status))return json({ok:false,phase:"write",status:w.status},503);
  }
  return json({ok:false,error:"Concurrent callback queue write"},503);
}

export default {
  async fetch(request,env){
    const url=new URL(request.url),path=url.pathname.replace(/\/+$/,"")||"/";
    if(path==="/health")return json({ok:true,service:"ttittulares-cloudflare",mode:"legacy-handlers"});
    if(path==="/api/ttittulares-telegram-callback")return enqueueTtiTelegramCallback(request,env);
    if(Object.prototype.hasOwnProperty.call(ROUTES,path)){
      return handlerRequest(request,env,url,ROUTES[path]);
    }
    if(path==="/")return Response.redirect(url.origin+"/ttittulares/",302);
    if(env.ASSETS&&["GET","HEAD"].includes(request.method))return env.ASSETS.fetch(request);
    return json({ok:false,error:"No encontrado"},404);
  }
};
export {handlerRequest,responseAdapter,parseTtiCallback};
