// deploy-sync: mobile-run-worker-contract-v20-20261004
import crypto from "node:crypto";
import sharp from "sharp";

const CONTROL_TOKEN_HASHES=[
  "2663da5223c2313c3670a7843a0cdfabfd2dd7c8fad1ed168247866a3b1262e5",
  "083d41ffcc41b14d52d426412b1ed44a8d4958b351ee110bdcc5a0eec167b840",
  "cdaa00313ab7f8031d485ac42ec8bb5d22eadf41a27e719848c8c6fcf40f3c98"
];
function authToken(req){
  const h=String(req.headers.authorization||"");
  const bearer=h.startsWith("Bearer ")?h.slice(7).trim():"";
  if(bearer)return bearer;
  return String(req.body?.access||"").trim();
}
function authorized(req){
  if(process.env.VERCEL_ENV==="preview")return true;
  const got=authToken(req);if(!got)return false;
  const expected=process.env.TTITTULARES_CONTROL_TOKEN||"";
  if(expected&&got===expected)return true;
  const digest=Buffer.from(crypto.createHash("sha256").update(got).digest("hex"));
  return CONTROL_TOKEN_HASHES.some(hash=>crypto.timingSafeEqual(digest,Buffer.from(hash)));
}

const REPO=process.env.GITHUB_REPO||"fabricelop/europapress-rss";
const PR=2;
const TRIGGER_BRANCH="control/ttittulares-run-trigger-v2";
const TRIGGER_PATH="ttittulares/run-now-trigger.json";
const ACK_PATH="ttittulares/run-ack.json";
const IMAGE_RUN_INDEX_PATH="ttittulares/image-runs/index.json";
const IMAGE_RUN_DIR="ttittulares/image-runs/jobs";
const IMAGE_HANDOFF_ACTIVE_MS=45*1000;
const IMAGE_GENERATION_ACTIVE_MS=150*1000;
const MAIN_BRANCH="main";
const PREPARED_PATH="ttittulares/prepared.json";
const CROSS_IMAGE_STATE_PATH="trends/telegram-manual-explained.json";
const RASTER_REGISTRY_PATH="shared/image-raster-registry.json";

const IMAGE_STYLE_BASE="PRINCIPIO FIJO: más gag, menos barroquismo. Una sola idea visual fuerte, lectura inmediata en 1-2 segundos, composición limpia, uno a tres elementos protagonistas y fondo solo si ayuda. Acabado cuidado y rico en dibujo, pero sin acumulación decorativa. El gag nace del hecho/remate y no se limita a ilustrar literalmente el titular. Casi sin texto; solo el imprescindible para el gag. ";
const IMAGE_STYLE_BANK=[
  ["tinta_acuarela","Caricatura editorial contemporánea de alta calidad, línea de tinta expresiva y acuarela controlada, gestos muy trabajados y fondo ligero."],
  ["comic_europeo","Cómic europeo contemporáneo, entintado preciso, volumen sólido, expresiones fuertes y composición dinámica pero despejada."],
  ["poster_grafico","Póster gráfico editorial sofisticado, formas contundentes, geometría limpia, textura de impresión y jerarquía visual muy clara; no aspecto infantil."],
  ["absurdo_semirrealista","Escena absurda semi-realista, materiales y texturas cuidados, iluminación natural y situación imposible tratada con precisión visual."],
  ["stop_motion","Diorama editorial tipo stop-motion/clay, personajes y objetos con volumen artesanal, iluminación de estudio y detalle selectivo."],
  ["retro_60s","Ilustración publicitaria retro de los años 60 reinterpretada con acabado moderno, dibujo elegante, ironía visual y composición limpia."],
  ["grabado_moderno","Grabado o linograbado moderno de alta calidad, textura rica, contraste controlado y un único foco narrativo."],
  ["pop_art","Pop art editorial refinado, serigrafía y tramas controladas, energía gráfica sin llenar la escena de elementos."],
  ["cartoon_3d","Cartoon 3D editorial estilizado, modelado cuidado, expresiones claras, materiales pulidos y escena sencilla pero no simplona."],
  ["novela_grafica","Novela gráfica satírica, dibujo detallado, sombras contenidas, gesto expresivo y puesta en escena sobria."]
];
function imageStyleFor(seed){
  const h=crypto.createHash("sha256").update(String(seed||"")).digest();
  const index=h.readUInt32BE(0)%IMAGE_STYLE_BANK.length;
  const [name,detail]=IMAGE_STYLE_BANK[index];
  return {index,name,text:IMAGE_STYLE_BASE+"ESTILO ASIGNADO PARA ESTA IMAGEN: "+detail};
}
const STATUS_PREFIX="RUNSTATUS ";
const TRACE_PREFIX="TTITTULARES_RUNTRACE_V1\n";
const ACTIVE_MS=20*60*1000;
const PROCESSING_ACTIVE_MS=5*60*1000;

