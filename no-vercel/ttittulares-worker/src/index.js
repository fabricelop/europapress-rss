// TTiTTulares: Cloudflare Worker adapter for the ORIGINAL editorial handlers.
// Generated handler files are copied from production sources at build time.
// No secrets are exposed to the browser. No Vercel requests are performed here.
import controlHandler from "../generated/lib/ttittulares-control-handler.js";
import runHandler from "../generated/lib/ttittulares-run-handler.js";
import statusHandler from "../generated/lib/ttittulares-run-status-handler.js";

const MAX_BODY_BYTES = 5*1024*1024;
// TT Control contains a generic tt: callback forwarder; do not modify gateway.
// Actual tt:i forwarding must still be verified after this Worker is deployed.
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
  const match=data.match(/^tt:([pdi]):([a-zA-Z0-9_-]{5,64})$/);
  const uid=Number(update?.update_id);
  const mid=Number(cq?.message?.message_id);
  const chat=String(cq?.message?.chat?.id||"");
  const qid=String(cq?.id||"");
  if(!match||!Number.isSafeInteger(uid)||uid<=0||
     !Number.isSafeInteger(mid)||mid<=0||
     !/^-?[0-9]{3,20}$/.test(chat)||
     !/^[a-zA-Z0-9_-]{6,128}$/.test(qid))return null;
  return {update_id:uid,type:match[1]==="i"?"instagram_action":"emergency_action",text:(match[1]==="p"?"ttp":match[1]==="d"?"ttd":"tti_ig")+"|"+match[2],
    callback_query_id:qid,message_id:mid,
    source:"ttittulares_cloudflare_callback_v1",received_at:new Date().toISOString()};
}
// Only the private Cloudflare secret can decrypt the bot credential.
// The source repository contains RSA-OAEP ciphertext, never bot plaintext.
let cachedBotCredential=null;
let credentialExpires=0;
async function cloudflareTelegramBotToken(env){
  const now=Date.now();
  if(cachedBotCredential&&credentialExpires>now)return cachedBotCredential;
  if(!env.TTITTULARES_CALLBACK_DECRYPT_KEY)throw new Error("Telegram callback private key missing");
  const endpoint="https://api.github.com/repos/fabricelop/europapress-rss/contents/ttittulares/secure/telegram-bot-token.enc.json?ref=main";
  const r=await fetch(endpoint,{headers:{"accept":"application/vnd.github+json",
    "authorization":"Bearer "+env.GITHUB_TOKEN,"user-agent":"ttittulares-callback-credentials-v2"},cache:"no-store"});
  if(!r.ok)throw new Error("Encrypted bot credential unavailable "+r.status);
  const item=await r.json();
  const doc=JSON.parse(Buffer.from(String(item.content||"").replace(/\s/g,""),"base64").toString("utf8"));
  if(doc.algorithm!=="RSA-OAEP-SHA256"||typeof doc.ciphertext!=="string"||doc.ciphertext.length<300)throw new Error("Invalid encrypted bot credential");
  const privateBytes=Buffer.from(String(env.TTITTULARES_CALLBACK_DECRYPT_KEY),"base64");
  const key=await crypto.subtle.importKey("pkcs8",privateBytes,{name:"RSA-OAEP",hash:"SHA-256"},false,["decrypt"]);
  const tokenBytes=await crypto.subtle.decrypt({name:"RSA-OAEP"},key,Buffer.from(doc.ciphertext,"base64"));
  const token=new TextDecoder().decode(tokenBytes);
  if(!/^\d{6,15}:[A-Za-z0-9_-]{25,}$/.test(token))throw new Error("Decrypted Telegram bot credential invalid");
  cachedBotCredential=token;
  credentialExpires=Date.now()+10*60*1000;
  return token;
}
async function verifyAndAnswerTelegramCallback(event,env){
  const token=await cloudflareTelegramBotToken(env);
  const response=await fetch("https://api.telegram.org/bot"+token+"/answerCallbackQuery",{
    method:"POST",headers:{"content-type":"application/json"},
    body:JSON.stringify({callback_query_id:event.callback_query_id,text:event.type==="instagram_action"?"Recibido. Publicando en Instagram…":"Recibido. Actualizando noticia…"})
  });
  const ack=await response.json().catch(()=>({}));
  if(!response.ok||!ack.ok)return {ok:false,status:response.status};
  return {ok:true};
}

