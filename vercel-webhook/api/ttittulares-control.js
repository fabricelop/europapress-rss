import crypto from "node:crypto";

const REPO=process.env.GITHUB_REPO||"fabricelop/europapress-rss";
const BRANCH=process.env.GITHUB_BRANCH||"main";
const PREPARED="ttittulares/prepared.json";
const DECISIONS="ttittulares/decisions.json";
const PROCESSING="telegram/editorial-processing.json";
const EVENTS="telegram/events.json";
const MANUAL_ARCHIVE="ttittulares/manual-submissions.json";
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
  const r=await gh(`contents/${path}?ref=${encodeURIComponent(BRANCH)}`);
  if(!r.ok)throw new Error(`GitHub GET ${path}: ${r.status} ${await r.text()}`);
  const f=await r.json();return {doc:JSON.parse(b64d(f.content)||"{}"),sha:f.sha}
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
  return at.length>=20&&bt.length>=20&&at===bt
}
function manualEventId(url,title){
  const base=canonicalUrl(url)||normalizedTitle(title);
  return "manual-"+crypto.createHash("sha256").update(base).digest("hex").slice(0,12)
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
  await mutateJson(DECISIONS,`${status==="published"?"Publicar":"Desestimar"} TTiTTulares desde web`,doc=>{
    doc.project||="TTiTTulares";doc.items||=[];
    const old=doc.items.find(x=>idOf(x.event_id)===id);
    if(old)Object.assign(old,{status,updated_at:now});
    else doc.items.push({event_id:id,status,updated_at:now});
    doc.updated_at=now;return doc
  });
  await mutateJson(PREPARED,"Retirar noticia cerrada de TTiTTulares web",doc=>{
    doc.items=(doc.items||[]).filter(x=>idOf(x.event_id)!==id);doc.updated_at=now;return doc
  });
  await mutateJson(PROCESSING,"Actualizar cierre web TTiTTulares",doc=>{
    for(const item of doc.items||[])if(idOf(item.event_id)===id){
      item.status=status==="published"?"PUBLISHED":"DISMISSED";
      item[status==="published"?"published_at":"dismissed_at"]=now
    }
    doc.updated_at=now;return doc
  });
  await mutateJson(EVENTS,"Cerrar evento TTiTTulares desde web",doc=>{
    for(const event of doc.events||[])if(idOf(event.id||event.event_id)===id){
      event.status=status==="published"?"PUBLISHED":"DISMISSED";
      event[status==="published"?"published_at":"dismissed_at"]=now
    }
    doc.updated_at=now;return doc
  });
  await mutateJson(MANUAL_ARCHIVE,"Actualizar archivo manual TTiTTulares",doc=>{
    doc.items||=[];
    for(const item of doc.items)if(idOf(item.event_id)===id){
      item.status=status.toUpperCase();item.updated_at=now
    }
    doc.updated_at=now;return doc
  });
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
async function rework(eventId,instruction){
  const id=idOf(eventId),text=String(instruction||"").trim();
  if(!id)throw new Error("Falta event_id");if(!text)throw new Error("Escribe las instrucciones para rehacer.");
  const now=new Date().toISOString();
  const {doc:prepared}=await readJson(PREPARED);
  const source=(prepared.items||[]).find(x=>idOf(x.event_id)===id)||{};
  await mutateJson(PROCESSING,"Rehacer noticia TTiTTulares desde web",doc=>{
    doc.items||=[];let item=[...doc.items].reverse().find(x=>idOf(x.event_id)===id);
    if(!item){
      item={event_id:id,title:source.title||"",url:source.url||"",sources:source.sources_at_draft||[],source_count:Number(source.drafted_source_count||0),selected_at:now};
      doc.items.push(item)
    }
    item.previous_status=item.status;item.status="PROCESSING";item.selection_mode="REWRITE";item.with_image=true;item.image_mode="generated_gag_or_archive_sensitive";item.image_instruction="Genera por defecto un gag editorial visual; usa archive_sensitive solo para muerte, lesión grave o traumática, accidente serio, violencia, abuso, catástrofe o sufrimiento humano significativo. Una lesión deportiva ordinaria no activa archive_sensitive.";
    item.rewrite_request=text;item.rewrite_requested_at=now;item.rewrite_version=Number(item.rewrite_version||0)+1;
    item.revision=Number(item.revision||source.revision||1)+1;delete item.delivered_at;delete item.published_at;delete item.dismissed_at;
    doc.updated_at=now;return doc
  });
  await mutateJson(PREPARED,"Retirar versión antigua para rehacer TTiTTulares",doc=>{
    doc.items=(doc.items||[]).filter(x=>idOf(x.event_id)!==id);doc.updated_at=now;return doc
  });
  await mutateJson(DECISIONS,"Reabrir noticia TTiTTulares desde web",doc=>{
    doc.items=(doc.items||[]).filter(x=>idOf(x.event_id)!==id);doc.updated_at=now;return doc
  });
  await mutateJson(EVENTS,"Marcar noticia TTiTTulares en elaboración",doc=>{
    for(const event of doc.events||[])if(idOf(event.id||event.event_id)===id){
      event.status="PROCESSING";event.processing_at=now
    }
    doc.updated_at=now;return doc
  });
  return {ok:true,event_id:id,status:"PROCESSING"}
}
async function submitManualStory(url,title,instruction){
  const cleanUrl=canonicalUrl(url),cleanTitle=String(title||"").trim(),note=String(instruction||"").trim();
  if(!cleanUrl&&!cleanTitle)throw new Error("Pega un enlace o escribe un titular");
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
      selected_at:now,status:"PROCESSING",selection_mode:"MANUAL_WEB_USER",manual_submission:true,revision:Number(item.revision||1),with_image:true,image_mode:"generated_gag_or_archive_sensitive"
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
      image_mode:"generated_gag_or_archive_sensitive"
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

async function proxyPreparedImage(rawUrl,res){
  const url=String(rawUrl||"");let parsed;
  try{parsed=new URL(url)}catch(_){throw new Error("URL de imagen no válida")}
  if(parsed.protocol!=="https:")throw new Error("Solo se permiten imágenes HTTPS");
  const {doc:prepared}=await readJson(PREPARED);
  const allowed=new Set((prepared.items||[]).map(x=>x?.image?.url||x?.image_url).filter(Boolean).map(String));
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
export default async function handler(req,res){
  res.setHeader("cache-control","no-store");
  try{
    if(req.method==="GET"){
      if(String(req.query?.view||"")==="image-proxy")return await proxyPreparedImage(req.query?.url,res);
      const [prepared,status,config,queue,events,decisions,manualArchive]=await Promise.all([
        readJson(PREPARED),readJson("ttittulares/status.json"),readJson("ttittulares/config.json"),
        readJson(PROCESSING),readJson(EVENTS),readJson(DECISIONS),readJson(MANUAL_ARCHIVE)
      ]);
      const eventMap=new Map((events.doc?.events||[]).map(e=>[String(e.id||e.event_id||""),e]));
      const closedIds=new Set((decisions.doc?.items||[])
        .filter(x=>["published","dismissed"].includes(String(x.status||"").toLowerCase()))
        .map(x=>String(x.event_id||"")));
      const visiblePrepared=(prepared.doc?.items||[]).filter(x=>!closedIds.has(String(x.event_id||"")));
      const preparedIds=new Set(visiblePrepared.map(x=>String(x.event_id||"")));
      const processingIds=new Set((queue.doc?.items||[]).filter(x=>String(x.status||"")==="PROCESSING").map(x=>String(x.event_id||"")));
      const manualStories=manualArchive.doc?.items||[];
      const processingItems=(queue.doc?.items||[]).filter(x=>String(x.status||"")==="PROCESSING"&&!preparedIds.has(String(x.event_id||""))&&!closedIds.has(String(x.event_id||""))).map(x=>{
        const ev=eventMap.get(String(x.event_id||""))||{};
        return {
          event_id:String(x.event_id||""),
          title:String(x.title||ev.canonical_title||ev.title||""),
          url:String(x.url||ev.url||""),
          selected_at:x.selected_at||null,
          selection_mode:x.selection_mode||null,
          rewrite_version:x.rewrite_version||null,
          source_count:Number(ev.source_count||x.source_count||0),
          sources:Array.isArray(ev.sources)?ev.sources:(Array.isArray(x.sources)?x.sources:[])
        }
      });
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
          source_count:Number(ev.source_count||x.source_count||0),
          sources:Array.isArray(ev.sources)?ev.sources:(Array.isArray(x.sources)?x.sources:[])
        }
      }).sort((a,b)=>String(b.problematic_at||b.selected_at||"").localeCompare(String(a.problematic_at||a.selected_at||"")));
      const threeSourceItems=(events.doc?.events||[]).filter(e=>{
        const id=String(e.id||e.event_id||"");
        return Number(e.source_count||0)===3
          &&["WAITING","UPDATE_WAITING"].includes(String(e.status||""))
          &&!processingIds.has(id)
          &&!preparedIds.has(id)
          &&!closedIds.has(id)
          &&!manualStories.some(m=>storyMatches(m,e))
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
      const liveStatus={...(status.doc||{}),processing_count:processingItems.length,processing_items:processingItems,problematic_count:problematicItems.length,problematic_items:problematicItems,ready_count:visiblePrepared.length,three_source_count:threeSourceItems.length,three_source_items:threeSourceItems};
      return res.status(200).json({ok:true,service:"ttittulares-control",prepared:{...(prepared.doc||{}),items:visiblePrepared},status:liveStatus,config:config.doc})
    }
    if(req.method!=="POST")return res.status(405).json({ok:false,error:"Método no permitido"});
    if(!authorized(req))return res.status(401).json({ok:false,error:"No autorizado"});
    const body=req.body||{},action=String(body.action||"");
    if(action==="ping"){const backend=await backendStatus();return res.status(backend.ok?200:503).json({ok:backend.ok,access:"granted",backend})}
    if(action==="published")return res.status(200).json(await closePrepared(body.event_id,"published"));
    if(action==="dismiss")return res.status(200).json(await closePrepared(body.event_id,"dismissed"));
    if(action==="rework")return res.status(200).json(await rework(body.event_id,body.instruction));
    if(action==="check")return res.status(200).json(await markUserValidated(body.event_id));
    if(action==="prepare3")return res.status(200).json(await manualPrepare(body.event_id));
    if(action==="submit")return res.status(200).json(await submitManualStory(body.url,body.title,body.instruction));
    return res.status(400).json({ok:false,error:"Acción no válida"})
  }catch(e){console.error(e);return res.status(500).json({ok:false,error:String(e.message||e)})}
}