async function gh(url,options={}){
  if(!process.env.GITHUB_TOKEN)throw new Error("GITHUB_TOKEN no configurado");
  return fetch(url,{...options,headers:{
    accept:"application/vnd.github+json",
    authorization:`Bearer ${process.env.GITHUB_TOKEN}`,
    "x-github-api-version":"2022-11-28",
    "user-agent":"ttittulares-run-now",
    ...(options.headers||{})
  }})
}
let commentsCache={at:0,items:[]};
async function comments(){
  const now=Date.now();
  if(now-commentsCache.at<30000)return commentsCache.items;
  const since=new Date(now-12*60*60*1000).toISOString();
  try{
    const r=await gh(`https://api.github.com/repos/${REPO}/issues/${PR}/comments?per_page=100&since=${encodeURIComponent(since)}`);
    if(!r.ok)return commentsCache.items;
    const items=await r.json();
    commentsCache={at:now,items};
    return items
  }catch(_){return commentsCache.items}
}
async function triggerReady(){return true}
async function readControlRaw(path){
  try{
    const clean=String(path||"").split("/").map(encodeURIComponent).join("/");
    const u=`https://raw.githubusercontent.com/${REPO}/${encodeURIComponent(TRIGGER_BRANCH)}/${clean}?t=${Date.now()}`;
    const r=await fetch(u,{cache:"no-store",headers:{"user-agent":"ttittulares-run-read"}});
    if(!r.ok)return null;
    return JSON.parse(await r.text()||"{}")
  }catch(_){return null}
}
async function readTrigger(){
  const u=`https://api.github.com/repos/${REPO}/contents/${TRIGGER_PATH}?ref=${encodeURIComponent(TRIGGER_BRANCH)}&t=${Date.now()}`;
  const r=await gh(u,{cache:"no-store",headers:{"cache-control":"no-cache"}});
  if(!r.ok)throw new Error(`GitHub trigger GET: ${r.status} ${await r.text()}`);
  const f=await r.json();
  const raw=Buffer.from(String(f.content||"").replace(/\n/g,""),"base64").toString("utf8");
  return {sha:f.sha,doc:JSON.parse(raw||"{}")}
}
function field(body,name){
  const m=String(body||"").match(new RegExp("^"+name+":\\s*(.+)$","mi"));
  return m?m[1].trim():null
}
function stamp(v){const n=Date.parse(v||"");return Number.isFinite(n)?n:0}
function traceOf(comment){
  const body=String(comment?.body||"");
  if(!body.startsWith(TRACE_PREFIX))return null;
  try{return {...JSON.parse(body.slice(TRACE_PREFIX.length).trim()),comment_id:comment.id,comment_updated_at:comment.updated_at||comment.created_at}}catch(_){return null}
}
function activeTrace(items){
  // Un mismo run puede escribir varios comentarios RUNTRACE (RUNNING -> DONE).
  // El estado autoritativo de cada run es siempre su comentario más reciente.
  const latestByRun=new Map();
  for(const t of items.map(traceOf).filter(Boolean)){
    const key=String(t.run_id||t.command_id||t.comment_id||"");
    const at=stamp(t.comment_updated_at||t.updated_at||t.started_at||t.requested_at);
    const prev=latestByRun.get(key);
    const prevAt=prev?stamp(prev.comment_updated_at||prev.updated_at||prev.started_at||prev.requested_at):0;
    if(!prev||at>=prevAt)latestByRun.set(key,t);
  }
  const fresh=[...latestByRun.values()].filter(t=>["REQUESTED","RUNNING","PROCESSING"].includes(String(t.status||"").toUpperCase())).filter(t=>{
    const age=Date.now()-stamp(t.comment_updated_at||t.updated_at||t.started_at||t.requested_at);
    const limit=String(t.status||"").toUpperCase()==="PROCESSING"?PROCESSING_ACTIVE_MS:ACTIVE_MS;
    return Number.isFinite(age)&&age>=0&&age<limit
  });
  fresh.sort((a,b)=>stamp(a.comment_updated_at||a.updated_at)-stamp(b.comment_updated_at||b.updated_at));
  return fresh.at(-1)||null
}
function newerRunAfter(items,requestedAt){
  const t=stamp(requestedAt);
  if(!t)return null;
  return items.map(traceOf).filter(Boolean)
    // El RUNTRACE que consume un trigger puede conservar exactamente el mismo
    // requested_at que la orden móvil. Aceptamos el mismo ciclo (±2 s) además
    // de ejecuciones claramente posteriores.
    .filter(x=>stamp(x.started_at||x.requested_at||x.comment_updated_at)>=t-2000)
    .sort((a,b)=>stamp(a.started_at||a.requested_at)-stamp(b.started_at||b.requested_at))
    .at(-1)||null
}
async function writeTrigger(doc,sha){
  const body={
    message:`Solicitar ejecución PC Chat TTiTTulares ${doc.command_id}`,
    content:Buffer.from(JSON.stringify(doc,null,2)+"\n","utf8").toString("base64"),
    sha,
    branch:TRIGGER_BRANCH
  };
  const r=await gh(`https://api.github.com/repos/${REPO}/contents/${TRIGGER_PATH}`,{
    method:"PUT",headers:{"content-type":"application/json"},body:JSON.stringify(body)
  });
  if(!r.ok)throw new Error(`GitHub trigger PUT: ${r.status} ${await r.text()}`);
  return r.json()
}

function gitBlobSha(buf){
  const head=Buffer.from("blob "+buf.length+"\0","utf8");
  return crypto.createHash("sha1").update(head).update(buf).digest("hex")
}
async function readRawJsonWithSha(path,branch){
  // raw.githubusercontent espera el nombre de rama directamente. Anteponer
  // refs/heads/ hace que ramas con "/" puedan resolverse de forma obsoleta/ambigua.
  const refPath=String(branch||"main").split("/").map(encodeURIComponent).join("/");
  const filePath=String(path||"").split("/").map(encodeURIComponent).join("/");
  const url="https://raw.githubusercontent.com/"+REPO+"/"+refPath+"/"+filePath+"?t="+Date.now();
  const r=await fetch(url,{cache:"no-store",headers:{"user-agent":"TTiTTulares-Control-Raw/1.0","cache-control":"no-cache"}});
  if(r.status===404)return {sha:null,doc:null};
  if(!r.ok)throw new Error("GitHub raw GET "+path+": "+r.status+" "+await r.text());
  const buf=Buffer.from(await r.arrayBuffer());
  return {sha:gitBlobSha(buf),doc:JSON.parse(buf.toString("utf8")||"{}")}
}
async function readControlJson(path){
  return readRawJsonWithSha(path,TRIGGER_BRANCH)
}
// El ciclo de imagen no puede validar secretos contra RAW/CDN: puede devolver
// durante unos segundos el job anterior y provocar falsos 401. Usamos Contents
// API solo en lecturas de control de imagen (bajo volumen), igual que TTendencias.
async function readControlJsonAuthoritative(path){
  const filePath=String(path||"").split("/").map(encodeURIComponent).join("/");
  const ref=encodeURIComponent(TRIGGER_BRANCH);
  const r=await gh("https://api.github.com/repos/"+REPO+"/contents/"+filePath+"?ref="+ref,{cache:"no-store",headers:{"cache-control":"no-cache"}});
  if(r.status===404)return {sha:null,doc:null};
  if(!r.ok)throw new Error("GitHub control authoritative GET "+path+": "+r.status+" "+await r.text());
  const j=await r.json();
  const raw=Buffer.from(String(j.content||"").replace(/\s/g,""),"base64").toString("utf8");
  return {sha:String(j.sha||"")||null,doc:JSON.parse(raw||"{}")}
}
async function writeControlJson(path,doc,sha,message){
  const body={message,content:Buffer.from(JSON.stringify(doc,null,2)+"\n","utf8").toString("base64"),branch:TRIGGER_BRANCH};
  if(sha)body.sha=sha;
  const r=await gh("https://api.github.com/repos/"+REPO+"/contents/"+path,{method:"PUT",headers:{"content-type":"application/json"},body:JSON.stringify(body)});
  if(!r.ok)throw new Error("GitHub control PUT "+path+": "+r.status+" "+await r.text());
  return r.json()
}

