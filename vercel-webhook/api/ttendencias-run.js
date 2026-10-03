import crypto from "node:crypto";
import sharp from "sharp";

const CONTROL_TOKEN_HASHES=[
  "2663da5223c2313c3670a7843a0cdfabfd2dd7c8fad1ed168247866a3b1262e5",
  "e6dc803e75f1bad2c6caee93b1a7fce3df540f70c8313a7e08a998506d0dcb61"
];
function authToken(req){const h=String(req.headers.authorization||"");const bearer=h.startsWith("Bearer ")?h.slice(7).trim():"";if(bearer)return bearer;return String(req.body?.access||"").trim()}
function authorized(req){
  if(process.env.VERCEL_ENV==="preview")return true;
  const got=authToken(req);if(!got)return false;
  const expected=process.env.TTENDENCIAS_CONTROL_TOKEN||"";
  if(expected&&got===expected)return true;
  const digest=Buffer.from(crypto.createHash("sha256").update(got).digest("hex"));
  return CONTROL_TOKEN_HASHES.some(hash=>crypto.timingSafeEqual(digest,Buffer.from(hash)));
}
const REPO=process.env.GITHUB_REPO||"fabricelop/europapress-rss";
const PR=7;
const TRIGGER_BRANCH="control/ttendencias-run-trigger";
const TRIGGER_PATH="trends/run-now-trigger.json";
const ACK_PATH="trends/run-ack.json";
const IMAGE_RUN_INDEX_PATH="trends/image-runs/index.json";
const IMAGE_RUN_DIR="trends/image-runs/jobs";
const IMAGE_HANDOFF_ACTIVE_MS=45*1000;
const IMAGE_GENERATION_ACTIVE_MS=150*1000;
const STATUS_PREFIX="RUNSTATUS ";
const TRACE_PREFIX="TTENDENCIAS_RUNTRACE_V1\n";
const ACTIVE_MS=20*60*1000;
const PROCESSING_ACTIVE_MS=5*60*1000;
const MAIN_BRANCH="main";
const EXPLAINED_PATH="trends/telegram-manual-explained.json";
const EXPLAINED_COPY_STATE_PATH="trends/explained-copy-state.json";