async function telegramCryptoReady(env){
  try{
    const token=await cloudflareTelegramBotToken(env);
    const r=await fetch("https://api.telegram.org/bot"+token+"/getMe");
    const result=await r.json().catch(()=>({}));
    return json({ok:!!result.ok,telegram_callback_credential_ready:!!result.ok},result.ok?200:503);
  }catch(err){
    console.log("TTiTTulares bot credential preflight failed",String(err?.message||err));
    return json({ok:false,telegram_callback_credential_ready:false},503);
  }
}


// Close a verified TTiTTulares callback synchronously, independently of Actions.
// Always persist the inbox first; the existing workflow remains the recovery path.
function linkedTtiTelegramMessages(rows,eventId,clickedMessageId){
  const linked=(Array.isArray(rows)?rows:[]).filter(row=>String(row?.event_id||"")===eventId);
  const fields=["telegram_message_id","archive_telegram_message_id","cross_quote_message_id"];
  const ids=[...new Set(linked.flatMap(row=>fields.map(key=>Number(row?.[key]||0))).filter(n=>Number.isSafeInteger(n)&&n>0))];
  if(!ids.includes(Number(clickedMessageId)))throw new Error("Unlinked TTiTTulares Telegram message");
  return ids;
}
async function inlineTtiTelegramDecision(env,update,event){
  const [rawAction,eventId]=event.text.split("|");
  const status=rawAction==="ttp"?"published":"dismissed";
  const now=new Date().toISOString();
  const gh="https://api.github.com/repos/fabricelop/europapress-rss/contents/";
  const headers={
    "accept":"application/vnd.github+json",
    "authorization":"Bearer "+env.GITHUB_TOKEN,
    "content-type":"application/json",
    "user-agent":"ttittulares-realtime-telegram-decision-v2",
    "x-github-api-version":"2022-11-28"
  };
  const deliveriesResponse=await fetch(gh+"telegram/ttittulares-deliveries.json?ref=main",{headers,cache:"no-store"});
  if(!deliveriesResponse.ok)throw new Error("Delivery verification failed HTTP "+deliveriesResponse.status);
  const deliveriesFile=await deliveriesResponse.json();
  const deliveriesDoc=JSON.parse(Buffer.from(String(deliveriesFile.content||"").replace(/\s/g,""),"base64").toString("utf8"));
  const messageIds=linkedTtiTelegramMessages(deliveriesDoc.items,eventId,event.message_id);
  let persisted=false;
  for(let attempt=0;attempt<5;attempt++){
    const response=await fetch(gh+"ttittulares/decisions.json?ref=main",{headers,cache:"no-store"});
    if(!response.ok)throw new Error("Immediate decision read HTTP "+response.status);
    const file=await response.json();
    const doc=JSON.parse(Buffer.from(String(file.content||"").replace(/\s/g,""),"base64").toString("utf8"));
    if(!Array.isArray(doc.items))throw new Error("Decisions schema invalid");
    let row=doc.items.find(item=>String(item.event_id||"")===eventId);
    if(row&&["dismissed","published"].includes(row.status)&&row.status!==status)
      throw new Error("Conflicting terminal Telegram decision");
    if(row?.status===status){persisted=true;break;}
    if(!row){row={event_id:eventId};doc.items.push(row);}
    Object.assign(row,{status,updated_at:now,decision_source:"telegram_emergency_callback",telegram_message_id:event.message_id});
    doc.updated_at=now;
    const payload={
      message:"TTiTTulares: "+status+" inmediato desde Telegram "+eventId,
      branch:"main",sha:file.sha,
      content:Buffer.from(JSON.stringify(doc,null,2)+"\n","utf8").toString("base64")
    };
    const write=await fetch(gh+"ttittulares/decisions.json",{method:"PUT",headers,body:JSON.stringify(payload)});
    if(write.ok){persisted=true;break;}
    if(![409,422].includes(write.status))throw new Error("Immediate decision write HTTP "+write.status);
  }
  if(!persisted)throw new Error("Decision persisted only in callback inbox; retry queued");
  // Terminal decision is now visible to delivery workflows, preventing re-delivery.
  // Delete all deliveries of this event, including both archive and IA companions.
  const chat=update?.callback_query?.message?.chat?.id;
  const token=await cloudflareTelegramBotToken(env);
  const outcomes=await Promise.all(messageIds.map(async messageId=>{
    try{
      const response=await fetch("https://api.telegram.org/bot"+token+"/deleteMessage",{
        method:"POST",headers:{"content-type":"application/json"},
        body:JSON.stringify({chat_id:chat,message_id:messageId})
      });
      const result=await response.json().catch(()=>({}));
      const description=String(result.description||"");
      const ok=Boolean(result.ok)||description.toLowerCase().includes("message to delete not found");
      if(!ok)console.log("TTITTULARES_INLINE_DELETE_PENDING",messageId,"HTTP",response.status);
      return {message_id:messageId,deleted:ok};
    }catch(error){
      console.log("TTITTULARES_INLINE_DELETE_RETRY",messageId,String(error?.name||"NetworkError"));
      return {message_id:messageId,deleted:false};
    }
  }));
  // The already-persisted callback inbox triggers the durable GitHub Actions
  // processor, which updates all downstream states and retries failed deletes.
  return {applied:true,deleted:outcomes.every(x=>x.deleted),message_count:messageIds.length};
}