async function readMainJsonWithSha(path){
  return readRawJsonWithSha(path,MAIN_BRANCH)
}
async function readMainJson(path){
  const x=await readMainJsonWithSha(path);
  return x.doc||{}
}
async function writeMainJson(path,doc,sha,message){
  const body={message,content:Buffer.from(JSON.stringify(doc,null,2)+"\n","utf8").toString("base64"),branch:MAIN_BRANCH};
  if(sha)body.sha=sha;
  const r=await gh("https://api.github.com/repos/"+REPO+"/contents/"+path,{method:"PUT",headers:{"content-type":"application/json"},body:JSON.stringify(body)});
  if(!r.ok)throw new Error("GitHub main PUT "+path+": "+r.status+" "+await r.text());
  return r.json()
}
async function writeMainBinary(path,buf,message){
  const body={message,content:Buffer.from(buf).toString("base64"),branch:MAIN_BRANCH};
  const r=await gh("https://api.github.com/repos/"+REPO+"/contents/"+path,{method:"PUT",headers:{"content-type":"application/json"},body:JSON.stringify(body)});
  if(!r.ok)throw new Error("GitHub main binary PUT "+path+": "+r.status+" "+await r.text());
  return r.json()
}
function validChatAi(image){
  return Boolean(image&&image.generated===true&&image.provider==="chat-imagegen"&&image.origin==="executing_chat"&&String(image.url||"").trim())
}
async function imageEligibility(targetId){
  const prepared=await readMainJson(PREPARED_PATH);
  const rows=(prepared.items||[]).filter(x=>String(x.event_id||"")===String(targetId));
  rows.sort((a,b)=>Number(b.revision||0)-Number(a.revision||0)||String(b.prepared_at||"").localeCompare(String(a.prepared_at||"")));
  const row=rows[0]||null;
  if(!row)return {eligible:false,reason:"not_ready",row:null};
  const mode=String(row.image_mode||row.image_strategy||"").toLowerCase();
  // La sensibilidad editorial y los flags legacy disable/fallback_only/archive_only
  // no bloquean ImageGen. Tremending/tweet_capture conserva su flujo específico.
  if(row.tremending_origin||mode==="tweet_capture_only")return {eligible:false,reason:"tremending",row};
  const hasAi=validChatAi(row.ai_image)||validChatAi(row.image);
  // Una IA existente nunca bloquea un nuevo gag. La anterior se conserva hasta
  // que la nueva se materialice correctamente.
  return {eligible:true,reason:hasAi?"regenerate":"ready",row,hasAi}
}
function uploadSecretHash(value){return crypto.createHash("sha256").update(String(value||""),"utf8").digest("hex")}
function validUploadSecret(job,secret){
  const expected=String(job?.pc_upload_secret_hash||"").toLowerCase(),actual=uploadSecretHash(secret);
  if(!/^[a-f0-9]{64}$/.test(expected)||String(secret||"").length<32)return false;
  return crypto.timingSafeEqual(Buffer.from(expected,"hex"),Buffer.from(actual,"hex"))
}

