import crypto from "node:crypto";

const CONTROL_TOKEN_HASHES=[
  "2663da5223c2313c3670a7843a0cdfabfd2dd7c8fad1ed168247866a3b1262e5",
  "083d41ffcc41b14d52d426412b1ed44a8d4958b351ee110bdcc5a0eec167b840",
  "cdaa00313ab7f8031d485ac42ec8bb5d22eadf41a27e719848c8c6fcf40f3c98"
];
function authToken(req){const h=String(req.headers.authorization||"");return h.startsWith("Bearer ")?h.slice(7).trim():""}
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
const IMAGE_ACTIVE_MS=45*60*1000;
const STATUS_PREFIX="RUNSTATUS ";
const TRACE_PREFIX="TTITTULARES_RUNTRACE_V1\n";

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
async function comments(){
  const since=new Date(Date.now()-24*60*60*1000).toISOString();
  let url=`https://api.github.com/repos/${REPO}/issues/${PR}/comments?per_page=100&since=${encodeURIComponent(since)}`;
  const items=[];
  for(let page=0;page<10&&url;page++){
    const r=await gh(url);
    if(!r.ok)throw new Error(`GitHub comments: ${r.status} ${await r.text()}`);
    items.push(...await r.json());
    const next=(r.headers.get("link")||"").match(/<([^>]+)>;\s*rel="next"/);
    url=next?next[1]:null
  }
  return items
}
async function triggerReady(){return true}
async function readTrigger(){
  const u=`https://api.github.com/repos/${REPO}/contents/${TRIGGER_PATH}?ref=${encodeURIComponent(TRIGGER_BRANCH)}`;
  const r=await gh(u);
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
  const fresh=items.map(traceOf).filter(Boolean).filter(t=>["REQUESTED","RUNNING"].includes(String(t.status||""))).filter(t=>{
    const age=Date.now()-stamp(t.comment_updated_at||t.updated_at||t.started_at||t.requested_at);
    return Number.isFinite(age)&&age>=0&&age<20*60*1000
  });
  fresh.sort((a,b)=>stamp(a.comment_updated_at||a.updated_at)-stamp(b.comment_updated_at||b.updated_at));
  return fresh.at(-1)||null
}
function newerRunAfter(items,requestedAt){
  const t=stamp(requestedAt);
  if(!t)return null;
  return items.map(traceOf).filter(Boolean)
    .filter(x=>stamp(x.started_at||x.requested_at||x.comment_updated_at)>t+1000)
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

async function readControlJson(path){
  const r=await gh("https://api.github.com/repos/"+REPO+"/contents/"+path+"?ref="+encodeURIComponent(TRIGGER_BRANCH));
  if(r.status===404)return {sha:null,doc:null};
  if(!r.ok)throw new Error("GitHub control GET "+path+": "+r.status+" "+await r.text());
  const f=await r.json(),raw=Buffer.from(String(f.content||"").replace(/\n/g,""),"base64").toString("utf8");
  return {sha:f.sha,doc:JSON.parse(raw||"{}")}
}
async function writeControlJson(path,doc,sha,message){
  const body={message,content:Buffer.from(JSON.stringify(doc,null,2)+"\n","utf8").toString("base64"),branch:TRIGGER_BRANCH};
  if(sha)body.sha=sha;
  const r=await gh("https://api.github.com/repos/"+REPO+"/contents/"+path,{method:"PUT",headers:{"content-type":"application/json"},body:JSON.stringify(body)});
  if(!r.ok)throw new Error("GitHub control PUT "+path+": "+r.status+" "+await r.text());
  return r.json()
}
async function requestPcAck(req,res){
  const command_id=String(req.body?.command_id||"").trim();
  const stage=String(req.body?.stage||"").toLowerCase();
  if(!command_id||!["picked_up","launched"].includes(stage))return res.status(400).json({ok:false,error:"Ack no válido"});
  const {doc:trigger}=await readTrigger();
  if(String(trigger.command_id||"")!==command_id)return res.status(409).json({ok:false,error:"command_id ya no es el actual"});
  const requested_at=String(trigger.requested_at||"");
  const age=Date.now()-stamp(requested_at);
  if(!stamp(requested_at)||age<0||age>10*60*1000)return res.status(409).json({ok:false,error:"Trigger fuera de ventana"});
  const existing=await readControlJson(ACK_PATH);
  const now=new Date().toISOString();
  const same=String(existing.doc?.command_id||"")===command_id;
  const doc={
    version:1,command_id,requested_at,stage,
    picked_up_at:same&&existing.doc?.picked_up_at?existing.doc.picked_up_at:now,
    launched_at:stage==="launched"?now:(same?existing.doc?.launched_at||null:null),
    updated_at:now
  };
  await writeControlJson(ACK_PATH,doc,existing.sha,"PC Chat ack TTiTTulares "+stage+" "+command_id);
  return res.status(200).json({ok:true,...doc})
}

function safeTargetId(v){
  const id=String(v||"").trim();
  if(!/^[A-Za-z0-9._-]{3,160}$/.test(id))throw new Error("target_id inválido");
  return id
}
async function requestImageRun(req,res){
  const target_id=safeTargetId(req.body?.target_id||req.body?.event_id);
  const target_name=String(req.body?.target_name||req.body?.title||req.body?.name||"").trim().slice(0,240);
  const revision=Math.max(0,Number.parseInt(req.body?.revision??1,10)||1);
  const jobPath=IMAGE_RUN_DIR+"/"+target_id+".json";
  const existing=await readControlJson(jobPath);
  const previous=existing.doc||{};
  const previousStatus=String(previous.status||"").toUpperCase();
  const previousAt=stamp(previous.updated_at||previous.finished_at||previous.requested_at);
  const previousAge=previousAt?Date.now()-previousAt:Infinity;
  const previousStillActive=previousStatus==="REQUESTED"
    ?previousAge<30000
    :["RUNNING","GENERATING","PERSISTING"].includes(previousStatus)&&previousAge<IMAGE_ACTIVE_MS;
  if(previousStillActive){
    return res.status(409).json({ok:false,error:"image_run_in_progress",command_id:previous.command_id||null,target_id,status:previousStatus})
  }
  const requested_at=new Date().toISOString();
  const command_id="tt-img-"+Date.now()+"-"+crypto.randomBytes(3).toString("hex");
  const doc={
    version:1,command_id,requested_at,updated_at:requested_at,status:"REQUESTED",phase:"queued",
    mode:"manual_pc_chat_image",executor:"pc_chat",project:"ttittulares",launcher_arg:"titulares",
    task:"image",target_id,event_id:target_id,target_name,revision,
    message:"Solicitud registrada; esperando al PC para abrir un chat de imagen."
  };
  let saved=await writeControlJson(jobPath,doc,existing.sha,"Solicitar imagen IA TTiTTulares "+target_id+" "+command_id);

  // Índice de descubrimiento: pequeño y acotado. El estado autoritativo sigue siendo el fichero individual.
  for(let attempt=0;attempt<3;attempt++){
    const idx=await readControlJson(IMAGE_RUN_INDEX_PATH);
    const base=idx.doc&&Array.isArray(idx.doc.jobs)?idx.doc:{version:1,jobs:[]};
    const jobs=base.jobs.filter(x=>String(x.command_id||"")!==command_id&&String(x.target_id||"")!==target_id);
    jobs.push({command_id,target_id,event_id:target_id,target_name,revision,requested_at,status_path:jobPath});
    const indexDoc={version:1,updated_at:requested_at,jobs:jobs.slice(-60)};
    try{
      await writeControlJson(IMAGE_RUN_INDEX_PATH,indexDoc,idx.sha,"Actualizar cola de imágenes IA TTiTTulares");
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
  if(!authorized(req))return res.status(401).json({ok:false,error:"No autorizado"});
  try{
    const task=rawTask==="images"?"images":"editorial";
    if(task==="images")return await requestImageRun(req,res);
    const [{doc:current,sha},items]=await Promise.all([readTrigger(),comments()]);
    if(activeTrace(items))return res.status(409).json({ok:false,error:"run_in_progress"});
    const currentId=String(current.command_id||"").trim();
    const currentRequested=String(current.requested_at||"").trim();
    if(currentId&&currentRequested){
      const age=Date.now()-new Date(currentRequested).getTime();
      const consumedBy=newerRunAfter(items,currentRequested);
      const marks=items.filter(c=>String(c.body||"").startsWith(STATUS_PREFIX+currentId+"\n"));
      const last=marks.at(-1);
      const st=last?field(last.body,"status"):"REQUESTED";
      if(!consumedBy&&Number.isFinite(age)&&age<45000)return res.status(429).json({ok:false,error:"recent_request",retry_after_seconds:Math.ceil((45000-age)/1000)});
      if(!consumedBy&&Number.isFinite(age)&&age<20*60*1000&&!["DONE","ERROR"].includes(st||"REQUESTED"))return res.status(409).json({ok:false,error:"run_in_progress"})
    }

    const requested_at=new Date().toISOString();
    const command_id=`tt-${Date.now()}-${crypto.randomBytes(3).toString("hex")}`;
    const doc={version:2,command_id,requested_at,mode:"manual_pc_chat",executor:"pc_chat",project:"ttittulares",launcher_arg:"titulares",task,auto_image_followup:false};
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