async function instagramTelegramNotice(env,update,text){
  const chat=update?.callback_query?.message?.chat?.id;
  const messageId=Number(update?.callback_query?.message?.message_id);
  if(!chat||!messageId)throw new Error("INSTAGRAM_NOTICE_MISSING_CHAT");
  const token=await cloudflareTelegramBotToken(env);
  const response=await fetch("https://api.telegram.org/bot"+token+"/sendMessage",{
    method:"POST",headers:{"content-type":"application/json"},
    body:JSON.stringify({chat_id:chat,text:"📸 "+text,reply_to_message_id:messageId})
  });
  const body=await response.json().catch(()=>({}));
  if(!response.ok||!body.ok)throw new Error("INSTAGRAM_NOTICE_FAILED");
}

async function publishTtiInstagramSelected(env,update,event){
  const allowedChat=String(env.INSTAGRAM_ALLOWED_CHAT_ID||"");
  const callbackChat=String(update?.callback_query?.message?.chat?.id||"");
  if(!allowedChat||allowedChat!==callbackChat)return json({ok:false,error:"Unauthorized Instagram chat"},403);
  if(!env.INSTAGRAM_PUBLISHER_URL||!env.INSTAGRAM_INTERNAL_SECRET||
     String(env.INSTAGRAM_INTERNAL_SECRET).length<32){
    await instagramTelegramNotice(env,update,"Instagram no está configurado. No se ha publicado nada.");
    return json({ok:false,error:"Instagram pilot disabled or not configured"},503);
  }
  const endpoint=String(env.INSTAGRAM_PUBLISHER_URL).replace(/\/+$/,"")+"/publish";
  if(!/^https:\/\/[a-zA-Z0-9.-]+\/publish$/.test(endpoint)){
    await instagramTelegramNotice(env,update,"La ruta de Instagram no es válida. No se ha enviado ninguna publicación.");
    return json({ok:false,error:"Invalid Instagram endpoint"},503);
  }
  const gh="https://api.github.com/repos/fabricelop/europapress-rss/contents/telegram/ttittulares-deliveries.json?ref=main";
  const response=await fetch(gh,{headers:{
    accept:"application/vnd.github+json",
    authorization:"Bearer "+env.GITHUB_TOKEN,
    "user-agent":"ttittulares-instagram-pilot"
  },cache:"no-store"});
  if(!response.ok)throw new Error("Could not verify Telegram delivery");
  const file=await response.json();
  const doc=JSON.parse(Buffer.from(String(file.content||"").replace(/\s/g,""),"base64").toString("utf8"));
  const eventId=event.text.split("|")[1];
  const messageId=Number(event.message_id);
  const delivery=[...(doc.items||[])].reverse().find(x=>
    String(x.event_id||"")===eventId && Number(x.telegram_message_id)===messageId
    && String(x.status||"").toLowerCase()==="sent"
    && x.instagram?.image_url && x.instagram?.caption);
  if(!delivery){
    await instagramTelegramNotice(env,update,"El paquete de esta noticia no está disponible para Instagram; no se ha publicado nada.");
    return json({ok:false,error:"No eligible Instagram package for this message"},409);
  }
  const original=delivery.instagram;
  const payload={
    source:"ttittulares",event_id:eventId,revision:Number(delivery.revision)||1,
    telegram_message_id:messageId,
    image_url:String(original.image_url),caption:String(original.caption)
  };
  let result={};
  for(let attempt=0;attempt<5;attempt++){
    const r=await fetch(endpoint,{method:"POST",
      headers:{"content-type":"application/json","authorization":"Bearer "+env.INSTAGRAM_INTERNAL_SECRET,
        "user-agent":"TTActualidad-TTiTTulares/1.0"},
      body:JSON.stringify(payload)});
    result=await r.json().catch(()=>({error:"NON_JSON_RESPONSE"}));
    result.http_status=r.status;
    if(r.ok&&result.state==="published")break;
    if(r.status!==202||result.state!=="processing")break;
    await new Promise(resolve=>setTimeout(resolve,Math.min(5000,2000+attempt*750)));
  }
  const token=await cloudflareTelegramBotToken(env);
  const chat=update?.callback_query?.message?.chat?.id;
  const tg="https://api.telegram.org/bot"+token+"/";
  if(result.state==="published"&&result.permalink?.startsWith("https://www.instagram.com/")){
    const old=update?.callback_query?.message?.reply_markup?.inline_keyboard||[];
    const revised=old.map(row=>row.map(button=>
      button?.callback_data==="tt:i:"+eventId?
      {text:"📸 Publicado en Instagram",url:result.permalink}:button));
    const edited=await fetch(tg+"editMessageReplyMarkup",{method:"POST",headers:{"content-type":"application/json"},
      body:JSON.stringify({chat_id:chat,message_id:messageId,reply_markup:{inline_keyboard:revised}})});
    const editResult=await edited.json().catch(()=>({}));
    if(!edited.ok||!editResult.ok){
      // Publication is confirmed: if Telegram cannot edit the button, deliver
      // its permalink in a reply instead. Never publish again to repair UI.
      await instagramTelegramNotice(env,update,"Publicado en Instagram: "+result.permalink);
    }
    return json({ok:true,state:"published",permalink:result.permalink});
  }
  // Never delete Telegram or update X on Meta error/ambiguous publication.
  const note=result.state==="published"?
    "Publicado en Instagram. Enlace pendiente de confirmar.":
    result.state==="processing"?
    "Instagram sigue procesando la imagen. Vuelve a pulsar el botón en unos segundos.":
    result.state==="uncertain"?
    "No se puede confirmar la publicación. Comprueba Instagram antes de reintentar.":
    "No se ha confirmado la publicación en Instagram; el mensaje de Telegram sigue disponible.";
  const metaCode=Number.isSafeInteger(result.meta_error_code)?result.meta_error_code:null;
  const metaSubcode=Number.isSafeInteger(result.meta_error_subcode)?result.meta_error_subcode:null;
  const diagnostic=(result.error?"\\nDiagnóstico: "+String(result.error).slice(0,64):"")+
    (metaCode!==null?"\\nMeta: "+metaCode+(metaSubcode!==null?"/"+metaSubcode:""):"");
  await instagramTelegramNotice(env,update,note+diagnostic);
  return json({ok:result.state==="published",state:result.state||"error"});
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
  // Verify authenticity and ACK in the live webhook (<10 sec), never in
  // GitHub Actions: Telegram callback_query IDs expire before GH jobs start.
  try{
    const ack=await verifyAndAnswerTelegramCallback(event,env);
    if(!ack.ok)return json({ok:false,error:"Telegram callback expired or invalid",status:ack.status},422);
    event.verified_by_telegram=true;
    event.verified_at=new Date().toISOString();
  }catch(err){
    console.log("TTiTTulares immediate Telegram ACK failed",String(err?.message||err));
    return json({ok:false,error:"Telegram confirmation unavailable"},503);
  }
  if(event.type==="instagram_action"){
    // Instagram never changes the independent X Published / Dismissed state.
    // The callback is confirmed against Telegram before reading the trusted
    // delivery snapshot. Nothing submitted in callback_data is trusted as media.
    try {return await publishTtiInstagramSelected(env,update,event);}
    catch(error) {
      console.log("TTITTULARES_INSTAGRAM_CALLBACK_FAILED",String(error?.message||error));
      try{
        await instagramTelegramNotice(env,update,
          "No se ha podido confirmar la publicación. Comprueba @ttactualidad antes de volver a pulsar.");
      }catch(notifyError){
        console.log("TTITTULARES_INSTAGRAM_NOTIFY_FAILED",String(notifyError?.message||notifyError));
      }
      return json({ok:false,error:"Instagram publication was not confirmed; check Instagram first"},503);
    }
  }
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
    if(w.ok){
      try{
        const inline=await inlineTtiTelegramDecision(env,update,event);
        return json({ok:true,queued:true,update_id:event.update_id,immediate:inline});
      }catch(error){
        // Never lose an ACKed callback: inbox already persisted for Actions.
        console.log("TTITTULARES_INLINE_FALLBACK_TO_DURABLE_QUEUE",event.update_id,String(error?.message||error));
        return json({ok:true,queued:true,update_id:event.update_id,immediate:{applied:false,queued_for_retry:true}});
      }
    }
    if(![409,422].includes(w.status))return json({ok:false,phase:"write",status:w.status},503);
  }
  return json({ok:false,error:"Concurrent callback queue write"},503);
}