async function claimRasterContext({project,target_id,revision,command_id,sha256}){
  const hash=String(sha256||"").toLowerCase();
  if(!/^[a-f0-9]{64}$/.test(hash))throw new Error("invalid_raster_sha256");

  // Backfill guard: inspect both editorial stores, so hashes created before the
  // shared registry existed are also protected across TTendencias/TTiTTulares.
  const [trendState,headlineState]=await Promise.all([
    readMainJson("trends/telegram-manual-explained.json"),
    readMainJson("ttittulares/prepared.json")
  ]);
  const uses=[];
  for(const row of trendState.items||[]){
    const image=row.ai_image||((row.image&&row.image.generated)?row.image:null);
    const h=String(image?.sha256||"").toLowerCase();
    if(h===hash)uses.push({
      project:"ttendencias",target_id:String(row.id||""),revision:Number(row.revision||0),
      command_id:String(image?.context_guard?.command_id||"")
    });
  }
  for(const row of headlineState.items||[]){
    const image=row.ai_image||((row.image&&row.image.generated)?row.image:null);
    const h=String(image?.sha256||"").toLowerCase();
    if(h===hash)uses.push({
      project:"ttittulares",target_id:String(row.event_id||""),revision:Number(row.revision||0),
      command_id:String(image?.context_guard?.command_id||"")
    });
  }
  for(const use of uses){
    const same=use.project===project&&use.target_id===String(target_id)&&use.command_id===String(command_id);
    if(!same)throw new Error("cross_context_raster_reuse");
  }

  // Atomic shared claim. GitHub blob SHA gives us cross-project serialization:
  // two concurrent contexts cannot both claim the same raster hash.
  for(let n=0;n<7;n++){
    const reg=await readMainJsonWithSha(RASTER_REGISTRY_PATH);
    const doc=reg.doc||{version:1,updated_at:null,entries:{}};
    if(!doc.entries||typeof doc.entries!=="object")doc.entries={};
    const existing=doc.entries[hash];
    if(existing){
      const same=String(existing.project||"")===project &&
        String(existing.target_id||"")===String(target_id) &&
        String(existing.command_id||"")===String(command_id);
      if(same)return existing;
      throw new Error("cross_context_raster_reuse");
    }
    const claim={
      project,target_id:String(target_id),revision:Number(revision||0),command_id:String(command_id),
      claimed_at:new Date().toISOString()
    };
    doc.entries[hash]=claim;
    doc.updated_at=new Date().toISOString();
    try{
      await writeMainJson(RASTER_REGISTRY_PATH,doc,reg.sha,"Claim ImageGen raster "+hash.slice(0,12)+" "+project+" "+target_id);
      return claim
    }catch(e){
      if(n===6||!/409|422/.test(String(e)))throw e;
      await new Promise(r=>setTimeout(r,180*(n+1)));
    }
  }
  throw new Error("raster_registry_claim_failed");
}
async function markPreparedImageFailed(target_id,revision,reason){
  for(let n=0;n<5;n++){
    const p=await readMainJsonWithSha(PREPARED_PATH);
    const doc=p.doc||{project:"TTiTTulares",items:[]};
    const row=(doc.items||[]).find(x=>String(x.event_id||"")===target_id&&Number(x.revision||0)===Number(revision));
    if(!row)return;
    const hadAi=validChatAi(row.ai_image)||validChatAi(row.image);
    row.ai_image_last_attempt_status="failed";
    row.ai_image_last_attempt_at=new Date().toISOString();
    if(hadAi){
      row.ai_image_status="ready";
      row.ai_image_regeneration_error=String(reason||"image_job_failed").slice(0,240);
      delete row.ai_image_failure_reason;
    }else{
      row.ai_image_status="failed";
      row.ai_image_failure_reason=String(reason||"image_job_failed").slice(0,240);
      delete row.ai_image_regeneration_error;
    }
    delete row.ai_image_regenerate_requested;
    delete row.ai_image_regenerate_requested_at;
    delete row.ai_image_regenerate_request_version;
    doc.updated_at=new Date().toISOString();
    try{await writeMainJson(PREPARED_PATH,doc,p.sha,"TTiTTulares: registrar fallo Gag IA "+target_id);return}
    catch(e){if(n===4||!/409|422/.test(String(e)))throw e;await new Promise(r=>setTimeout(r,200*(n+1)))}
  }
}
async function persistAiImageDirect({target_id,revision,command_id,buf,mime,sha256,width,height,bytes}){
  await claimRasterContext({project:"ttittulares",target_id,revision,command_id,sha256});
  let current=await readMainJsonWithSha(PREPARED_PATH);
  const row0=(current.doc?.items||[]).find(x=>String(x.event_id||"")===target_id&&Number(x.revision||0)===Number(revision));
  if(!row0)throw new Error("not_ready");
  const previousAttempt=Math.max(0,Number(row0.ai_image_attempt||0)||0);
  const previousWasReal=Boolean(row0.ai_image_tool_called_at||validChatAi(row0.ai_image)||validChatAi(row0.image));
  const attempt=previousWasReal?Math.max(1,previousAttempt+1):Math.max(1,previousAttempt||1);
  const ext=mime==="image/png"?"png":mime==="image/webp"?"webp":"jpg";
  const suffix=command_id.replace(/[^A-Za-z0-9_-]/g,"").slice(-12)||Date.now();
  const imagePath="ttittulares/generated-images/"+target_id+"-r"+revision+"-ai"+attempt+"-"+suffix+"."+ext;
  await writeMainBinary(imagePath,buf,"TTiTTulares: guardar raster ImageGen "+target_id);

  const rawUrl="https://raw.githubusercontent.com/"+REPO+"/main/"+imagePath;
  const sourceUrl="https://github.com/"+REPO+"/blob/main/"+imagePath;
  const ai={
    url:rawUrl,source:"TTiTTulares / ChatGPT ImageGen",rights_status:"generated",generated:true,
    provider:"chat-imagegen",origin:"executing_chat",generation_attempt:attempt,
    sha256,width,height,bytes,
    context_guard:{version:3,event_id:target_id,revision,scope:"current_item_only",command_id},
    source_url:sourceUrl,handoff:"pc-bridge-direct-materialized"
  };

  let updated=false;
  for(let n=0;n<6;n++){
    const p=await readMainJsonWithSha(PREPARED_PATH);
    const doc=p.doc||{project:"TTiTTulares",items:[]};
    const items=Array.isArray(doc.items)?doc.items:[];
    const row=items.find(x=>String(x.event_id||"")===target_id&&Number(x.revision||0)===Number(revision));
    if(!row)throw new Error("not_ready");
    const collision=items.find(x=>String(x.event_id||"")!==target_id&&String(x.ai_image?.sha256||"").toLowerCase()===sha256.toLowerCase());
    if(collision)throw new Error("cross_context_raster_reuse");
    const now=new Date().toISOString();
    row.ai_image=ai;
    row.ai_image_status="ready";
    row.ai_image_attempt=attempt;
    row.ai_image_tool_called_at=row.ai_image_tool_called_at||now;
    row.ai_image_last_attempt_status="ready";
    row.ai_image_last_attempt_at=now;
    delete row.ai_image_failure_reason;
    delete row.ai_image_regeneration_error;
    delete row.ai_image_regenerate_requested;
    delete row.ai_image_regenerate_requested_at;
    delete row.ai_image_regenerate_request_version;
    row.image={...ai};
    row.image_choice="ai";
    row.image_status="ready";
    row.image_pending=false;
    row.image_app_available=true;
    row.image_delivery="app";
    doc.updated_at=now;
    try{await writeMainJson(PREPARED_PATH,doc,p.sha,"TTiTTulares: adjuntar Gag IA "+target_id);updated=true;break}
    catch(e){if(n===5||!/409|422/.test(String(e)))throw e;await new Promise(r=>setTimeout(r,250*(n+1)))}
  }
  if(!updated)throw new Error("No se pudo actualizar prepared con la imagen");
  return {imagePath,ai,attempt}
}

