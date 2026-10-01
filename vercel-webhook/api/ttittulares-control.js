import crypto from "node:crypto";
import { annotateTitularRemates, titularRemateIdentity, titularRemateVariants, buildTitularRemateRecord } from "../lib/ttittulares-remate-ratings.js";

const REPO=process.env.GITHUB_REPO||"fabricelop/europapress-rss";
const BRANCH=process.env.GITHUB_BRANCH||"main";
const PREPARED="ttittulares/prepared.json";
const REMATE_RATINGS="ttittulares/remate-ratings.json";
const DECISIONS="ttittulares/decisions.json";
const PROCESSING="telegram/editorial-processing.json";
const EVENTS="telegram/events.json";
const MANUAL_ARCHIVE="ttittulares/manual-submissions.json";
const TREND_CANDIDATES="ttittulares/trend-candidates.json";
const TREMENDING="ttittulares/tremending/items.json";
const TREND_REQUESTS="trends/requests.json";
const TREND_EDITORIAL_QUEUE="trends/editorial-queue.json";
// Tokens de control ya emitidos. No rotar ni eliminar salvo revocación de seguridad explícita.
const CONTROL_TOKEN_HASHES=[
  "2663da5223c2313c3670a7843a0cdfabfd2dd7c8fad1ed168247866a3b1262e5",
  "083d41ffcc41b14d52d426412b1ed44a8d4958b351ee110bdcc5a0eec167b840",
  "cdaa00313ab7f8031d485ac42ec8bb5d22eadf41a27e719848c8c6fcf40f3c98"
];

function b64d(s){return Buffer.from(String(s||"").replace(/\n/g,""),"base64").toString("utf8")}
function b64e(s){return Buffer.from(s,"utf8").toString("base64")}
function authToken(req){const h=String(req.headers.authorization||"");return h.startsWith("Bearer ")?h.slice(7).trim():""}
function authorized(req){
  // Los previews están protegidos por Vercel Deployment Protection.
  // No pedimos un segundo token dentro de la propia app.
  if(process.env.VERCEL_ENV==="preview")return true;
  const got=authToken(req);if(!got)return false;
  const expected=process.env.TTITTULARES_CONTROL_TOKEN||"";
  if(expected&&got===expected)return true;
  const digest=Buffer.from(crypto.createHash("sha256").update(got).digest("hex"));
  return CONTROL_TOKEN_HASHES.some(hash=>crypto.timingSafeEqual(digest,Buffer.from(hash)));
}
async function gh(path,options={}){
  if(!process.env.GITHUB_TOKEN)throw new Error("GITHUB_TOKEN no configurado");
  return fetch(`https://api.github.com/repos/${REPO}/${path}`,{
    ...options,
    headers:{accept:"application/vnd.github+json",authorization:`Bearer ${process.env.GITHUB_TOKEN}`,
      "x-github-api-version":"2022-11-28","user-agent":"ttittulares-web-control",...(options.headers||{})}
  })
}
async function readJson(path){
  let lastError;
  for(let attempt=1;attempt<=3;attempt++){
    const r=await gh(`contents/${path}?ref=${encodeURIComponent(BRANCH)}&_=${Date.now()}-${attempt}`,{cache:"no-store"});
    if(!r.ok)throw new Error(`GitHub GET ${path}: ${r.status} ${await r.text()}`);
    const f=await r.json();
    try{
      let raw="";
      if(f.content&&String(f.encoding||"base64")==="base64")raw=b64d(f.content);
      else if(f.content&&String(f.encoding||"")==="utf-8")raw=String(f.content);
      else if(f.sha){
        // GitHub Contents deja content vacío/encoding:none para ficheros >1 MB.
        // El blob API sí entrega hasta 100 MB y evita convertir events.json en {}.
        const br=await gh(`git/blobs/${f.sha}`,{cache:"no-store"});
        if(!br.ok)throw new Error(`GitHub BLOB ${path}: ${br.status} ${await br.text()}`);
        const blob=await br.json();
        if(blob.content&&String(blob.encoding||"base64")==="base64")raw=b64d(blob.content);
        else if(blob.content)raw=String(blob.content);
      }
      if(!raw.trim())throw new Error(`Contenido vacío para ${path} (sha ${f.sha||"desconocido"})`);
      return {doc:JSON.parse(raw),sha:f.sha}
    }catch(e){
      lastError=e;
      console.error("JSON inválido temporal",path,"sha",f.sha,"intento",attempt,String(e));
      if(attempt<3)await new Promise(resolve=>setTimeout(resolve,attempt*250));
    }
  }
  throw new Error(`JSON inválido en ${path} tras 3 lecturas: ${String(lastError?.message||lastError)}`)
}
async function readPublicJson(path){
  const clean=String(path||"").split("/").map(encodeURIComponent).join("/");
  const url=`https://raw.githubusercontent.com/${REPO}/${encodeURIComponent(BRANCH)}/${clean}?t=${Date.now()}`;
  const r=await fetch(url,{cache:"no-store",headers:{"user-agent":"ttittulares-web-read"}});
  if(!r.ok)throw new Error(`GitHub RAW ${path}: ${r.status}`);
  const raw=await r.text();
  if(!raw.trim())throw new Error(`GitHub RAW ${path}: contenido vacío`);
  return {doc:JSON.parse(raw),sha:null,source:"raw"}
}