export default {
  async fetch(request,env){
    const url=new URL(request.url),path=url.pathname.replace(/\/+$/,"")||"/";
    if(path==="/health")return json({ok:true,service:"ttittulares-cloudflare",mode:"legacy-handlers"});
    if(path==="/api/ttittulares-telegram-credential-ready"&&request.method==="GET")return telegramCryptoReady(env);
    if(path==="/api/ttittulares-telegram-pipeline-version"&&request.method==="GET")return json({ok:true,version:"immediate-decision-delete-v2"});
    if(path==="/api/ttittulares-instagram-preflight"&&request.method==="GET"){
      // Authenticated, read-only verification. Never creates a media container.
      const secret=String(env.INSTAGRAM_INTERNAL_SECRET||"");
      if(secret.length<32||request.headers.get("authorization")!=="Bearer "+secret){
        return json({ok:false,error:"UNAUTHORIZED"},401);
      }
      const chat=String(url.searchParams.get("chat_id")||"");
      const allowedChat=String(env.INSTAGRAM_ALLOWED_CHAT_ID||"");
      const configured=Boolean(allowedChat)&&Boolean(env.GITHUB_TOKEN)&&
        Boolean(env.TTITTULARES_CALLBACK_DECRYPT_KEY);
      const publisher=String(env.INSTAGRAM_PUBLISHER_URL||"").replace(/\\/+$/,"");
      const endpointOk=publisher==="https://tt-actualidad-instagram-pilot.fabricelop.workers.dev";
      let publisherStatus=0,publisherOk=false;
      if(endpointOk){
        try{
          const p=await fetch(publisher+"/meta-preflight",{
            method:"GET",headers:{"authorization":"Bearer "+secret},
            signal:AbortSignal.timeout(12000)
          });
          publisherStatus=p.status;
          const d=await p.json().catch(()=>({}));
          publisherOk=p.ok&&d.ok===true&&d.active===true;
        }catch(_error){}
      }
      const chatMatches=chat?chat===allowedChat:null;
      return json({ok:configured&&endpointOk&&publisherOk&&chatMatches!==false,
        publisher_authenticated:publisherOk,publisher_http:publisherStatus,
        publisher_url_valid:endpointOk,allowed_chat_configured:!!allowedChat,
        chat_matches:chatMatches,github_configured:!!env.GITHUB_TOKEN,
        telegram_bot_configured:!!env.TTITTULARES_CALLBACK_DECRYPT_KEY});
    }
    if(path==="/api/ttittulares-instagram-route-version"&&request.method==="GET")return json({ok:true,version:"instagram-callback-preflight-v1",telegram_callback:"tt:i",status:"disabled_until_credentials"});
    if(path==="/api/ttittulares-telegram-callback")return enqueueTtiTelegramCallback(request,env);
    if(Object.prototype.hasOwnProperty.call(ROUTES,path)){
      return handlerRequest(request,env,url,ROUTES[path]);
    }
    if(path==="/")return Response.redirect(url.origin+"/ttittulares/",302);
    if(env.ASSETS&&["GET","HEAD"].includes(request.method))return env.ASSETS.fetch(request);
    return json({ok:false,error:"No encontrado"},404);
  }
};
export {handlerRequest,responseAdapter,parseTtiCallback,linkedTtiTelegramMessages};