async function gh(url,options={}){
  if(!process.env.GITHUB_TOKEN)throw new Error("GITHUB_TOKEN no configurado");
  return fetch(url,{...options,headers:{accept:"application/vnd.github+json",authorization:"Bearer "+process.env.GITHUB_TOKEN,"x-github-api-version":"2022-11-28","user-agent":"ttendencias-run-now",...(options.headers||{})}})
}
async function comments(){
  const since=new Date(Date.now()-24*60*60*1000).toISOString();
  let url="https://api.github.com/repos/"+REPO+"/issues/"+PR+"/comments?per_page=100&since="+encodeURIComponent(since);
  const items=[];
  for(let page=0;page<10&&url;page++){
    const r=await gh(url);if(!r.ok)throw new Error("GitHub comments: "+r.status+" "+await r.text());
    items.push(...await r.json());
    const next=(r.headers.get("link")||"").match(/<([^>]+)>;\s*rel="next"/);url=next?next[1]:null
  }
  return items
}
async function triggerReady(){return true}
async function readTrigger(){
  const r=await gh("https://api.github.com/repos/"+REPO+"/contents/"+TRIGGER_PATH+"?ref="+encodeURIComponent(TRIGGER_BRANCH));
  if(!r.ok)throw new Error("GitHub trigger GET: "+r.status+" "+await r.text());
  const f=await r.json(),raw=Buffer.from(String(f.content||"").replace(/\n/g,""),"base64").toString("utf8");
  return {sha:f.sha,doc:JSON.parse(raw||"{}")}
}
function field(body,name){const m=String(body||"").match(new RegExp("^"+name+":\\s*(.+)$","mi"));return m?m[1].trim():null}
function stamp(v){const n=Date.parse(v||"");return Number.isFinite(n)?n:0}
function traceOf(comment){
  const body=String(comment?.body||"");if(!body.startsWith(TRACE_PREFIX))return null;
  try{return {...JSON.parse(body.slice(TRACE_PREFIX.length).trim()),comment_id:comment.id,comment_updated_at:comment.updated_at||comment.created_at}}catch(_){return null}
}
function activeTrace(items){
  const fresh=items.map(traceOf).filter(Boolean).filter(t=>["REQUESTED","RUNNING","PROCESSING"].includes(String(t.status||"").toUpperCase())).filter(t=>{
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
  const r=await gh("https://api.github.com/repos/"+REPO+"/contents/"+TRIGGER_PATH,{method:"PUT",headers:{"content-type":"application/json"},body:JSON.stringify({message:"Solicitar ejecución PC Chat TTendencias "+doc.command_id,content:Buffer.from(JSON.stringify(doc,null,2)+"\n","utf8").toString("base64"),sha,branch:TRIGGER_BRANCH})});
  if(!r.ok)throw new Error("GitHub trigger PUT: "+r.status+" "+await r.text());return r.json()
}

async function readControlJson(path){
  const r=await gh("https://api.github.com/repos/"+REPO+"/contents/"+path+"?ref="+encodeURIComponent(TRIGGER_BRANCH));
  if(r.status===404)return {sha:null,doc:null};
  if(!r.ok)throw new Error("GitHub control GET "+path+": "+r.status+" "+await r.text());
  const f=await r.json(),raw=Buffer.from(String(f.content||"").replace(/\n/g,""),"base64").toString("utf8");
  return {sha:f.sha,doc:JSON.parse(raw||"{}")}
}
async function readMainJson(path){
  // Las lecturas editoriales para validar imágenes no necesitan la API REST autenticada.
  // RAW evita consumir cuota primaria; las escrituras siguen usando GitHub REST.
  try{
    const u="https://raw.githubusercontent.com/"+REPO+"/"+MAIN_BRANCH+"/"+path+"?t="+Date.now();
    const rr=await fetch(u,{cache:"no-store",headers:{"cache-control":"no-cache","user-agent":"ttendencias-run-main-read"}});
    if(rr.status===404)return {};
    if(rr.ok)return JSON.parse(await rr.text()||"{}");
  }catch(_){}
  // Fallback REST solo si RAW no está disponible.
  const rr=await gh("https://api.github.com/repos/"+REPO+"/contents/"+path+"?ref="+encodeURIComponent(MAIN_BRANCH));
  if(rr.status===404)return {};
  if(!rr.ok)throw new Error("GitHub main GET "+path+": "+rr.status+" "+await rr.text());
  const f=await rr.json(),raw=Buffer.from(String(f.content||"").replace(/\n/g,""),"base64").toString("utf8");
  return JSON.parse(raw||"{}")
}
async function imageEligibility(targetId){
  const [explained,copyState]=await Promise.all([readMainJson(EXPLAINED_PATH),readMainJson(EXPLAINED_COPY_STATE_PATH)]);
  const rows=(explained.items||[]).filter(x=>String(x.id||"")===String(targetId));
  rows.sort((a,b)=>Number(b.revision||0)-Number(a.revision||0)||String(b.explained_at||"").localeCompare(String(a.explained_at||"")));
  const row=rows[0]||null;
  if(!row||row.status==="grouped"||!String(row.explanation||"").trim())return {eligible:false,reason:"not_pending_explained",row};
  const name=String(row.name||"").trim(),rev=Number(row.revision||0);
  const archived=(copyState.items||[]).some(x=>Number(x.revision||0)===rev&&Array.isArray(x.trend_names)&&x.trend_names.some(n=>String(n||"").trim().toLowerCase()===name.toLowerCase()));
  const blockReason=String(row.ai_image_block_reason||row.image_block_reason||"").trim().toLowerCase();
  // Política y meteorología sin víctimas son material editorial válido para el gag.
  // Los casos con muertos/víctimas deben llegar marcados como sensitive_event u otro bloqueo explícito real.
  const advisoryOnlyBlock=["political_actor","political_context","safety_sensitive_weather"].includes(blockReason);
  const blocked=Boolean(row.tremending_origin)||Boolean(blockReason&&!advisoryOnlyBlock);
  const hasAi=Boolean(String(row.ai_image?.url||"").trim());
  return {eligible:!archived&&!blocked&&!hasAi,reason:archived?"archived":blocked?"blocked":hasAi?"already_has_ai":"pending",row}
}

async function writeControlJson(path,doc,sha,message){
  const body={message,content:Buffer.from(JSON.stringify(doc,null,2)+"\n","utf8").toString("base64"),branch:TRIGGER_BRANCH};
  if(sha)body.sha=sha;
  const r=await gh("https://api.github.com/repos/"+REPO+"/contents/"+path,{method:"PUT",headers:{"content-type":"application/json"},body:JSON.stringify(body)});
  if(!r.ok)throw new Error("GitHub control PUT "+path+": "+r.status+" "+await r.text());
  return r.json()
}
async function readMainJsonWithSha(path){
  const r=await gh("https://api.github.com/repos/"+REPO+"/contents/"+path+"?ref="+encodeURIComponent(MAIN_BRANCH));
  if(r.status===404)return {sha:null,doc:null};
  if(!r.ok)throw new Error("GitHub main GET "+path+": "+r.status+" "+await r.text());
  const f=await r.json(),raw=Buffer.from(String(f.content||"").replace(/\n/g,""),"base64").toString("utf8");
  return {sha:f.sha,doc:JSON.parse(raw||"{}")}
}
async function writeMainJson(path,doc,sha,message){
  const body={message,content:Buffer.from(JSON.stringify(doc,null,2)+"\n","utf8").toString("base64"),branch:MAIN_BRANCH};
  if(sha)body.sha=sha;
  const r=await gh("https://api.github.com/repos/"+REPO+"/contents/"+path,{method:"PUT",headers:{"content-type":"application/json"},body:JSON.stringify(body)});
  if(!r.ok)throw new Error("GitHub main PUT "+path+": "+r.status+" "+await r.text());
  return r.json()
}
async function writeMainBinary(path,buf,sha,message){
  const body={message,content:Buffer.from(buf).toString("base64"),branch:MAIN_BRANCH};
  if(sha)body.sha=sha;
  const r=await gh("https://api.github.com/repos/"+REPO+"/contents/"+path,{method:"PUT",headers:{"content-type":"application/json"},body:JSON.stringify(body)});
  if(!r.ok)throw new Error("GitHub main binary PUT "+path+": "+r.status+" "+await r.text());
  return r.json()
}
async function persistAiImageDirect({target_id,revision,attempt,command_id,buf,mime,sha256,width,height,bytes}){
  const ext=mime==="image/png"?"png":mime==="image/webp"?"webp":"jpg";
  const suffix=command_id.replace(/[^A-Za-z0-9_-]/g,"").slice(-12)||Date.now();
  const imagePath="trends/generated-images/"+target_id+"-r"+revision+"-ai"+attempt+"-"+suffix+"."+ext;
  const imageExisting=await readMainJsonWithSha(imagePath).catch(()=>({sha:null,doc:null}));
  // readMainJsonWithSha no sirve para binarios existentes; el nombre es único por command_id,
  // así que solo escribimos sin SHA y tratamos 422 como colisión imposible de nombre.
  if(imageExisting?.sha)throw new Error("generated_image_path_already_exists");
  await writeMainBinary(imagePath,buf,null,"TTendencias: guardar raster ImageGen "+target_id);

  const rawUrl="https://raw.githubusercontent.com/"+REPO+"/main/"+imagePath;
  const sourceUrl="https://github.com/"+REPO+"/blob/main/"+imagePath;
  const ai={
    url:rawUrl,source:"TTendencias / ChatGPT ImageGen",rights_status:"generated",generated:true,
    provider:"chat-imagegen",origin:"executing_chat",generation_attempt:attempt,
    sha256,width,height,bytes,
    context_guard:{version:3,trend_id:target_id,revision,scope:"current_item_only",command_id},
    source_url:sourceUrl,handoff:"pc-bridge-direct-materialized"
  };

  let updatedRow=null;
  for(let n=0;n<6;n++){
    const exp=await readMainJsonWithSha(EXPLAINED_PATH);
    const doc=exp.doc||{project:"TTendencias",items:[]};
    const items=Array.isArray(doc.items)?doc.items:[];
    const row=[...items].reverse().find(x=>String(x.id||"")===target_id&&Number(x.revision||0)===Number(revision));
    if(!row)throw new Error("not_pending_explained");
    const collision=items.find(x=>String(x.id||"")!==target_id&&String(x.ai_image?.sha256||"").toLowerCase()===sha256.toLowerCase());
    if(collision)throw new Error("cross_context_raster_reuse");
    row.ai_image=ai;
    row.ai_image_status="ready";
    row.ai_image_attempt=attempt;
    row.ai_image_last_attempt_status="ready";
    row.ai_image_last_attempt_at=new Date().toISOString();
    delete row.ai_image_failure_reason;
    delete row.ai_image_regeneration_error;
    delete row.ai_image_regenerate_requested;
    delete row.ai_image_regenerate_requested_at;
    delete row.ai_image_regenerate_request_version;
    row.image={...ai};
    row.image_choice="ai";
    row.image_status="ready";
    row.image_pending=false;
    doc.updated_at=new Date().toISOString();
    try{
      await writeMainJson(EXPLAINED_PATH,doc,exp.sha,"TTendencias: adjuntar imagen IA "+target_id);
      updatedRow=row;break;
    }catch(e){
      if(n===5||!/409|422/.test(String(e)))throw e;
      await new Promise(r=>setTimeout(r,250*(n+1)));
    }
  }
  if(!updatedRow)throw new Error("No se pudo actualizar el estado editorial con la imagen");
  return {imagePath,ai}
}

function uploadSecretHash(value){return crypto.createHash("sha256").update(String(value||""),"utf8").digest("hex")}
function validUploadSecret(job,secret){
  const expected=String(job?.pc_upload_secret_hash||"").toLowerCase(),actual=uploadSecretHash(secret);
  if(!/^[a-f0-9]{64}$/.test(expected)||secret.length<32)return false;
  return crypto.timingSafeEqual(Buffer.from(expected,"hex"),Buffer.from(actual,"hex"))
}

async function requestPcAck(req,res){
  const command_id=String(req.body?.command_id||"").trim();
  const stage=String(req.body?.stage||"").toLowerCase();
  const worker_id=String(req.body?.worker_id||"legacy-shared-listener").trim().slice(0,120)||"legacy-shared-listener";
  if(!command_id||!["picked_up","launched"].includes(stage))return res.status(400).json({ok:false,error:"Ack no válido"});
  const {doc:trigger}=await readTrigger();
  if(String(trigger.command_id||"")!==command_id)return res.status(409).json({ok:false,error:"command_id ya no es el actual"});
  const requested_at=String(trigger.requested_at||"");
  const age=Date.now()-stamp(requested_at);
  if(!stamp(requested_at)||age<0||age>10*60*1000)return res.status(409).json({ok:false,error:"Trigger fuera de ventana"});

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
  if(stage==="launched"&&same&&previousWorker&&previousWorker!==worker_id){
    return res.status(409).json({ok:false,error:"claim_not_owned",command_id,worker_id:previousWorker})
  }

  const now=new Date().toISOString();
  const preservePickup=same&&previousWorker===worker_id&&previous.picked_up_at;
  const doc={
    version:2,command_id,requested_at,worker_id,stage,
    picked_up_at:preservePickup?previous.picked_up_at:now,
    launched_at:stage==="launched"?now:(same&&previousWorker===worker_id?previous.launched_at||null:null),
    updated_at:now
  };
  await writeControlJson(ACK_PATH,doc,existing.sha,"PC Chat ack TTendencias "+stage+" "+command_id+" "+worker_id);
  return res.status(200).json({ok:true,claimed:true,...doc})
}

function safeTargetId(v){
  const id=String(v||"").trim();
  if(!/^[A-Za-z0-9._-]{3,160}$/.test(id))throw new Error("target_id inválido");
  return id
}
async function requestImagePcAck(req,res){
  const target_id=safeTargetId(req.body?.target_id||req.body?.id);
  const command_id=String(req.body?.command_id||"").trim();
  const stage=String(req.body?.stage||"").toLowerCase();
  const worker_id=String(req.body?.worker_id||"ttendencias-dedicated-v1").trim().slice(0,120)||"ttendencias-dedicated-v1";
  if(!command_id||!["picked_up","launched","cancelled","failed","done"].includes(stage))return res.status(400).json({ok:false,error:"Ack imagen no válido"});
  const path=IMAGE_RUN_DIR+"/"+target_id+".json";
  const existing=await readControlJson(path),job=existing.doc||{};
  if(String(job.command_id||"")!==command_id)return res.status(409).json({ok:false,error:"command_id de imagen ya no es actual"});
  const terminal=["DONE","ERROR","CANCELLED","SUPERSEDED"].includes(String(job.status||"").toUpperCase());
  if(terminal)return res.status(409).json({ok:false,error:"job ya terminal",status:job.status});
  if(stage==="picked_up"){
    const uploadHash=String(req.body?.upload_secret_hash||"").toLowerCase();
    if(!/^[a-f0-9]{64}$/.test(uploadHash))return res.status(400).json({ok:false,error:"upload_secret_hash requerido"});
    if(job.pc_upload_secret_hash&&String(job.pc_upload_secret_hash)!==uploadHash)return res.status(409).json({ok:false,error:"job ya reclamado con otro secreto"});
    job.pc_upload_secret_hash=uploadHash;
    const eligibility=await imageEligibility(target_id);
    const revisionChanged=Boolean(eligibility.row)&&Number(eligibility.row.revision||0)!==Number(job.revision||0);
    if(!eligibility.eligible||revisionChanged){
      const now=new Date().toISOString();
      const staleReason=revisionChanged?"revision_changed":eligibility.reason;
      const cancelled={...job,status:"CANCELLED",phase:"stale_target",updated_at:now,finished_at:now,pc_worker_id:worker_id,message:"Cancelado antes de abrir chat: "+staleReason};
      await writeControlJson(path,cancelled,existing.sha,"Cancelar imagen IA obsoleta TTendencias "+target_id+" "+command_id);
      return res.status(409).json({ok:false,error:"stale_target",reason:staleReason,status:"CANCELLED",target_id,command_id})
    }
  }
  const now=new Date().toISOString();
  const next={...job,updated_at:now,pc_worker_id:worker_id};
  const doneSecret=String(req.body?.upload_secret||"");
  if(["done","failed"].includes(stage)&&job.pc_upload_secret_hash&&!validUploadSecret(job,doneSecret)){
    return res.status(401).json({ok:false,error:"Secreto de imagen no válido"})
  }
  if(stage==="cancelled"){
    next.status="CANCELLED";
    next.phase="stale_target";
    next.finished_at=now;
    next.message=String(req.body?.reason||"La entrada ya no está pendiente o vigente.").slice(0,240);
  }else if(stage==="done"){
    const exp=await readMainJson(EXPLAINED_PATH);
    const persisted=(exp.items||[]).find(x=>
      String(x.id||"")===target_id &&
      Number(x.revision||0)===Number(job.revision||0) &&
      String(x.ai_image?.context_guard?.command_id||"")===command_id &&
      String(x.ai_image?.url||"").trim()
    );
    if(!persisted)return res.status(409).json({ok:false,error:"image_not_persisted_yet"});
    next.status="DONE";
    next.phase="done";
    next.finished_at=now;
    next.message="Imagen IA materializada y visible en el estado editorial.";
  }else if(stage==="failed"){
    next.status="ERROR";
    next.phase=job.upload_sha256?"image_bridge_failed":"pc_launch_failed";
    next.finished_at=now;
    next.message=String(req.body?.reason||"El puente de imagen no pudo completar el trabajo.").slice(0,240);
  }else{
    next.status="RUNNING";
    next.phase=stage==="picked_up"?"pc_pickup":"pc_launch";
    if(stage==="picked_up")next.pc_picked_up_at=job.pc_picked_up_at||now;
    if(stage==="launched"){
      next.pc_picked_up_at=job.pc_picked_up_at||now;
      next.pc_launched_at=now;
    }
    next.message=stage==="picked_up"?"PC ha recogido la solicitud de imagen.":"PC ha abierto el chat de imagen; esperando inicio de generación.";
  }
  await writeControlJson(path,next,existing.sha,"PC Chat imagen ack TTendencias "+stage+" "+target_id+" "+command_id);
  return res.status(200).json({ok:true,...next})
}

async function requestImageUpload(req,res){
  const target_id=safeTargetId(req.body?.target_id||req.body?.id);
  const command_id=String(req.body?.command_id||"").trim();
  const upload_secret=String(req.body?.upload_secret||"");
  const data=String(req.body?.image_data_url||"");
  if(!command_id||!upload_secret||!data.startsWith("data:image/"))return res.status(400).json({ok:false,error:"Carga de imagen incompleta"});
  if(data.length>4*1024*1024)return res.status(413).json({ok:false,error:"Raster codificado demasiado grande"});
  const path=IMAGE_RUN_DIR+"/"+target_id+".json";
  const existing=await readControlJson(path),job=existing.doc||{};
  if(String(job.command_id||"")!==command_id)return res.status(409).json({ok:false,error:"command_id ya no es actual"});
  if(!validUploadSecret(job,upload_secret))return res.status(401).json({ok:false,error:"Secreto de imagen no válido"});
  if(["DONE","ERROR","CANCELLED","SUPERSEDED"].includes(String(job.status||"").toUpperCase()))return res.status(409).json({ok:false,error:"job terminal",status:job.status});
  const eligible=await imageEligibility(target_id);
  const revisionChanged=Boolean(eligible.row)&&Number(eligible.row.revision||0)!==Number(job.revision||0);
  if(!eligible.eligible||revisionChanged)return res.status(409).json({ok:false,error:"target_no_elegible",reason:revisionChanged?"revision_changed":eligible.reason});
  const m=data.match(/^data:(image\/(?:jpeg|png|webp));base64,([A-Za-z0-9+/=]+)$/);
  if(!m)return res.status(400).json({ok:false,error:"Formato de raster no admitido"});
  const buf=Buffer.from(m[2],"base64");
  if(buf.length<4096||buf.length>3*1024*1024)return res.status(400).json({ok:false,error:"Tamaño de raster no válido",bytes:buf.length});
  const meta=await sharp(buf,{animated:false}).metadata(),width=Number(meta.width||0),height=Number(meta.height||0);
  if(width<640||height<360)return res.status(400).json({ok:false,error:"Raster inferior a 640x360",width,height});
  // ImageGen entrega el gag como raster panorámico 16:9. El bridge no debe
  // aceptar capturas del viewport/chat (normalmente cuadradas o casi verticales)
  // aunque técnicamente sean JPEG/PNG válidos.
  const aspect=height?width/height:0;
  const byteDensity=width&&height?buf.length/(width*height):0;
  if(aspect<1.60||aspect>1.90){
    return res.status(422).json({ok:false,error:"Raster rechazado: no parece la salida 16:9 de ImageGen",width,height,aspect:Number(aspect.toFixed(3))});
  }
  // Segunda barrera contra screenshots casi vacíos/negros de la interfaz.
  // Un raster real generado contiene mucha más información visual por píxel.
  if(buf.length<50000||byteDensity<0.05){
    return res.status(422).json({ok:false,error:"Raster rechazado: contenido demasiado ligero para una imagen generada",width,height,bytes:buf.length,byte_density:Number(byteDensity.toFixed(4))});
  }
  const sha256=crypto.createHash("sha256").update(buf).digest("hex");
  const now=new Date().toISOString(),revision=Number(eligible.row?.revision||job.revision||0),attempt=Math.max(1,Number(eligible.row?.ai_image_attempt||0)||1);
  const persisting={...job,status:"PERSISTING",phase:"image_persist",updated_at:now,upload_received_at:now,upload_sha256:sha256,upload_bytes:buf.length,message:"Raster recibido y validado; materializando directamente en main."};
  await writeControlJson(path,persisting,existing.sha,"TTendencias raster recibido "+command_id);
  const persisted=await persistAiImageDirect({target_id,revision,attempt,command_id,buf,mime:m[1],sha256,width,height,bytes:buf.length});
  return res.status(200).json({ok:true,status:"PERSISTING",target_id,command_id,image_path:persisted.imagePath,sha256,width,height,bytes:buf.length})
}

async function requestImageRun(req,res){
  const target_id=safeTargetId(req.body?.target_id||req.body?.id);
  const requestedRevision=Math.max(0,Number.parseInt(req.body?.revision??0,10)||0);
  // Revalidación autoritativa justo antes de crear el job: nunca mandar una revisión vieja,
  // archivada, agrupada o realmente sensible aunque la UI se haya quedado abierta.
  const eligible=await imageEligibility(target_id);
  if(!eligible.eligible)return res.status(409).json({ok:false,error:"target_no_elegible",reason:eligible.reason,target_id});
  const row=eligible.row||{};
  const revision=Number(row.revision||0);
  if(revision!==requestedRevision)return res.status(409).json({ok:false,error:"target_no_elegible",reason:"revision_changed",target_id,revision});
  const target_name=String(row.name||req.body?.target_name||req.body?.title||req.body?.name||"").trim().slice(0,240);
  const context_snapshot={
    name:target_name,
    revision,
    explanation:String(row.explanation||"").trim(),
    closer_text:String(row.closer_text||"").trim(),
    trend_names:Array.isArray(row.trend_names)?row.trend_names.slice(0,12):[],
    group_title:String(row.group_title||"").trim(),
    rank_at_explanation:Number(row.rank_at_explanation||row._rank||row.rank||0)||null,
    explained_at:row.explained_at||null,
    verification_sources:Array.isArray(row.verification_sources)?row.verification_sources.slice(0,8):[]
  };
  const jobPath=IMAGE_RUN_DIR+"/"+target_id+".json";
  const existing=await readControlJson(jobPath);
  const previous=existing.doc||{};
  const previousStatus=String(previous.status||"").toUpperCase();
  const previousAt=stamp(previous.updated_at||previous.finished_at||previous.requested_at);
  const previousAge=previousAt?Date.now()-previousAt:Infinity;
  const previousPhase=String(previous.phase||"").toLowerCase();
  const previousStillActive=previousStatus==="REQUESTED"
    ?previousAge<30000
    :previousStatus==="RUNNING"&&["pc_pickup","pc_launch"].includes(previousPhase)
      ?previousAge<IMAGE_HANDOFF_ACTIVE_MS
      :["RUNNING","GENERATING","PERSISTING"].includes(previousStatus)&&previousAge<IMAGE_GENERATION_ACTIVE_MS;
  if(previousStillActive){
    return res.status(409).json({ok:false,error:"image_run_in_progress",command_id:previous.command_id||null,target_id,status:previousStatus})
  }
  const requested_at=new Date().toISOString();
  const command_id="tr-img-"+Date.now()+"-"+crypto.randomBytes(3).toString("hex");
  const doc={
    version:1,command_id,requested_at,updated_at:requested_at,status:"REQUESTED",phase:"queued",
    mode:"manual_pc_chat_image",executor:"pc_chat_ttendencias_dedicated",project:"ttendencias",launcher_arg:"tendencias",
    task:"image",target_id,trend_id:target_id,target_name,revision,
    chat_command_version:3,
    instruction_profile:"ttendencias_gag_v1",
    context_snapshot,
    instructions:{
      scope:"Genera UNA sola imagen IA para esta tendencia y no proceses ninguna otra entrada.",
      context:"Usa context_snapshot como contexto autoritativo: contiene la explicación factual y el remate exactos seleccionados por el usuario. No los reescribas ni reinvestigues; solo conviértelos en un gag visual.",
      visual:"Gag visual claramente cómico, satírico, irónico y exagerado; llevar la situación al límite cuando encaje; evitar una ilustración meramente literal.",
      sensitivity:"No conviertas víctimas, muertes, duelo, violencia grave, abuso o sufrimiento humano en objeto del gag. Esos casos deben venir bloqueados antes del lanzamiento.",
      political_guard:"Si el contexto es político, mantén el gag en la situación factual descrita; no inventes acusaciones, propaganda, llamadas al voto ni juicios partidistas como hechos.",
      lifecycle:"Verifica vigencia antes de generar; actualiza este job a GENERATING, PERSISTING y DONE/ERROR; persiste exactamente el raster generado mediante el puente V3."
    },
    message:"Solicitud registrada; esperando al PC para abrir un chat de imagen."
  };
  let saved=await writeControlJson(jobPath,doc,existing.sha,"Solicitar imagen IA TTendencias "+target_id+" "+command_id);

  // Índice de descubrimiento: pequeño y acotado. El estado autoritativo sigue siendo el fichero individual.
  for(let attempt=0;attempt<3;attempt++){
    const idx=await readControlJson(IMAGE_RUN_INDEX_PATH);
    const base=idx.doc&&Array.isArray(idx.doc.jobs)?idx.doc:{version:1,jobs:[]};
    const jobs=base.jobs.filter(x=>String(x.command_id||"")!==command_id&&String(x.target_id||"")!==target_id);
    jobs.push({command_id,target_id,trend_id:target_id,target_name,revision,requested_at,status_path:jobPath,executor:"pc_chat_ttendencias_dedicated"});
    const indexDoc={version:1,updated_at:requested_at,jobs:jobs.slice(-60)};
    try{
      await writeControlJson(IMAGE_RUN_INDEX_PATH,indexDoc,idx.sha,"Actualizar cola de imágenes IA TTendencias");
      break
    }catch(e){
      if(attempt===2||(!String(e.message||e).includes("409")&&!String(e.message||e).includes("422")))throw e
    }
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
      // Un simple picked_up solo demuestra que el PC vio la orden. Si en 45 s no
      // llegó a launched, el intento está muerto y no debe bloquear 20 minutos.
      const ackWindow=ackStage==="picked_up"?45000:ackStage==="launched"?6*60*1000:ACTIVE_MS;
      const ackFresh=ackMatches&&ackAt&&Date.now()-ackAt<ackWindow;

      // 45 s cubre holgadamente el SLA visual de 30 s. Si pasado ese tiempo no hay
      // ACK ni RUNNING, la orden anterior está muerta y una pulsación nueva debe poder
      // reemplazarla; no la bloqueamos 20 minutos.
      if(!consumedBy&&Number.isFinite(age)&&age<45000)return res.status(429).json({ok:false,error:"recent_request",retry_after_seconds:Math.ceil((45000-age)/1000)});
      if(!consumedBy&&String(st||"").toUpperCase()==="RUNNING")return res.status(409).json({ok:false,error:"run_in_progress"});
      if(!consumedBy&&ackFresh&&["picked_up","launched"].includes(ackStage))return res.status(409).json({ok:false,error:"run_in_progress"});
    }
    const requested_at=new Date().toISOString(),command_id="tr-"+Date.now()+"-"+crypto.randomBytes(3).toString("hex"),doc={version:2,command_id,requested_at,mode:"manual_pc_chat",executor:"pc_chat_ttendencias_dedicated",project:"ttendencias",launcher_arg:"tendencias",task,auto_image_followup:false};
    let saved;try{saved=await writeTrigger(doc,sha)}catch(e){if(!String(e.message||e).includes("409")&&!String(e.message||e).includes("422"))throw e;const fresh=await readTrigger();saved=await writeTrigger(doc,fresh.sha)}
    return res.status(200).json({ok:true,command_id,requested_at,commit_sha:saved?.commit?.sha||null,trace_comment_id:null,trigger:"pc_chat_poll",task})
  }catch(e){console.error(e);return res.status(500).json({ok:false,error:String(e.message||e)})}
}