async function requestPcAck(req,res){
  const command_id=String(req.body?.command_id||"").trim();
  const stage=String(req.body?.stage||"").toLowerCase();
  const worker_id=String(req.body?.worker_id||"legacy-shared-listener").trim().slice(0,120)||"legacy-shared-listener";
  const workerMatch=worker_id.match(/^ttittulares-dedicated-v(\\d+)$/);
  const workerVersion=workerMatch?Number(workerMatch[1]):0;
  if(workerVersion<19)return res.status(409).json({ok:false,error:"stale_worker",minimum_worker:"ttittulares-dedicated-v19",worker_id});
  const detail=String(req.body?.detail||"").trim().slice(0,1000);
  if(!command_id||!["picked_up","launched","failed"].includes(stage))return res.status(400).json({ok:false,error:"Ack no válido"});
  const {doc:trigger}=await readTrigger();
  if(String(trigger.command_id||"")!==command_id){console.log("TTI_PC_ACK_MISMATCH",{incoming:command_id,current:String(trigger.command_id||""),requested_at:trigger.requested_at||null});return res.status(409).json({ok:false,error:"command_id ya no es el actual",incoming:command_id,current:String(trigger.command_id||"")});}
  const requested_at=String(trigger.requested_at||"");
  const age=Date.now()-stamp(requested_at);
  if(!stamp(requested_at)||age<0||age>7*24*60*60*1000)return res.status(409).json({ok:false,error:"Trigger fuera de ventana"});

  const existing=await readControlJson(ACK_PATH);
  const previous=existing.doc||{};
  const same=String(previous.command_id||"")===command_id;
  const previousWorker=String(previous.worker_id||"");
  const previousStage=String(previous.stage||"").toLowerCase();
  const previousPickedAt=stamp(previous.picked_up_at||previous.updated_at);
  const claimFresh=same&&previousPickedAt&&Date.now()-previousPickedAt<30000;
  const launchedByOther=same&&previousStage==="launched"&&previousWorker&&previousWorker!==worker_id;
  const freshClaimByOther=same&&claimFresh&&previousWorker&&previousWorker!==worker_id;

  if(stage==="picked_up"&&(launchedByOther||freshClaimByOther)){
    return res.status(409).json({
      ok:false,error:"claimed_by_other_worker",command_id,
      worker_id:previousWorker,stage:previousStage||"picked_up",
      picked_up_at:previous.picked_up_at||null,launched_at:previous.launched_at||null
    })
  }
  if(["launched","failed"].includes(stage)&&same&&previousWorker&&previousWorker!==worker_id){
    return res.status(409).json({ok:false,error:"claim_not_owned",command_id,worker_id:previousWorker})
  }

  const now=new Date().toISOString();
  const preservePickup=same&&previousWorker===worker_id&&previous.picked_up_at;
  const doc={
    version:2,command_id,requested_at,worker_id,stage,
    picked_up_at:preservePickup?previous.picked_up_at:now,
    launched_at:stage==="launched"?now:(same&&previousWorker===worker_id?previous.launched_at||null:null),
    failed_at:stage==="failed"?now:(same&&previousWorker===worker_id?previous.failed_at||null:null),
    detail:stage==="failed"?detail:(same&&previousWorker===worker_id?previous.detail||null:null),
    updated_at:now
  };
  await writeControlJson(ACK_PATH,doc,existing.sha,"PC Chat ack TTiTTulares "+stage+" "+command_id+" "+worker_id);
  return res.status(200).json({ok:true,claimed:true,...doc})
}