async function mutateJson(path,message,fn){
  for(let attempt=1;attempt<=5;attempt++){
    const {doc,sha}=await readJson(path);const before=JSON.stringify(doc);const next=await fn(doc);
    if(JSON.stringify(next)===before)return next;
    const r=await gh(`contents/${path}`,{method:"PUT",headers:{"content-type":"application/json"},body:JSON.stringify({
      message,content:b64e(JSON.stringify(next,null,2)+"\n"),sha,branch:BRANCH
    })});
    if(r.ok)return next;
    if(![409,422].includes(r.status))throw new Error(`GitHub PUT ${path}: ${r.status} ${await r.text()}`);
    await new Promise(resolve=>setTimeout(resolve,attempt*150));
  }
  throw new Error(`Conflicto persistente actualizando ${path}`)
}
function idOf(v){return String(v||"").trim()}
function canonicalUrl(v){
  const raw=String(v||"").trim();if(!raw)return "";
  try{
    const u=new URL(raw);u.hash="";
    for(const k of [...u.searchParams.keys()])if(/^utm_/i.test(k)||["fbclid","gclid","mc_cid","mc_eid"].includes(k.toLowerCase()))u.searchParams.delete(k);
    u.hostname=u.hostname.toLowerCase();u.pathname=u.pathname.replace(/\/$/,"")||"/";
    const pairs=[...u.searchParams.entries()].sort(([a],[b])=>a.localeCompare(b));u.search="";
    for(const [k,val] of pairs)u.searchParams.append(k,val);
    return u.toString()
  }catch(_){return raw.replace(/#.*$/,"").replace(/\/$/,"")}
}
function normalizedTitle(v){
  return String(v||"").normalize("NFD").replace(/[\u0300-\u036f]/g,"").toLowerCase().replace(/[^a-z0-9]+/g," ").trim().replace(/\s+/g," ")
}
function storyMatches(a,b){
  const au=canonicalUrl(a?.url||a?.canonical_url),bu=canonicalUrl(b?.url||b?.canonical_url);
  if(au&&bu&&au===bu)return true;
  const at=normalizedTitle(a?.title||a?.canonical_title||a?.normalized_title),bt=normalizedTitle(b?.title||b?.canonical_title||b?.normalized_title);
  return Boolean(at&&bt&&at===bt)
}
function manualEventId(url,title){
  const base=canonicalUrl(url)||normalizedTitle(title);
  return "manual-"+crypto.createHash("sha256").update(base).digest("hex").slice(0,12)
}
function tremendingEntryId(value){return idOf(value)}
function tremendingEventId(item){
  const id=tremendingEntryId(item?.id);if(!id)throw new Error("Entrada Tremending no válida");
  return "tremending-"+crypto.createHash("sha256").update(id).digest("hex").slice(0,12)
}
function selectedTremendingTweet(item){
  const wanted=idOf(item?.selected_tweet_id);
  const tweet=(item?.tweets||[]).find(x=>idOf(x?.id)===wanted);
  return tweet&&String(tweet.url||"").startsWith("https://x.com/")?tweet:null
}
async function selectTremendingTweet(entryId,tweetId){
  const entry=tremendingEntryId(entryId),tweet=tremendingEntryId(tweetId);if(!entry||!tweet)throw new Error("Falta la entrada o el tuit elegido");
  const now=new Date().toISOString();let chosen=null;
  await mutateJson(TREMENDING,"Elegir tuit Tremending desde TTiTTulares",doc=>{
    doc.items||=[];const item=doc.items.find(x=>tremendingEntryId(x.id)===entry);
    if(!item)throw new Error("No se encuentra la entrada Tremending");
    chosen=(item.tweets||[]).find(x=>tremendingEntryId(x.id)===tweet);
    if(!chosen)throw new Error("Ese tuit no pertenece a esta entrada");
    item.selected_tweet_id=tweet;item.selected_tweet_url=chosen.url;item.selected_tweet_author=chosen.author||"";
    item.image={status:"pending_capture",tweet_id:tweet,tweet_url:chosen.url,requested_at:now};
    if(!item.status||item.status==="postponed")item.status="pending";
    item.updated_at=now;doc.updated_at=now;return doc
  });
  return {ok:true,entry_id:entry,tweet:chosen,image_status:"pending_capture"}
}
async function markTremending(entryId,status){
  const entry=tremendingEntryId(entryId);if(!entry)throw new Error("Falta entry_id");const now=new Date().toISOString();
  await mutateJson(TREMENDING,status==="discarded"?"Descartar entrada Tremending":"Posponer entrada Tremending",doc=>{
    doc.items||=[];const item=doc.items.find(x=>tremendingEntryId(x.id)===entry);if(!item)throw new Error("No se encuentra la entrada Tremending");
    item.status=status;item.updated_at=now;if(status==="discarded")item.discarded_at=now;else item.postponed_at=now;doc.updated_at=now;return doc
  });
  return {ok:true,entry_id:entry,status}
}
function shortTremendingTrendTitle(title){
  const clean=String(title||"").replace(/\s+/g," ").trim();
  const pair=clean.match(/\bentre\s+([A-ZÁÉÍÓÚÑ][\p{L}.-]*(?:\s+[A-ZÁÉÍÓÚÑ][\p{L}.-]*){1,2})\s+y\s+([A-ZÁÉÍÓÚÑ][\p{L}.-]*(?:\s+[A-ZÁÉÍÓÚÑ][\p{L}.-]*){1,2})(?=\s+en\b|[,:;“"]|$)/u);
  if(pair){
    const first=pair[1].trim().split(/\s+/).at(-1),second=pair[2].trim().split(/\s+/).at(-1);
    const candidate=first+(/^[ií]/i.test(second)?" e ":" y ")+second;
    if(candidate.length<=56)return candidate;
  }
  const phrase=clean.split(/[“":;!?]/,1)[0].trim().replace(/[.,\s]+$/g,"");
  const words=phrase.split(/\s+/),chosen=[];
  for(const word of words){if((chosen.join(" ")+(chosen.length?" ":"")+word).length>55)break;chosen.push(word);}
  return chosen.join(" ")||clean.slice(0,55).trim()||"Tremending";
}
async function sendTremending(entryId,destination){
  const entry=tremendingEntryId(entryId),target=String(destination||"");
  if(!["news","trend"].includes(target))throw new Error("Destino Tremending no válido");
  const {doc:inbox}=await readJson(TREMENDING);
  const item=(inbox.items||[]).find(x=>tremendingEntryId(x.id)===entry);
  if(!item)throw new Error("No se encuentra la entrada Tremending");
  if(String(item.status||"").toLowerCase()==="discarded")throw new Error("La entrada está descartada");
  const tweet=selectedTremendingTweet(item);if(!tweet)throw new Error("Elige primero el tuit que quieres usar");
  const now=new Date().toISOString(),eventId=tremendingEventId(item),title=String(item.title||"Entrada Tremending").trim(),url=canonicalUrl(item.url||"");
  const requestedNews=target==="news",requestedTrend=target==="trend";
  const capture=(item.image&&item.image.status==="ready"&&/^https:\/\//i.test(String(item.image.url||"")))?{
    url:String(item.image.url),source:"X / Tremending",source_url:String(tweet.url||""),rights_status:"tweet_capture",generated:false,
    alt:"Captura del tuit seleccionado para "+title
  }:null;
  let closed=null;

  if(requestedNews){
    const {doc:decisions}=await readJson(DECISIONS);
    closed=(decisions.items||[]).find(x=>idOf(x.event_id)===eventId&&["published","dismissed"].includes(String(x.status||"").toLowerCase()))||null;
    if(!closed){
      await mutateJson(EVENTS,"Registrar entrada Tremending para TTiTTulares",doc=>{
        doc.events||=[];let ev=doc.events.find(x=>idOf(x.id||x.event_id)===eventId);
        if(!ev){ev={id:eventId,canonical_title:title,url,appearances:[{source:"Público · Tremending",url,first_seen:now}],sources:["Público · Tremending"],source_count:1,first_seen:now,last_seen:now,status:"PROCESSING",revision:1,tremending_origin:true,tremending_id:entry};doc.events.push(ev)}
        else Object.assign(ev,{status:"PROCESSING",last_seen:now,tremending_origin:true,tremending_id:entry});
        doc.updated_at=now;return doc
      });
      await mutateJson(PROCESSING,"Enviar entrada Tremending a elaboración",doc=>{
        doc.items||=[];let row=[...(doc.items||[])].reverse().find(x=>idOf(x.event_id)===eventId);if(!row){row={event_id:eventId};doc.items.push(row)}
        Object.assign(row,{
          event_id:eventId,title,url,sources:["Público · Tremending"],source_count:1,drafted_source_count:1,selected_at:now,status:"PROCESSING",
          selection_mode:"TREMENDING_USER",manual_submission:true,tremending_origin:true,tremending_id:entry,tremending_tweet:tweet,
          with_image:true,disable_ai_image:true,image_mode:"tweet_capture_only",image_strategy:"tweet_capture_only",
          fallback_image_status:capture?"ready":"pending_capture",fallback_image:capture||undefined,
          image:capture||undefined,image_choice:capture?"fallback":"none",image_status:capture?"ready":"pending_capture",image_pending:!capture
        });
        delete row.ai_image;delete row.ai_image_status;delete row.ai_image_attempt;delete row.ai_image_last_attempt_status;delete row.dismissed_at;delete row.delivered_at;
        doc.updated_at=now;return doc
      });
    }
  }

  if(requestedTrend){
    const trendId="tremending-"+crypto.createHash("sha256").update(entry).digest("hex").slice(0,12),name=shortTremendingTrendTitle(title);
    const trendContext="Entrada seleccionada desde Público/Tremending. Titula con el nombre corto \""+name+"\" y redacta \"TT 🗯️ "+name+" es tendencia por/porque ...\" con un remate opcional 🌶️ en la línea siguiente. No utilizar TT#0 ni repetir título, ni copiar el titular completo. Verifica los hechos y atribuye opiniones. Usa exclusivamente la captura del tuit seleccionado como imagen; NO generes imagen IA.";
    await mutateJson(TREND_REQUESTS,"Enviar entrada Tremending a TTendencias",doc=>{
      doc.requests||=[];let row=doc.requests.find(x=>idOf(x.id)===trendId);if(!row){row={id:trendId,revision:0};doc.requests.push(row)}
      Object.assign(row,{
        id:trendId,name,rank:0,status:"preparing",requested_at:now,reexplain:false,with_image:true,disable_ai_image:true,image_strategy:"tweet_capture_only",
        alternatives_target:0,task:"explain",requested_together:[name],auto_queued:false,tremending_origin:true,tremending_id:entry,
        article_title:title,source_url:url,selected_tweet:tweet,selected_tweet_image:capture,rewrite_instruction:trendContext
      });
      doc.updated_at=now;return doc
    });
    await mutateJson(TREND_EDITORIAL_QUEUE,"Incorporar entrada Tremending a cola TTendencias",doc=>{
      doc.project||="TTendencias";doc.items||=[];doc.items=doc.items.filter(x=>idOf(x.id)!==trendId);
      doc.items.push({
        id:trendId,name,rank:0,status:"preparing",requested_at:now,revision:0,rewrite_instruction:trendContext,
        with_image:true,disable_ai_image:true,image_strategy:"tweet_capture_only",task:"explain",batch_id:null,requested_together:[name],
        captured_with:[],auto_queued:false,tremending_origin:true,tremending_id:entry,article_title:title,source_url:url,
        selected_tweet:tweet,selected_tweet_image:capture
      });
      doc.count=doc.items.length;doc.updated_at=now;return doc
    });
  }

  await mutateJson(TREMENDING,"Registrar destino editorial de Tremending",doc=>{
    doc.items||=[];const row=doc.items.find(x=>tremendingEntryId(x.id)===entry);if(!row)throw new Error("No se encuentra la entrada Tremending");
    row.status="sent";row.destinations=[...new Set([...(row.destinations||[]),target])];row.sent_at=now;row.updated_at=now;doc.updated_at=now;return doc
  });
  return {ok:true,entry_id:entry,event_id:eventId,destination:target,news_queued:requestedNews&&!closed,trend_queued:requestedTrend,duplicate_news:!!closed}
}
function threeSourceSpeedMinutes(event){
  const general=new Set(Array.isArray(event.sources)?event.sources:[]);
  const times=(event.appearances||[])
    .filter(x=>general.has(x.source)&&x.first_seen)
    .map(x=>Date.parse(x.first_seen))
    .filter(Number.isFinite)
    .sort((x,y)=>x-y);
  return times.length>=3?Math.max(0,Math.round((times[2]-times[0])/60000)):null
}
async function closePrepared(eventId,status){
  const id=idOf(eventId);if(!id)throw new Error("Falta event_id");
  const now=new Date().toISOString();
  let cancelPendingImage=false;
  if(status==="published"){
    try{
      const {doc}=await readJson(PREPARED);
      const item=(doc.items||[]).find(x=>idOf(x.event_id)===id);
      if(item){
        const state=String(item.image_status||(item.image_pending?"pending":item.image?.url?"ready":"none")).toLowerCase();
        const url=String(item.image?.url||item.image_url||"");
        const terminal=(state==="ready"&&!!url)||state==="telegram"||state==="none";
        cancelPendingImage=!terminal||Boolean(item.image_pending);
      }
    }catch(e){console.error("No se pudo determinar estado de imagen al publicar",e)}
  }
  await mutateJson(DECISIONS,`${status==="published"?"Publicar":"Desestimar"} TTiTTulares desde web`,doc=>{
    doc.project||="TTiTTulares";doc.items||=[];
    const old=doc.items.find(x=>idOf(x.event_id)===id);
    if(old)Object.assign(old,{status,updated_at:now,...(cancelPendingImage?{image_cancelled_by_publication:true,image_cancelled_at:now,image_cancel_reason:"published_before_image_complete"}:{})});
    else doc.items.push({event_id:id,status,updated_at:now,...(cancelPendingImage?{image_cancelled_by_publication:true,image_cancelled_at:now,image_cancel_reason:"published_before_image_complete"}:{})});
    doc.updated_at=now;return doc
  });
  await Promise.all([
    mutateJson(PREPARED,"Retirar noticia cerrada de TTiTTulares web",doc=>{
      doc.items=(doc.items||[]).filter(x=>idOf(x.event_id)!==id);doc.updated_at=now;return doc
    }),
    mutateJson(PROCESSING,"Actualizar cierre web TTiTTulares",doc=>{
      for(const item of doc.items||[])if(idOf(item.event_id)===id){
        item.status=status==="published"?"PUBLISHED":"DISMISSED";
        item[status==="published"?"published_at":"dismissed_at"]=now;
        if(cancelPendingImage){
          item.image_cancelled_by_publication=true;
          item.image_cancelled_at=now;
          item.image_cancel_reason="published_before_image_complete";
          item.image_pending=false
        }
      }
      doc.updated_at=now;return doc
    }),
    mutateJson(EVENTS,"Cerrar evento TTiTTulares desde web",doc=>{
      for(const event of doc.events||[])if(idOf(event.id||event.event_id)===id){
        event.status=status==="published"?"PUBLISHED":"DISMISSED";
        event[status==="published"?"published_at":"dismissed_at"]=now;
        if(cancelPendingImage){
          event.image_cancelled_by_publication=true;
          event.image_cancelled_at=now;
          event.image_cancel_reason="published_before_image_complete"
        }
      }
      doc.updated_at=now;return doc
    }),
    mutateJson(MANUAL_ARCHIVE,"Actualizar archivo manual TTiTTulares",doc=>{
      doc.items||=[];
      for(const item of doc.items)if(idOf(item.event_id)===id){
        item.status=status.toUpperCase();item.updated_at=now
      }
      doc.updated_at=now;return doc
    })
  ]);
  return {ok:true,event_id:id,status}
}
async function markUserValidated(eventId){
  const id=idOf(eventId);if(!id)throw new Error("Falta event_id");
  const now=new Date().toISOString();
  await mutateJson(PROCESSING,"Validar noticia no comprobada TTiTTulares",doc=>{
    doc.items||=[];
    const item=[...doc.items].reverse().find(x=>idOf(x.event_id)===id);
    if(!item)throw new Error("No se encuentra la noticia");
    if(String(item.status||"")!=="PROBLEMATIC")throw new Error("La noticia ya no está en No comprobadas");
    item.user_validated=true;
    item.user_validated_at=now;
    item.user_validation_source="web_check";
    item.user_validation_version=Number(item.user_validation_version||0)+1;
    doc.updated_at=now;return doc
  });
  return {ok:true,event_id:id,status:"PROBLEMATIC",user_validated:true,user_validated_at:now}
}
async function requestImageRegeneration(eventId){
  const id=idOf(eventId);if(!id)throw new Error("Falta event_id");
  const now=new Date().toISOString();let found=false;
  await mutateJson(PREPARED,"Solicitar regeneración de imagen IA TTiTTulares",doc=>{
    doc.items||=[];
    for(const item of doc.items){
      if(idOf(item.event_id)!==id)continue;
      found=true;
      item.ai_image_regenerate_requested=true;
      item.ai_image_regenerate_requested_at=now;
      item.ai_image_regenerate_request_version=Number(item.ai_image_regenerate_request_version||0)+1;
    }
    doc.updated_at=now;return doc
  });
  if(!found)throw new Error("La noticia ya no está en Listas");
  return {ok:true,event_id:id,image_regeneration:true}
}
async function useFallbackImage(eventId){
  const id=idOf(eventId);if(!id)throw new Error("Falta event_id");
  const now=new Date().toISOString();let changed=false;
  await mutateJson(PREPARED,"Usar imagen de archivo TTiTTulares",doc=>{
    doc.items||=[];
    for(const item of doc.items){
      if(idOf(item.event_id)!==id)continue;
      const fallback=item.fallback_image||{};
      if(!/^https:\/\//i.test(String(fallback.url||"")))throw new Error("Todavía no hay imagen de archivo/fallback disponible");
      item.image={...fallback};
      item.image_choice="fallback";
      item.image_status="ready";
      item.image_pending=false;
      item.image_selected_at=now;
      changed=true
    }
    doc.updated_at=now;return doc
  });
  if(!changed)throw new Error("La noticia ya no está en Listas");
  return {ok:true,event_id:id,image_choice:"fallback"}
}

async function rework(eventId,instruction,reinvestigate=false){
  const id=idOf(eventId),text=String(instruction||"Cambia solo el remate y genera una nueva imagen IA. Conserva exactamente hechos, fuentes y texto factual. No reinvestigues.").trim();
  if(!id)throw new Error("Falta event_id");if(!text)throw new Error("Escribe las instrucciones para rehacer.");
  const now=new Date().toISOString();let found=false,targetRevision=0;
  await mutateJson(PREPARED,"Solicitar reelaboración TTiTTulares desde web",doc=>{
    doc.items||=[];
    for(const item of doc.items){
      if(idOf(item.event_id)!==id)continue;
      found=true;
      targetRevision=Number(item.revision||1)+1;
      item.rewrite_pending=true;
      item.rewrite_requested_at=now;
      item.rewrite_target_revision=targetRevision;
      item.rewrite_request_version=Number(item.rewrite_request_version||0)+1;
      item.rewrite_scope=reinvestigate?"full":"remate_and_ai";
      item.reinvestigate=reinvestigate;
      item.rewrite_request=reinvestigate?text:"CONTRATO: conservar hechos, fuentes y texto factual sin cambios. NO buscar ni reinvestigar. Cambiar exclusivamente remate e imagen IA; un intento ImageGen desde el chat, nunca bloquear READY. "+text;
    }
    if(found)doc.updated_at=now;
    return doc
  });
  if(!found)throw new Error("La noticia ya no está en Listas");
  return {ok:true,event_id:id,status:"PROCESSING",rewrite_pending:true,target_revision:targetRevision}
}
async function submitManualStory(url,title,instruction){
  const cleanUrl=canonicalUrl(url),cleanTitle=String(title||"").trim(),note=String(instruction||"").trim();
  if(!cleanTitle){const e=new Error("Noticia es obligatoria");e.statusCode=400;throw e;}
  const now=new Date().toISOString();
  const [eventsR,queueR,preparedR,decisionsR,archiveR]=await Promise.all([
    readJson(EVENTS),readJson(PROCESSING),readJson(PREPARED),readJson(DECISIONS),readJson(MANUAL_ARCHIVE)
  ]);
  const probe={url:cleanUrl,title:cleanTitle};
  const archiveMatch=[...(archiveR.doc.items||[])].reverse().find(x=>storyMatches(x,probe));
  const eventMatch=(eventsR.doc.events||[]).find(x=>storyMatches(x,probe));
  const queueMatch=[...(queueR.doc.items||[])].reverse().find(x=>storyMatches(x,probe));
  const preparedMatch=(preparedR.doc.items||[]).find(x=>storyMatches(x,probe));
  const candidateIds=new Set([
    archiveMatch?.event_id,eventMatch?.id,eventMatch?.event_id,queueMatch?.event_id,preparedMatch?.event_id
  ].map(idOf).filter(Boolean));
  if(archiveMatch&&["PUBLISHED","DISMISSED"].includes(String(archiveMatch.status||"").toUpperCase())){
    return {ok:true,duplicate:true,event_id:idOf(archiveMatch.event_id),status:String(archiveMatch.status).toUpperCase(),message:"Esta noticia ya estaba cerrada"}
  }
  const decision=(decisionsR.doc.items||[]).find(x=>candidateIds.has(idOf(x.event_id))&&["published","dismissed"].includes(String(x.status||"").toLowerCase()));
  if(decision)return {ok:true,duplicate:true,event_id:idOf(decision.event_id),status:String(decision.status).toUpperCase(),message:"Esta noticia ya estaba cerrada"};
  if(preparedMatch)return {ok:true,duplicate:true,event_id:idOf(preparedMatch.event_id),status:"READY",message:"Esta noticia ya está lista"};
  const activeQueue=queueMatch&&String(queueMatch.status||"")==="PROCESSING"?queueMatch:
    [...(queueR.doc.items||[])].reverse().find(x=>candidateIds.has(idOf(x.event_id))&&String(x.status||"")==="PROCESSING");
  if(activeQueue)return {ok:true,duplicate:true,event_id:idOf(activeQueue.event_id),status:"PROCESSING",message:"Esta noticia ya está en elaboración"};
  const id=idOf(eventMatch?.id||eventMatch?.event_id||queueMatch?.event_id||archiveMatch?.event_id||manualEventId(cleanUrl,cleanTitle));

  const source=eventMatch||queueMatch||archiveMatch||{};
  const finalTitle=cleanTitle||String(source.canonical_title||source.title||"Noticia enviada manualmente");
  const finalUrl=cleanUrl||canonicalUrl(source.url||source.canonical_url);
  const sources=Array.isArray(source.sources)?source.sources:[];
  const sourceCount=Number(source.source_count||source.current_source_count||0);

  await mutateJson(EVENTS,"Registrar noticia manual TTiTTulares",doc=>{
    doc.events||=[];
    let ev=doc.events.find(x=>idOf(x.id||x.event_id)===id);
    if(!ev){
      ev={id,canonical_title:finalTitle,url:finalUrl,appearances:[],sources,source_count:sourceCount,percentage:0,first_seen:now,last_seen:now,status:"PROCESSING",notified:false,revision:1,manual_submission:true};
      doc.events.push(ev)
    }else{
      ev.status="PROCESSING";ev.last_seen=now;ev.manual_submission=true;
      if(finalTitle&&!ev.canonical_title)ev.canonical_title=finalTitle;
      if(finalUrl&&!ev.url)ev.url=finalUrl
    }
    doc.updated_at=now;return doc
  });
  await mutateJson(PROCESSING,"Mandar noticia manual a elaboración TTiTTulares",doc=>{
    doc.items||=[];
    let item=[...doc.items].reverse().find(x=>idOf(x.event_id)===id);
    if(!item){item={event_id:id};doc.items.push(item)}
    Object.assign(item,{
      event_id:id,title:finalTitle,url:finalUrl,sources,source_count:sourceCount,drafted_source_count:sourceCount,
      selected_at:now,status:"PROCESSING",selection_mode:"MANUAL_WEB_USER",manual_submission:true,revision:Number(item.revision||1),with_image:true,image_mode:"ai_plus_fallback"
    });
    if(note){item.rewrite_request=note;item.manual_instruction=note}
    delete item.published_at;delete item.dismissed_at;delete item.delivered_at;
    doc.updated_at=now;return doc
  });
  await mutateJson(MANUAL_ARCHIVE,"Archivar noticia manual TTiTTulares",doc=>{
    doc.version=1;doc.items||=[];
    let item=[...doc.items].reverse().find(x=>idOf(x.event_id)===id||storyMatches(x,probe));
    if(!item){
      item={event_id:id,first_submitted_at:now};doc.items.push(item)
    }
    Object.assign(item,{
      event_id:id,title:finalTitle,url:finalUrl,canonical_url:canonicalUrl(finalUrl),normalized_title:normalizedTitle(finalTitle),
      status:"PROCESSING",last_submitted_at:now,updated_at:now
    });
    if(note)item.instruction=note;
    doc.updated_at=now;return doc
  });
  return {ok:true,duplicate:!!(archiveMatch||eventMatch||queueMatch||preparedMatch),event_id:id,status:"PROCESSING",message:"Enviada a elaboración"}
}

async function manualPrepare(eventId){
  const id=idOf(eventId);if(!id)throw new Error("Falta event_id");
  const now=new Date().toISOString();
  const {doc:events}=await readJson(EVENTS);
  const ev=(events.events||[]).find(x=>idOf(x.id||x.event_id)===id);
  if(!ev)throw new Error("No se encuentra el acontecimiento");
  const count=Number(ev.source_count||0);
  if(count<3)throw new Error("Solo se puede forzar elaboración con al menos 3 fuentes");
  if(!["WAITING","UPDATE_WAITING","ELIGIBLE","ELIGIBLE_UPDATE"].includes(String(ev.status||"")))throw new Error("La noticia ya no está disponible para elaborar");
  const {doc:decisions}=await readJson(DECISIONS);
  const closed=(decisions.items||[]).find(x=>idOf(x.event_id)===id&&["published","dismissed"].includes(String(x.status||"")));
  if(closed)throw new Error("La noticia ya fue cerrada");
  await mutateJson(PROCESSING,"Forzar elaboración TTiTTulares desde web",doc=>{
    doc.items||=[];
    let item=[...doc.items].reverse().find(x=>idOf(x.event_id)===id);
    if(item&&["PROCESSING","READY","PUBLISHED","DISMISSED"].includes(String(item.status||"")))return doc;
    item=item||{event_id:id};
    Object.assign(item,{
      event_id:id,
      title:String(ev.canonical_title||ev.title||""),
      url:String(ev.url||""),
      sources:Array.isArray(ev.sources)?ev.sources:[],
      source_count:count,
      drafted_source_count:count,
      selected_at:now,
      status:"PROCESSING",
      selection_mode:"MANUAL_WEB_3S",
      revision:Number(ev.revision||item.revision||1),
      parent_event_id:ev.parent_event_id||null,
      update_context:ev.update_context||null,
      with_image:true,
      image_mode:"ai_plus_fallback"
    });
    if(!doc.items.includes(item))doc.items.push(item);
    doc.updated_at=now;return doc
  });
  await mutateJson(EVENTS,"Marcar noticia TTiTTulares en elaboración",doc=>{
    for(const event of doc.events||[])if(idOf(event.id||event.event_id)===id){
      event.status="PROCESSING";event.processing_at=now
    }
    doc.updated_at=now;return doc
  });
  return {ok:true,event_id:id,status:"PROCESSING"}
}


function trendCandidateId(item){
  return idOf(item?.candidate_id||item?.event_id||item?.id);
}
function trendCandidateEventId(item){
  const existing=idOf(item?.ttittulares_event_id||item?.event_id);
  if(existing)return existing;
  const base=[String(item?.title||""),...(Array.isArray(item?.trend_names)?item.trend_names:[])].join("|")||JSON.stringify(item||{});
  return "trend-"+crypto.createHash("sha256").update(base).digest("hex").slice(0,12)
}
async function markTrendCandidate(candidateId,status,extra={}){
  const wanted=idOf(candidateId);if(!wanted)throw new Error("Falta candidate_id");
  const now=new Date().toISOString();
  let found=false;
  await mutateJson(TREND_CANDIDATES,status==="dismissed"?"Descartar candidato de TTendencias":"Actualizar candidato de TTendencias",doc=>{
    doc.project||="TTiTTulares";doc.version=Number(doc.version||1);doc.items||=[];
    for(const item of doc.items){
      if(trendCandidateId(item)!==wanted)continue;
      found=true;item.status=status;item.updated_at=now;Object.assign(item,extra);
      if(status==="dismissed")item.dismissed_at=now;
      if(status==="promoted")item.promoted_at=now
    }
    doc.updated_at=now;return doc
  });
  if(!found)throw new Error("No se encuentra el candidato de tendencia");
}
async function dismissTrendCandidate(candidateId){
  await markTrendCandidate(candidateId,"dismissed",{dismissed_source:"web_control"});
  return {ok:true,candidate_id:idOf(candidateId),status:"dismissed"}
}
async function promoteTrendCandidate(candidateId){
  const wanted=idOf(candidateId);if(!wanted)throw new Error("Falta candidate_id");
  const [{doc:candidates},{doc:events},{doc:queue},{doc:prepared},{doc:decisions}]=await Promise.all([
    readJson(TREND_CANDIDATES),readJson(EVENTS),readJson(PROCESSING),readJson(PREPARED),readJson(DECISIONS)
  ]);
  const candidate=(candidates.items||[]).find(x=>trendCandidateId(x)===wanted);
  if(!candidate)throw new Error("No se encuentra el candidato de tendencia");
  if(["dismissed","promoted"].includes(String(candidate.status||"").toLowerCase())){
    return {ok:true,candidate_id:wanted,status:String(candidate.status||"").toLowerCase(),event_id:candidate.ttittulares_event_id||candidate.event_id||null,duplicate:true}
  }
  const eventId=trendCandidateEventId(candidate),now=new Date().toISOString();
  const title=String(candidate.title||candidate.news_title||candidate.explanation||"Noticia detectada en TTendencias").trim();
  const url=String(candidate.url||candidate.source_url||"").trim();
  const sources=Array.isArray(candidate.sources)?candidate.sources:[];
  const sourceEvidence=Array.isArray(candidate.source_evidence)?candidate.source_evidence:[];
  const sourceCount=Number(candidate.source_count||sources.length||0);
  const probe={url,title};
  const closed=(decisions.items||[]).find(x=>idOf(x.event_id)===eventId&&["published","dismissed"].includes(String(x.status||"").toLowerCase()));
  if(closed){
    await markTrendCandidate(wanted,"dismissed",{dismissed_source:"duplicate_closed",ttittulares_event_id:eventId});
    return {ok:true,candidate_id:wanted,event_id:eventId,status:"dismissed",duplicate:true,message:"La noticia ya estaba cerrada"}
  }
  const preparedMatch=(prepared.items||[]).find(x=>idOf(x.event_id)===eventId||storyMatches(x,probe));
  const queueMatch=[...(queue.items||[])].reverse().find(x=>idOf(x.event_id)===eventId||storyMatches(x,probe));
  const eventMatch=(events.events||[]).find(x=>idOf(x.id||x.event_id)===eventId||storyMatches(x,probe));
  if(preparedMatch||["PROCESSING","READY"].includes(String(queueMatch?.status||""))){
    const linked=idOf(preparedMatch?.event_id||queueMatch?.event_id||eventMatch?.id||eventId);
    await markTrendCandidate(wanted,"promoted",{ttittulares_event_id:linked,promoted_source:"duplicate_active"});
    return {ok:true,candidate_id:wanted,event_id:linked,status:"PROCESSING",duplicate:true}
  }

  await mutateJson(EVENTS,"Registrar noticia detectada por TTendencias",doc=>{
    doc.events||=[];
    let ev=doc.events.find(x=>idOf(x.id||x.event_id)===eventId||storyMatches(x,probe));
    if(!ev){
      ev={id:eventId,canonical_title:title,url,appearances:sourceEvidence,sources,source_count:sourceCount,percentage:0,first_seen:candidate.detected_at||candidate.created_at||now,last_seen:now,status:"PROCESSING",notified:false,revision:Number(candidate.revision||1),trend_origin:true,trend_names:candidate.trend_names||[],trend_context:candidate.trend_context||[]};
      doc.events.push(ev)
    }else{
      ev.status="PROCESSING";ev.processing_at=now;ev.trend_origin=true;
      ev.trend_names=[...new Set([...(ev.trend_names||[]),...(candidate.trend_names||[])])];
      ev.trend_context=Array.isArray(candidate.trend_context)?candidate.trend_context:(ev.trend_context||[]);
      if(title&&!ev.canonical_title)ev.canonical_title=title;if(url&&!ev.url)ev.url=url;
      if(sourceCount>Number(ev.source_count||0)){ev.sources=sources;ev.source_count=sourceCount;if(sourceEvidence.length)ev.appearances=sourceEvidence}
    }
    doc.updated_at=now;return doc
  });
  await mutateJson(PROCESSING,"Enviar candidato de TTendencias a elaboración",doc=>{
    doc.items||=[];
    let item=[...doc.items].reverse().find(x=>idOf(x.event_id)===eventId||storyMatches(x,probe));
    if(!item){item={event_id:eventId};doc.items.push(item)}
    Object.assign(item,{
      event_id:eventId,title,url,sources,source_evidence:sourceEvidence,source_count:sourceCount,drafted_source_count:sourceCount,
      selected_at:now,status:"PROCESSING",selection_mode:"TTENDENCIAS_USER",revision:Number(candidate.revision||item.revision||1),
      with_image:true,image_mode:"ai_plus_fallback",trend_origin:true,trend_names:candidate.trend_names||[],
      trend_context:candidate.trend_context||[],trend_explanation:String(candidate.explanation||"")
    });
    delete item.problem_reason;delete item.problematic_at;delete item.dismissed_at;delete item.delivered_at;
    doc.updated_at=now;return doc
  });
  await markTrendCandidate(wanted,"promoted",{ttittulares_event_id:eventId,promoted_source:"web_check"});
  return {ok:true,candidate_id:wanted,event_id:eventId,status:"PROCESSING"}
}

async function proxyPreparedImage(rawUrl,res){
  const url=String(rawUrl||"");let parsed;
  try{parsed=new URL(url)}catch(_){throw new Error("URL de imagen no válida")}
  if(parsed.protocol!=="https:")throw new Error("Solo se permiten imágenes HTTPS");
  const [{doc:prepared},{doc:tremending}]=await Promise.all([readPublicJson(PREPARED),readPublicJson(TREMENDING)]);
  const allowed=new Set([
    ...(prepared.items||[]).flatMap(x=>[x?.image?.url||x?.image_url,x?.ai_image?.url,x?.fallback_image?.url]),
    ...(tremending.items||[]).map(x=>x?.image?.url)
  ].filter(Boolean).map(String));
  if(!allowed.has(url))throw new Error("Imagen no autorizada");
  const r=await fetch(url,{headers:{"user-agent":"TTiTTulares-Image-Proxy/1.0",accept:"image/*"}});
  if(!r.ok)throw new Error("No se pudo descargar la imagen: "+r.status);
  const type=String(r.headers.get("content-type")||"");
  if(!type.startsWith("image/"))throw new Error("El recurso no es una imagen");
  const buf=Buffer.from(await r.arrayBuffer());
  if(buf.length>12*1024*1024)throw new Error("Imagen demasiado grande");
  res.setHeader("content-type",type);res.setHeader("content-length",String(buf.length));
  return res.status(200).send(buf)
}
async function backendStatus(){
  const [config,status]=await Promise.all([
    gh(`contents/ttittulares/config.json?ref=${encodeURIComponent(BRANCH)}`),
    gh(`contents/ttittulares/status.json?ref=${encodeURIComponent(BRANCH)}`)
  ]);
  return {ok:config.ok&&status.ok,status:config.ok&&status.ok?200:503}
}
// Persist one editable score for the exact prepared tweet and revision. No client-supplied text.
async function rateTitularRemate(key, score){
  const ratingKey=String(key||"").trim(),rating=Number(score);
  if(!/^titular-remate-v2:[a-f0-9]{24}$/.test(ratingKey)||!Number.isInteger(rating)||rating<1||rating>5){
    const error=new Error("Envía el remate del tuit y una valoración entera de 1 a 5.");error.statusCode=400;throw error;
  }
  const {doc:prepared}=await readJson(PREPARED);
  let item=null,variant=null;
  for(const candidate of prepared.items||[]){
    const match=titularRemateVariants(candidate).find(v=>titularRemateIdentity(candidate,v)===ratingKey);
    if(match){item=candidate;variant=match;break}
  }
  if(!item){const error=new Error("Esta variante ya no está disponible o su texto ha cambiado.");error.statusCode=409;throw error}
  const now=new Date().toISOString();let saved;
  await mutateJson(REMATE_RATINGS,"TTiTTulares: valorar remate único",doc=>{
    doc.project||="TTiTTulares";doc.version||=1;doc.items||=[];
    let record=doc.items.find(r=>r.key===ratingKey);
    if(record&&record.rating===rating){saved=record;return doc}
    const next=buildTitularRemateRecord(item,variant,rating,now);
    if(record){Object.assign(record,next,{created_at:record.created_at||now});saved=record}
    else{doc.items.push(next);saved=next}
    doc.updated_at=now;
    return doc;
  });
  return {ok:true,rating_key:ratingKey,rating:saved.rating,rated_at:saved.updated_at};
}

export default async function handler(req,res){
  res.setHeader("cache-control","no-store");
  try{
    if(req.method==="GET"){
      if(String(req.query?.view||"")==="image-proxy")return await proxyPreparedImage(req.query?.url,res);
      const [prepared,status,config,queue,events,decisions,manualArchive,trendCandidates,remateRatings,tremending]=await Promise.all([
        readJson(PREPARED),readPublicJson("ttittulares/status.json"),readPublicJson("ttittulares/config.json"),
        readPublicJson(PROCESSING),readPublicJson(EVENTS),readJson(DECISIONS),readPublicJson(MANUAL_ARCHIVE),readPublicJson(TREND_CANDIDATES),readPublicJson(REMATE_RATINGS),readPublicJson(TREMENDING)
      ]);
      const eventMap=new Map((events.doc?.events||[]).map(e=>[String(e.id||e.event_id||""),e]));
      const closedIds=new Set((decisions.doc?.items||[])
        .filter(x=>["published","dismissed"].includes(String(x.status||"").toLowerCase()))
        .map(x=>String(x.event_id||"")));
      const rewritePendingPrepared=(prepared.doc?.items||[]).filter(x=>Boolean(x.rewrite_pending)&&!closedIds.has(String(x.event_id||"")));
      const rewritePendingIds=new Set(rewritePendingPrepared.map(x=>String(x.event_id||"")));
      const processingIds=new Set([
        ...(queue.doc?.items||[]).filter(x=>String(x.status||"")==="PROCESSING").map(x=>String(x.event_id||"")),
        ...rewritePendingIds
      ]);
      const activeRewriteIds=new Set([
        ...(queue.doc?.items||[]).filter(x=>String(x.status||"")==="PROCESSING"&&String(x.selection_mode||"")==="REWRITE").map(x=>String(x.event_id||"")),
        ...rewritePendingIds
      ]);
      // rewrite_pending en prepared es autoritativo: si la escritura del gran
      // fichero PROCESSING falla, la reelaboración sigue existiendo y debe
      // mostrarse en En elaboración, nunca volver a Listas.
      const visiblePrepared=(prepared.doc?.items||[]).filter(x=>!closedIds.has(String(x.event_id||""))&&!activeRewriteIds.has(String(x.event_id||""))&&!x.rewrite_pending);
      const preparedIds=new Set(visiblePrepared.map(x=>String(x.event_id||"")));
      const manualStories=manualArchive.doc?.items||[];
      const queueProcessing=(queue.doc?.items||[]).filter(x=>String(x.status||"")==="PROCESSING"&&!preparedIds.has(String(x.event_id||""))&&!closedIds.has(String(x.event_id||""))).map(x=>{
        const ev=eventMap.get(String(x.event_id||""))||{};
        return {
          event_id:String(x.event_id||""),
          title:String(x.title||ev.canonical_title||ev.title||""),
          url:String(x.url||ev.url||""),
          selected_at:x.selected_at||null,
          selection_mode:x.selection_mode||null,
          rewrite_version:x.rewrite_version||null,
          trend_origin:Boolean(x.trend_origin||ev.trend_origin),
          trend_names:Array.isArray(x.trend_names)?x.trend_names:(Array.isArray(ev.trend_names)?ev.trend_names:[]),
          source_count:Number(ev.source_count||x.source_count||0),
          sources:Array.isArray(ev.sources)?ev.sources:(Array.isArray(x.sources)?x.sources:[])
        }
      });
      const queueProcessingIds=new Set(queueProcessing.map(x=>String(x.event_id||"")));
      const syntheticRewrites=rewritePendingPrepared
        .filter(x=>!queueProcessingIds.has(String(x.event_id||"")))
        .map(x=>({
          event_id:String(x.event_id||""),
          title:String(x.title||""),
          url:String(x.url||""),
          selected_at:x.rewrite_requested_at||x.prepared_at||null,
          selection_mode:"REWRITE",
          rewrite_version:Number(x.rewrite_request_version||x.rewrite_version||1),
          trend_origin:Boolean(x.trend_origin),
          trend_names:Array.isArray(x.trend_names)?x.trend_names:[],
          source_count:Number(x.drafted_source_count||0),
          sources:Array.isArray(x.sources_at_draft)?x.sources_at_draft:[],
          rewrite_pending_source:"prepared"
        }));
      const processingItems=[...queueProcessing,...syntheticRewrites];
      const problematicItems=(queue.doc?.items||[]).filter(x=>String(x.status||"")==="PROBLEMATIC"&&!preparedIds.has(String(x.event_id||""))&&!closedIds.has(String(x.event_id||""))).map(x=>{
        const ev=eventMap.get(String(x.event_id||""))||{};
        return {
          event_id:String(x.event_id||""),
          title:String(x.title||ev.canonical_title||ev.title||""),
          url:String(x.url||ev.url||""),
          selected_at:x.selected_at||null,
          problematic_at:x.problematic_at||null,
          problem_reason:String(x.problem_reason||""),
          problematic_attempts:Number(x.problematic_attempts||1),
          user_validated:Boolean(x.user_validated),
          user_validated_at:x.user_validated_at||null,
          trend_origin:Boolean(x.trend_origin||ev.trend_origin),
          trend_names:Array.isArray(x.trend_names)?x.trend_names:(Array.isArray(ev.trend_names)?ev.trend_names:[]),
          source_count:Number(ev.source_count||x.source_count||0),
          sources:Array.isArray(ev.sources)?ev.sources:(Array.isArray(x.sources)?x.sources:[])
        }
      }).sort((a,b)=>String(b.problematic_at||b.selected_at||"").localeCompare(String(a.problematic_at||a.selected_at||"")));
      const trendCandidateItems=(trendCandidates.doc?.items||[])
        .filter(x=>["candidate","pending",""].includes(String(x.status||"").toLowerCase()))
        .map(x=>({
          candidate_id:trendCandidateId(x),
          event_id:idOf(x.event_id||x.ttittulares_event_id),
          title:String(x.title||x.news_title||"Posible noticia desde TTendencias"),
          explanation:String(x.explanation||""),
          url:String(x.url||x.source_url||""),
          trend_names:Array.isArray(x.trend_names)?x.trend_names:[],
          search_terms:Array.isArray(x.search_terms)?x.search_terms:(Array.isArray(x.trend_names)?x.trend_names:[]),
          source_count:Number(x.source_count||(Array.isArray(x.sources)?x.sources.length:0)),
          sources:Array.isArray(x.sources)?x.sources:[],
          source_evidence:Array.isArray(x.source_evidence)?x.source_evidence:[],
          detected_at:x.detected_at||x.created_at||x.updated_at||null,
          origin:"TTendencias"
        }))
        .sort((a,b)=>String(b.detected_at||"").localeCompare(String(a.detected_at||"")));
      const visibleWaitingEvent=e=>{
        const id=String(e.id||e.event_id||"");
        return ["WAITING","UPDATE_WAITING"].includes(String(e.status||""))
          &&!processingIds.has(id)
          &&!preparedIds.has(id)
          &&!closedIds.has(id)
          &&!manualStories.some(m=>storyMatches(m,e))
      };
      const oneSourceCount=(events.doc?.events||[]).filter(e=>Number(e.source_count||0)===1&&visibleWaitingEvent(e)).length;
      const twoSourceCount=(events.doc?.events||[]).filter(e=>Number(e.source_count||0)===2&&visibleWaitingEvent(e)).length;
      const threeSourceItems=(events.doc?.events||[]).filter(e=>{
        return Number(e.source_count||0)===3&&visibleWaitingEvent(e)
      }).map(e=>({
        event_id:String(e.id||e.event_id||""),
        title:String(e.canonical_title||e.title||""),
        url:String(e.url||""),
        source_count:Number(e.source_count||0),
        sources:Array.isArray(e.sources)?e.sources:[],
        first_seen:e.first_seen||null,
        source3_minutes:threeSourceSpeedMinutes(e)
      })).sort((a,b)=>{
        const av=Number.isFinite(a.source3_minutes)?a.source3_minutes:Number.MAX_SAFE_INTEGER;
        const bv=Number.isFinite(b.source3_minutes)?b.source3_minutes:Number.MAX_SAFE_INTEGER;
        return av-bv||String(b.first_seen||"").localeCompare(String(a.first_seen||""))
      });
      const liveStatus={...(status.doc||{}),processing_count:processingItems.length,processing_items:processingItems,problematic_count:problematicItems.length+trendCandidateItems.length,problematic_items:problematicItems,trend_candidates_count:trendCandidateItems.length,trend_candidates:trendCandidateItems,ready_count:visiblePrepared.length,one_source_count:oneSourceCount,two_source_count:twoSourceCount,three_source_count:threeSourceItems.length,three_source_items:threeSourceItems};
      const tremendingItems=(tremending.doc?.items||[]).map(x=>({
        id:tremendingEntryId(x.id),title:String(x.title||"Entrada sin título"),url:String(x.url||""),description:String(x.description||""),published_at:x.published_at||null,first_seen_at:x.first_seen_at||null,last_seen_at:x.last_seen_at||null,status:String(x.status||"pending"),destinations:Array.isArray(x.destinations)?x.destinations:[],tweets:Array.isArray(x.tweets)?x.tweets:[],selected_tweet_id:x.selected_tweet_id||null,image:x.image||{status:"not_selected"},article_status:x.article_status||"pending"
      })).filter(x=>x.id).sort((a,b)=>String(b.published_at||b.first_seen_at||"").localeCompare(String(a.published_at||a.first_seen_at||"")));
      return res.status(200).json({ok:true,service:"ttittulares-control",prepared:annotateTitularRemates({...(prepared.doc||{}),items:visiblePrepared},remateRatings.doc),status:liveStatus,config:config.doc,tremending:{...(tremending.doc||{}),items:tremendingItems}})
    }
    if(req.method!=="POST")return res.status(405).json({ok:false,error:"Método no permitido"});
    if(!authorized(req))return res.status(401).json({ok:false,error:"No autorizado"});
    const body=req.body||{},action=String(body.action||"");
    if(action==="ping"){const backend=await backendStatus();return res.status(backend.ok?200:503).json({ok:backend.ok,access:"granted",backend})}
    if(action==="rate-remate")return res.status(200).json(await rateTitularRemate(body.rating_key,body.rating));
    if(action==="published")return res.status(200).json(await closePrepared(body.event_id,"published"));
    if(action==="dismiss")return res.status(200).json(await closePrepared(body.event_id,"dismissed"));
    if(action==="rework")return res.status(200).json(await rework(body.event_id,body.instruction,body.reinvestigate===true));
    if(action==="regenerate-image")return res.status(200).json(await requestImageRegeneration(body.event_id));
    if(action==="use-fallback-image")return res.status(200).json(await useFallbackImage(body.event_id));
    if(action==="check")return res.status(200).json(await markUserValidated(body.event_id));
    if(action==="select-tremending-tweet")return res.status(200).json(await selectTremendingTweet(body.entry_id,body.tweet_id));
    if(action==="send-tremending")return res.status(200).json(await sendTremending(body.entry_id,body.destination));
    if(action==="postpone-tremending")return res.status(200).json(await markTremending(body.entry_id,"postponed"));
    if(action==="reactivate-tremending")return res.status(200).json(await markTremending(body.entry_id,"pending"));
    if(action==="discard-tremending")return res.status(200).json(await markTremending(body.entry_id,"discarded"));
    if(action==="promote-trend")return res.status(200).json(await promoteTrendCandidate(body.candidate_id));
    if(action==="dismiss-trend")return res.status(200).json(await dismissTrendCandidate(body.candidate_id));
    if(action==="prepare3")return res.status(200).json(await manualPrepare(body.event_id));
    if(action==="submit")return res.status(200).json(await submitManualStory(body.url,body.title,body.instruction));
    return res.status(400).json({ok:false,error:"Acción no válida"})
  }catch(e){console.error(e);return res.status(Number(e?.statusCode)||500).json({ok:false,error:String(e.message||e)})}
}