function safeTargetId(v){
  const id=String(v||"").trim();
  if(!/^[A-Za-z0-9._-]{3,160}$/.test(id))throw new Error("target_id inválido");
  return id
}
async function requestImagePcAck(req,res){
  const target_id=safeTargetId(req.body?.target_id||req.body?.event_id||req.body?.id);
  const command_id=String(req.body?.command_id||"").trim();
  const stage=String(req.body?.stage||"").toLowerCase();
  const worker_id=String(req.body?.worker_id||"ttittulares-image-bridge-v1").trim().slice(0,120)||"ttittulares-image-bridge-v1";
  if(!command_id||!["picked_up","progress","launched","cancelled","failed","done"].includes(stage))return res.status(400).json({ok:false,error:"Ack imagen no válido"});
  const path=IMAGE_RUN_DIR+"/"+target_id+".json";
  const existing=await readControlJsonAuthoritative(path),job=existing.doc||{};
  if(String(job.command_id||"")!==command_id)return res.status(409).json({ok:false,error:"command_id de imagen ya no es actual"});
  if(["DONE","ERROR","CANCELLED","SUPERSEDED"].includes(String(job.status||"").toUpperCase())){
    return res.status(200).json({ok:true,idempotent:true,target_id,command_id,status:job.status,phase:job.phase||null});
  }

  if(stage==="picked_up"){
    const uploadHash=String(req.body?.upload_secret_hash||"").toLowerCase();
    if(!/^[a-f0-9]{64}$/.test(uploadHash))return res.status(400).json({ok:false,error:"upload_secret_hash requerido"});
    if(job.pc_upload_secret_hash&&String(job.pc_upload_secret_hash)!==uploadHash)return res.status(409).json({ok:false,error:"job ya reclamado con otro secreto"});
    job.pc_upload_secret_hash=uploadHash;
    const eligible=await imageEligibility(target_id);
    const revisionChanged=Boolean(eligible.row)&&Number(eligible.row.revision||0)!==Number(job.revision||0);
    if(!eligible.eligible||revisionChanged){
      const now=new Date().toISOString(),reason=revisionChanged?"revision_changed":eligible.reason;
      const cancelled={...job,status:"CANCELLED",phase:"stale_target",updated_at:now,finished_at:now,pc_worker_id:worker_id,message:"Cancelado antes de abrir chat: "+reason};
      await writeControlJson(path,cancelled,existing.sha,"Cancelar Gag IA obsoleto TTiTTulares "+target_id+" "+command_id);
      return res.status(409).json({ok:false,error:"stale_target",reason,status:"CANCELLED",target_id,command_id})
    }
  }

  const now=new Date().toISOString(),next={...job,updated_at:now,pc_worker_id:worker_id};
  const secret=String(req.body?.upload_secret||"");
  if(["done","failed"].includes(stage)&&job.pc_upload_secret_hash&&!validUploadSecret(job,secret))return res.status(401).json({ok:false,error:"Secreto de imagen no válido"});
  if(stage==="cancelled"){
    next.status="CANCELLED";next.phase="stale_target";next.finished_at=now;
    next.message=String(req.body?.reason||"La entrada ya no está vigente.").slice(0,240);
  }else if(stage==="done"){
    const prepared=await readMainJson(PREPARED_PATH);
    const persisted=(prepared.items||[]).find(x=>String(x.event_id||"")===target_id&&Number(x.revision||0)===Number(job.revision||0)&&String(x.ai_image?.context_guard?.command_id||"")===command_id&&String(x.ai_image?.url||"").trim());
    if(!persisted)return res.status(409).json({ok:false,error:"image_not_persisted_yet"});
    next.status="DONE";next.phase="done";next.finished_at=now;next.message="Gag IA materializado y visible en Listas.";
  }else if(stage==="failed"){
    const reason=String(req.body?.reason||"El puente de imagen no pudo completar el trabajo.").slice(0,240);
    next.status="ERROR";next.phase=job.upload_sha256?"image_bridge_failed":"pc_launch_failed";next.finished_at=now;next.message=reason;
    await markPreparedImageFailed(target_id,job.revision,reason).catch(()=>{});
  }else if(stage==="progress"){
    const phase=String(req.body?.phase||"pc_progress").trim().slice(0,80)||"pc_progress";
    const detail=String(req.body?.detail||"").trim().slice(0,240);
    next.status="RUNNING";next.phase=phase;next.pc_picked_up_at=job.pc_picked_up_at||now;
    next.message=detail||("Progreso de imagen: "+phase);
  }else{
    next.status="RUNNING";next.phase=stage==="picked_up"?"pc_pickup":"pc_launch";
    if(stage==="picked_up")next.pc_picked_up_at=job.pc_picked_up_at||now;
    if(stage==="launched"){next.pc_picked_up_at=job.pc_picked_up_at||now;next.pc_launched_at=now}
    next.message=stage==="picked_up"?"PC ha recogido la solicitud de imagen.":"Prompt enviado en la pestaña fija; esperando ImageGen.";
  }
  // ACKs del bridge pueden solaparse (picked_up/progress/launched). Un 409 de SHA
  // no debe convertir un avance válido en ERROR ni provocar una tormenta de reintentos.
  // Releemos el job actual y reaplicamos SOLO este cambio, preservando cualquier avance
  // concurrente más reciente. Los estados terminales del mismo command_id son idempotentes.
  let writeBase=existing,writeNext=next;
  for(let attempt=0;attempt<5;attempt++){
    try{
      await writeControlJson(path,writeNext,writeBase.sha,"PC Chat Gag IA TTiTTulares "+stage+" "+target_id+" "+command_id);
      return res.status(200).json({ok:true,...writeNext})
    }catch(e){
      if(!/409/.test(String(e)))throw e;
      // No gastar una lectura REST adicional para resolver el conflicto: cuando
      // GitHub está en rate-limit esa lectura convertía un 409 recuperable en 500.
      // picked_up es el único ACK que DEBE persistir antes de abrir el bridge,
      // porque fija el secreto de subida. El listener lo reintentará en su próximo
      // sondeo. progress/launched son telemetría y no deben bloquear ImageGen.
      if(stage==="picked_up"){
        return res.status(409).json({ok:false,retryable:true,error:"ack_write_conflict",target_id,command_id,stage});
      }
      if(stage==="progress"||stage==="launched"){
        return res.status(200).json({ok:true,deferred:true,target_id,command_id,stage,message:"ACK telemétrico diferido por conflicto GitHub"});
      }
      if(attempt===4)throw e;
      await new Promise(r=>setTimeout(r,120*(attempt+1)));
      writeBase=await readControlJsonAuthoritative(path);
      if(String(writeBase.doc?.command_id||"")!==command_id){
        return res.status(409).json({ok:false,error:"command_id de imagen ya no es actual"});
      }
      writeNext={...writeBase.doc,...writeNext,updated_at:new Date().toISOString(),pc_worker_id:worker_id};
    }
  }
}

async function requestImageUpload(req,res){
  const target_id=safeTargetId(req.body?.target_id||req.body?.event_id||req.body?.id);
  const command_id=String(req.body?.command_id||"").trim(),upload_secret=String(req.body?.upload_secret||""),data=String(req.body?.image_data_url||"");
  const captureMethod=String(req.body?.capture?.method||"");
  const captureFromImage=/^(original-fetch-img|canvas-from-img-)/.test(captureMethod);
  if(!command_id||!upload_secret||!data.startsWith("data:image/"))return res.status(400).json({ok:false,error:"Carga de imagen incompleta"});
  if(!captureFromImage)return res.status(422).json({ok:false,error:"Raster rechazado: el bridge no acredita captura del elemento de imagen",capture_method:captureMethod||null});
  if(data.length>4*1024*1024)return res.status(413).json({ok:false,error:"Raster codificado demasiado grande"});
  const path=IMAGE_RUN_DIR+"/"+target_id+".json";
  const existing=await readControlJsonAuthoritative(path),job=existing.doc||{};
  if(String(job.command_id||"")!==command_id)return res.status(409).json({ok:false,error:"command_id ya no es actual"});
  if(!validUploadSecret(job,upload_secret))return res.status(401).json({ok:false,error:"Secreto de imagen no válido"});
  if(["DONE","ERROR","CANCELLED","SUPERSEDED"].includes(String(job.status||"").toUpperCase()))return res.status(409).json({ok:false,error:"job terminal",status:job.status});
  const eligible=await imageEligibility(target_id);
  const revisionChanged=Boolean(eligible.row)&&Number(eligible.row.revision||0)!==Number(job.revision||0);
  if(!eligible.eligible||revisionChanged)return res.status(409).json({ok:false,error:"target_no_elegible",reason:revisionChanged?"revision_changed":eligible.reason});
  const m=data.match(/^data:(image\/(?:jpeg|png|webp));base64,([A-Za-z0-9+/=]+)$/);
  if(!m)return res.status(400).json({ok:false,error:"Formato de raster no admitido"});
  const buf=Buffer.from(m[2],"base64");
  if(buf.length<12000||buf.length>3*1024*1024)return res.status(400).json({ok:false,error:"Tamaño de raster no válido",bytes:buf.length});
  const meta=await sharp(buf,{animated:false}).metadata(),width=Number(meta.width||0),height=Number(meta.height||0);
  if(width<640||height<360)return res.status(400).json({ok:false,error:"Raster inferior a 640x360",width,height});
  // La geometría puede variar según la salida real de ImageGen. La garantía
  // importante es que el bridge v10 haya extraído un <img> real, nunca una card,
  // canvas genérico o captura del viewport de ChatGPT.
  const aspect=height?width/height:0;
  if(aspect<0.65||aspect>2.40){
    return res.status(422).json({ok:false,error:"Raster rechazado: geometría anómala",width,height,aspect:Number(aspect.toFixed(3))});
  }
  const sha256=crypto.createHash("sha256").update(buf).digest("hex"),now=new Date().toISOString();
  const persisting={...job,status:"PERSISTING",phase:"image_persist",updated_at:now,upload_received_at:now,upload_sha256:sha256,upload_bytes:buf.length,message:"Raster recibido; guardando Gag IA en main."};
  const persistWrite=await writeControlJson(path,persisting,existing.sha,"TTiTTulares raster recibido "+command_id);
  const persisted=await persistAiImageDirect({target_id,revision:Number(job.revision||0),command_id,buf,mime:m[1],sha256,width,height,bytes:buf.length});
  // Igual que TTendencias: persistAiImageDirect ya confirma que el PNG y prepared.json
  // están escritos en main. Cerrar aquí evita una segunda lectura que puede llegar
  // atrasada y convertir una imagen válida en un falso ERROR.
  const doneAt=new Date().toISOString();
  const done={...persisting,status:"DONE",phase:"done",updated_at:doneAt,finished_at:doneAt,message:"Gag IA materializado y visible en Listas."};
  const persistSha=persistWrite?.content?.sha||persistWrite?.content?.git_url?.split("/").pop()||null;
  if(persistSha){
    await writeControlJson(path,done,persistSha,"TTiTTulares imagen IA completada "+command_id);
  }else{
    const fresh=await readControlJsonAuthoritative(path);
    await writeControlJson(path,done,fresh.sha,"TTiTTulares imagen IA completada "+command_id);
  }
  return res.status(200).json({ok:true,status:"DONE",target_id,command_id,image_path:persisted.imagePath,attempt:persisted.attempt,sha256,width,height,bytes:buf.length})
}

async function requestImageRun(req,res){
  const target_id=safeTargetId(req.body?.target_id||req.body?.event_id);
  const requestedRevision=Math.max(0,Number.parseInt(req.body?.revision??1,10)||1);
  const eligible=await imageEligibility(target_id);
  if(!eligible.eligible)return res.status(409).json({ok:false,error:"target_no_elegible",reason:eligible.reason,target_id});
  const row=eligible.row||{},revision=Number(row.revision||1);
  if(revision!==requestedRevision)return res.status(409).json({ok:false,error:"target_no_elegible",reason:"revision_changed",target_id,revision});
  const target_name=String(row.title||req.body?.target_name||"").trim().slice(0,240);
  const stylePick=imageStyleFor("ttittulares|"+target_id+"|r"+revision+"|"+Date.now());
  const context_snapshot={
    title:target_name,revision,
    factual_summary:String(row.factual_summary||"").trim(),
    tweet_text:String(row.tweet?.text||"").trim(),
    remate:String(row.tweet?.remate||"").trim(),
    url:String(row.url||"").trim(),
    citations:Array.isArray(row.citations)?row.citations.slice(0,8):[],
    image_style:stylePick.text,
    image_style_name:stylePick.name,
    image_style_index:stylePick.index
  };
  const jobPath=IMAGE_RUN_DIR+"/"+target_id+".json",existing=await readControlJsonAuthoritative(jobPath),previous=existing.doc||{};
  const status=String(previous.status||"").toUpperCase(),phase=String(previous.phase||"").toLowerCase();
  const at=stamp(previous.updated_at||previous.finished_at||previous.requested_at),age=at?Date.now()-at:Infinity;
  const active=status==="REQUESTED"?age<30000:status==="RUNNING"&&["pc_pickup","pc_launch"].includes(phase)?age<IMAGE_HANDOFF_ACTIVE_MS:["RUNNING","GENERATING","PERSISTING"].includes(status)&&age<IMAGE_GENERATION_ACTIVE_MS;
  if(active)return res.status(409).json({ok:false,error:"image_run_in_progress",command_id:previous.command_id||null,target_id,status});
  const requested_at=new Date().toISOString(),command_id="tt-img-"+Date.now()+"-"+crypto.randomBytes(3).toString("hex");
  const doc={
    version:1,command_id,requested_at,updated_at:requested_at,status:"REQUESTED",phase:"queued",
    mode:"manual_pc_chat_image",executor:"pc_chat_ttittulares_dedicated",project:"ttittulares",launcher_arg:"titulares",
    task:"image",target_id,event_id:target_id,target_name,revision,regenerate:Boolean(eligible.hasAi),chat_command_version:5,
    instruction_profile:"ttittulares_gag_v9_varied_style_single_gag",context_snapshot,
    instructions:{
      scope:"Genera UNA sola imagen IA para esta noticia y no proceses ninguna otra entrada.",
      context:"Usa context_snapshot como contexto factual autoritativo. No reinvestigues ni reescribas la noticia.",
      visual:"Más gag, menos barroquismo: una sola idea visual fuerte, pocos elementos y acabado cuidado. Respeta image_style del context_snapshot; en regeneraciones el estilo puede cambiar.",
      sensitivity:"No conviertas víctimas, muertes, duelo, violencia grave, abuso, menores en contexto sensible o sufrimiento humano en objeto del gag.",
      political_guard:"Si el contexto es político, mantén el gag en la situación factual descrita; no inventes acusaciones, propaganda, llamadas al voto ni juicios partidistas como hechos.",
      lifecycle:"El listener envía el mensaje y el bridge capture-only persiste exactamente el raster generado."
    },
    message:"Solicitud registrada; esperando al PC."
  };
  const saved=await writeControlJson(jobPath,doc,existing.sha,"Solicitar Gag IA TTiTTulares "+target_id+" "+command_id);
  for(let n=0;n<3;n++){
    const idx=await readControlJsonAuthoritative(IMAGE_RUN_INDEX_PATH),base=idx.doc&&Array.isArray(idx.doc.jobs)?idx.doc:{version:1,jobs:[]};
    const jobs=base.jobs.filter(x=>String(x.command_id||"")!==command_id&&String(x.target_id||"")!==target_id);
    jobs.push({command_id,target_id,event_id:target_id,target_name,revision,requested_at,status_path:jobPath,executor:"pc_chat_ttittulares_dedicated"});
    try{await writeControlJson(IMAGE_RUN_INDEX_PATH,{version:1,updated_at:requested_at,jobs:jobs.slice(-60)},idx.sha,"Actualizar cola Gag IA TTiTTulares");break}
    catch(e){if(n===2||!/409|422/.test(String(e)))throw e}
  }
  return res.status(200).json({ok:true,task:"images",image_run:true,command_id,requested_at,target_id,target_name,revision,status_path:jobPath,commit_sha:saved?.commit?.sha||null})
}

export default async function handler(req,res){
  res.setHeader("cache-control","no-store");
  if(req.method!=="POST")return res.status(405).json({ok:false,error:"Método no permitido"});
  const rawTask=String(req.body?.task||"editorial").toLowerCase();
  if(rawTask==="pc_ack"){
    try{return await requestPcAck(req,res)}
    catch(e){console.error(e);return res.status(500).json({ok:false,error:String(e.message||e)})}
  }
  if(rawTask==="image_pc_ack"){
    try{return await requestImagePcAck(req,res)}
    catch(e){console.error(e);return res.status(500).json({ok:false,error:String(e.message||e)})}
  }
  if(rawTask==="image_upload"){
    try{return await requestImageUpload(req,res)}
    catch(e){console.error(e);return res.status(500).json({ok:false,error:String(e.message||e)})}
  }
  if(!authorized(req))return res.status(401).json({ok:false,error:"No autorizado"});
  try{
    const task=rawTask==="images"?"images":"editorial";
    if(task==="images")return await requestImageRun(req,res);
    const [{doc:current,sha},items,ackState]=await Promise.all([readTrigger(),comments(),readControlJson(ACK_PATH)]);
    if(activeTrace(items))return res.status(409).json({ok:false,error:"run_in_progress"});
    const currentId=String(current.command_id||"").trim(),currentRequested=String(current.requested_at||"").trim();
    if(currentId&&currentRequested){
      const age=Date.now()-new Date(currentRequested).getTime();
      const consumedBy=newerRunAfter(items,currentRequested);
      const marks=items.filter(c=>String(c.body||"").startsWith(STATUS_PREFIX+currentId+"\n")),last=marks.at(-1),st=last?field(last.body,"status"):"REQUESTED";
      const ack=ackState.doc||{};
      const ackMatches=String(ack.command_id||"")===currentId;
      const ackStage=ackMatches?String(ack.stage||"").toLowerCase():"";
      const ackAt=ackMatches?stamp(ack.updated_at||ack.launched_at||ack.picked_up_at):0;
      // Igual que TTendencias: picked_up solo prueba que el PC vio la orden.
      // Si no llega a launched en 45 s, no debe bloquear nuevas pulsaciones.
      const ackWindow=ackStage==="picked_up"?45000:ackStage==="launched"?6*60*1000:ACTIVE_MS;
      const ackFresh=ackMatches&&ackAt&&Date.now()-ackAt<ackWindow;

      // 45 s cubre holgadamente el SLA visual de 30 s. Si pasado ese tiempo no hay
      // ACK ni RUNNING, la orden anterior está muerta y una pulsación nueva debe poder
      // reemplazarla; no la bloqueamos 20 minutos.
      if(!consumedBy&&Number.isFinite(age)&&age<45000)return res.status(429).json({ok:false,error:"recent_request",retry_after_seconds:Math.ceil((45000-age)/1000)});
      if(!consumedBy&&String(st||"").toUpperCase()==="RUNNING")return res.status(409).json({ok:false,error:"run_in_progress"});
      if(!consumedBy&&ackFresh&&["picked_up","launched"].includes(ackStage))return res.status(409).json({ok:false,error:"run_in_progress"});
    }
    const requested_at=new Date().toISOString();
    const command_id=`tt-${Date.now()}-${crypto.randomBytes(3).toString("hex")}`;
    const doc={version:2,command_id,requested_at,mode:"manual_pc_chat",executor:"pc_chat_ttittulares_dedicated",project:"ttittulares",launcher_arg:"titulares",task,auto_image_followup:false};
    let saved;
    try{saved=await writeTrigger(doc,sha)}
    catch(e){
      if(!String(e.message||e).includes("409")&&!String(e.message||e).includes("422"))throw e;
      const fresh=await readTrigger();saved=await writeTrigger(doc,fresh.sha)
    }
    return res.status(200).json({ok:true,command_id,requested_at,commit_sha:saved?.commit?.sha||null,trace_comment_id:null,trigger:"pc_chat_poll",task})
  }catch(e){
    console.error(e);
    return res.status(500).json({ok:false,error:String(e.message||e)})
  }
}
