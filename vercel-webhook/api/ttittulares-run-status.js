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
const STATUS_PREFIX="RUNSTATUS ";
const TRACE_PREFIX="TTITTULARES_RUNTRACE_V1\n";
const TRACE_COMMENT_ID=5859738015;
const STALE_MS=20*60*1000;
const START_ACK_MS=30*1000;
const LAUNCH_ACK_MS=45*1000;
const CHAT_CONFIRM_MS=45*1000;

async function gh(url,options={}){
  if(!process.env.GITHUB_TOKEN)throw new Error("GITHUB_TOKEN no configurado");
  return fetch(url,{...options,headers:{
    accept:"application/vnd.github+json",
    authorization:`Bearer ${process.env.GITHUB_TOKEN}`,
    "x-github-api-version":"2022-11-28",
    "user-agent":"ttittulares-run-status",
    ...(options.headers||{})
  }})
}
let commentsCache={at:0,items:[]};
async function comments(){
  // RUNTRACE es detalle complementario. No consultar GitHub REST en cada polling:
  // una sola lectura reciente como máximo cada 30 s por instancia caliente.
  const now=Date.now();
  if(now-commentsCache.at<30000)return commentsCache.items;
  const since=new Date(now-12*60*60*1000).toISOString();
  try{
    const r=await gh(`https://api.github.com/repos/${REPO}/issues/${PR}/comments?per_page=100&since=${encodeURIComponent(since)}`);
    if(!r.ok)return commentsCache.items;
    const items=(await r.json()).filter(x=>String(x.body||"").startsWith(TRACE_PREFIX));
    commentsCache={at:now,items};
    return items
  }catch(_){
    return commentsCache.items
  }
}
async function triggerReady(){return true}
async function readControl(path){
  // El canal de control exige consistencia fuerte. GitHub REST refleja el HEAD
  // de la rama; RAW puede servir temporalmente el commit anterior.
  try{
    const r=await gh(`https://api.github.com/repos/${REPO}/contents/${path}?ref=${encodeURIComponent(TRIGGER_BRANCH)}`,{cache:"no-store"});
    if(r.ok){
      const f=await r.json();
      const raw=Buffer.from(String(f.content||"").replace(/\n/g,""),"base64").toString("utf8");
      return JSON.parse(raw||"{}")
    }
  }catch(_){}
  try{
    const clean=String(path||"").split("/").map(encodeURIComponent).join("/");
    const u=`https://raw.githubusercontent.com/${REPO}/${encodeURIComponent(TRIGGER_BRANCH)}/${clean}?t=${Date.now()}`;
    const r=await fetch(u,{cache:"no-store",headers:{"cache-control":"no-cache","user-agent":"ttittulares-run-status-control-read"}});
    if(r.ok)return JSON.parse(await r.text()||"{}")
  }catch(_){}
  return {}
}
async function readTrigger(){
  try{
    const r=await gh("https://api.github.com/repos/"+REPO+"/contents/"+TRIGGER_PATH+"?ref="+encodeURIComponent(TRIGGER_BRANCH),{cache:"no-store"});
    if(!r.ok)return {doc:await readControl(TRIGGER_PATH)};
    const f=await r.json();
    const raw=Buffer.from(String(f.content||"").replace(/\n/g,""),"base64").toString("utf8");
    return {doc:JSON.parse(raw||"{}")}
  }catch(_){
    return {doc:await readControl(TRIGGER_PATH)}
  }
}
async function readAck(){return await readControl(ACK_PATH)}
async function readAckFresh(){
  try{
    const r=await gh("https://api.github.com/repos/"+REPO+"/contents/"+ACK_PATH+"?ref="+encodeURIComponent(TRIGGER_BRANCH),{cache:"no-store"});
    if(!r.ok)return await readAck();
    const f=await r.json();
    const raw=Buffer.from(String(f.content||"").replace(/\n/g,""),"base64").toString("utf8");
    return JSON.parse(raw||"{}")
  }catch(_){
    return await readAck()
  }
}
async function readErrors(){
  try{
    const u=`https://raw.githubusercontent.com/${REPO}/main/ttittulares/execution-errors.json?t=${Date.now()}`;
    const r=await fetch(u,{cache:"no-store",headers:{"user-agent":"ttittulares-run-status-read"}});
    if(!r.ok)return [];
    return (JSON.parse(await r.text()||"{}").items||[]).map(x=>({at:x.at||null,event_id:x.event_id||null,phase:x.phase||null,reason:String(x.reason||"").slice(0,1200)}))
  }catch(_){return []}
}
function field(body,name){
  const m=String(body||"").match(new RegExp("^"+name+":\\s*(.+)$","mi"));
  return m?m[1].trim():null
}
function seconds(a,b){
  const x=new Date(a).getTime(),y=new Date(b).getTime();
  return Number.isFinite(x)&&Number.isFinite(y)?Math.max(0,Math.round((y-x)/1000)):null
}
function traceOf(comment){
  const body=String(comment?.body||"");
  if(!body.startsWith(TRACE_PREFIX))return null;
  try{
    const t=JSON.parse(body.slice(TRACE_PREFIX.length).trim());
    return {...t,comment_id:comment.id,comment_updated_at:comment.updated_at||comment.created_at}
  }catch(_){return null}
}
function stamp(v){const n=Date.parse(v||"");return Number.isFinite(n)?n:0}
function sourceLabel(v){return v==="manual"?"Manual":v==="mobile"?"Móvil→PC":v==="scheduled"?"Automática":v==="chat"?"Chat":String(v||"")}
function incidentsFor(errors,start,finish){
  const a=stamp(start),b=finish?stamp(finish)+120000:Date.now()+120000;
  if(!a)return [];
  return errors.filter(x=>{const t=stamp(x.at);return t>=a&&t<=b}).slice(-8)
}
function normalizeTrace(t,errors){
  const commentUpdated=t.comment_updated_at||null;
  const payloadUpdated=t.updated_at||null;
  // GitHub es el reloj autoritativo de la telemetría. Algunos ejecutores pueden
  // publicar timestamps unos minutos adelantados; no deben convertir una ejecución
  // viva en ERROR ni ocultarla del panel.
  const payloadMs=stamp(payloadUpdated),commentMs=stamp(commentUpdated);
  const updated=(payloadMs&&commentMs&&payloadMs>commentMs+2*60*1000)?commentUpdated:(payloadUpdated||commentUpdated||null);
  const started=t.started_at||t.requested_at||updated||null;
  const finished=t.finished_at||(["DONE","ERROR"].includes(t.status)?updated:null);
  const traceIncidents=(Array.isArray(t.incidents)?t.incidents:[]).map(x=>({
    at:x?.at||updated||null,event_id:x?.event_id||t.event_id||null,phase:x?.phase||t.phase||null,reason:String(x?.reason||"").slice(0,1200)
  })).filter(x=>x.reason);
  const ledgerIncidents=incidentsFor(errors,started,finished);
  const seen=new Set(),incidents=[];
  for(const x of [...traceIncidents,...ledgerIncidents]){
    const key=[x.at||"",x.event_id||"",x.phase||"",x.reason||""].join("|");
    if(seen.has(key))continue;seen.add(key);incidents.push(x)
  }
  const incident_count=Math.max(Number(t.incident_count||0),incidents.length);
  const heartbeat_age_seconds=updated?Math.max(0,Math.round((Date.now()-stamp(updated))/1000)):null;
  return {
    run_id:t.run_id||t.command_id||null,
    command_id:t.command_id||t.run_id||null,
    source:t.source||"chat",
    source_label:sourceLabel(t.source||"chat"),
    status:t.status||"RUNNING",
    phase:t.phase||null,
    current:Number(t.current||0),
    total:Number(t.total||0),
    event_id:t.event_id||null,
    title:t.title||null,
    requested_at:t.requested_at||null,
    started_at:t.started_at||started,
    updated_at:updated,
    telemetry_comment_updated_at:commentUpdated,
    heartbeat_age_seconds,
    finished_at:finished,
    duration_seconds:started&&finished?seconds(started,finished):null,
    message:t.message||null,
    summary:t.summary||null,
    generation_started_at:t.generation_started_at||null,
    generation_finished_at:t.generation_finished_at||null,
    bytes_obtained:typeof t.bytes_obtained==="boolean"?t.bytes_obtained:null,
    bytes_size:Number.isFinite(Number(t.bytes_size))?Number(t.bytes_size):null,
    sha256:t.sha256||null,
    outbox_comment_id:t.outbox_comment_id||null,
    final_image_result:t.final_image_result||null,
    incident_count,
    incidents
  }
}
function manualFallback(items,request,ack){
  const command_id=String(request.command_id||"").trim();
  const requested_at=String(request.requested_at||"").trim();
  if(!command_id||!requested_at)return null;
  const marks=items.filter(c=>String(c.body||"").startsWith(STATUS_PREFIX+command_id+"\n"));
  const last=marks.at(-1);
  const rawStatus=last?field(last.body,"status")||"REQUESTED":"REQUESTED";
  const started=marks.find(c=>field(c.body,"status")==="RUNNING");
  const started_at=started?(field(started.body,"started_at")||started.created_at):null;
  const lastActivity=last?.updated_at||last?.created_at||requested_at;
  const ackMatches=String(ack?.command_id||"")===command_id;
  const ackStage=ackMatches?String(ack?.stage||"").toLowerCase():"";
  const pickedAt=ackMatches?(ack?.picked_up_at||ack?.updated_at||null):null;
  const launchedAt=ackMatches?(ack?.launched_at||null):null;
  const failedAt=ackMatches?(ack?.failed_at||null):null;
  const failedDetail=ackMatches?String(ack?.detail||"").trim():null;
  const noPickup=rawStatus==="REQUESTED"&&!started_at&&!ackMatches&&Date.now()-stamp(requested_at)>=START_ACK_MS;
  const pickupButNoLaunch=rawStatus==="REQUESTED"&&!started_at&&ackMatches&&ackStage==="picked_up"&&Date.now()-stamp(pickedAt)>=LAUNCH_ACK_MS;
  const launchButNoEditorial=rawStatus==="REQUESTED"&&!started_at&&ackMatches&&ackStage==="launched"&&launchedAt&&Date.now()-stamp(launchedAt)>=CHAT_CONFIRM_MS;
  const launchFailed=rawStatus==="REQUESTED"&&!started_at&&ackMatches&&ackStage==="failed";
  const staleRunning=rawStatus==="RUNNING"&&Date.now()-stamp(lastActivity)>=STALE_MS;

  let status=rawStatus,phase=status==="REQUESTED"?"preparing":status==="RUNNING"?"running":status==="DONE"?"closing":"error";
  let message=last?field(last.body,"message"):null;
  let effectiveStarted=started_at;
  let updated_at=lastActivity;

  if(rawStatus==="REQUESTED"&&!started_at&&ackMatches&&!launchFailed){
    status="RUNNING";
    phase=ackStage==="launched"?"chat_launch":"pc_ack";
    effectiveStarted=pickedAt||requested_at;
    updated_at=ack?.updated_at||pickedAt||requested_at;
    message=ackStage==="launched"
      ?"PC ha recogido la orden y ha lanzado el chat; esperando confirmación editorial."
      :"PC ha recogido la orden; preparando el lanzamiento del chat.";
  }
  if(noPickup||pickupButNoLaunch||launchButNoEditorial||launchFailed||staleRunning){
    status="ERROR";phase="error";
    message=noPickup
      ?"El PC no ha recogido la orden en 30 segundos."
      :pickupButNoLaunch
        ?"El PC recogió la orden, pero no confirmó el lanzamiento del chat en 45 segundos."
        :launchButNoEditorial
          ?"El chat fue lanzado, pero no comenzó la ejecución editorial en 45 segundos."
          :launchFailed
            ?("El lanzador local falló: "+(failedDetail||"sin detalle"))
            :"La ejecución no actualiza su estado desde hace más de 20 minutos.";
  }
  const finished_at=noPickup
    ?new Date(stamp(requested_at)+START_ACK_MS).toISOString()
    :pickupButNoLaunch
      ?new Date(stamp(pickedAt)+LAUNCH_ACK_MS).toISOString()
      :launchButNoEditorial
        ?new Date(stamp(launchedAt)+CHAT_CONFIRM_MS).toISOString()
        :launchFailed
          ?(failedAt||ack?.updated_at||new Date().toISOString())
          :staleRunning?new Date().toISOString()
      :(["DONE","ERROR"].includes(status)&&last?(field(last.body,"finished_at")||last.created_at):null);

  return {
    run_id:command_id,command_id,source:"mobile",source_label:"Móvil→PC",status,phase,
    current:0,total:0,event_id:null,title:null,requested_at,started_at:effectiveStarted,updated_at,finished_at,
    start_delay_seconds:effectiveStarted?seconds(requested_at,effectiveStarted):null,
    duration_seconds:effectiveStarted&&finished_at?seconds(effectiveStarted,finished_at):null,
    message:message||"Orden móvil registrada; esperando al PC para recogerla (máx. 30 s).",
    summary:null,incident_count:0,incidents:[],
    pc_ack_stage:ackStage||null,pc_picked_up_at:pickedAt||null,pc_launched_at:launchedAt||null,pc_failed_at:failedAt||null,pc_failure_detail:failedDetail||null
  }
}

export default async function handler(req,res){
  res.setHeader("cache-control","no-store");
  if(req.method!=="GET")return res.status(405).json({ok:false,error:"Método no permitido"});
  try{
    if(String(req.query?.view||"").toLowerCase()==="trigger"){
      const [{doc:request},ack]=await Promise.all([readTrigger(),readAck()]);
      return res.status(200).json({ok:true,trigger:request||{},ack:ack||{},server_now:new Date().toISOString()})
    }
    const [enabled,items,{doc:request},ackRaw]=await Promise.all([triggerReady(),comments(),readTrigger(),readAck()]);
    let ack=ackRaw;
    const requestAge=Date.now()-stamp(request?.requested_at);
    if(request?.command_id&&Number.isFinite(requestAge)&&requestAge>=0&&requestAge<5*60*1000){
      ack=await readAckFresh()
    }
    const traces=items.map(traceOf).filter(Boolean);
    // Un RUNTRACE se crea una vez y se actualiza in-place. comment.updated_at mide
    // actividad/heartbeat, NO identidad cronológica del run: un run antiguo tocado
    // tarde no debe desplazar al run realmente más reciente.
    const runOrder=t=>stamp(t.started_at||t.requested_at||t.created_at||t.comment_updated_at||t.updated_at);
    const terminalOrder=t=>stamp(t.finished_at||t.updated_at||t.comment_updated_at||t.started_at||t.requested_at);
    const newest=[...traces].sort((a,b)=>runOrder(a)-runOrder(b));
    const latestRaw=newest.at(-1)||null;
    let errors=[];
    if(latestRaw&&Number(latestRaw.incident_count||0)>0)errors=await readErrors();
    let latest=latestRaw?normalizeTrace(latestRaw,errors):null;

    let active=null;
    if(latest&&["REQUESTED","RUNNING"].includes(latest.status)){
      const freshAt=latest.telemetry_comment_updated_at||latest.updated_at||latest.started_at||latest.requested_at;
      const age=Date.now()-stamp(freshAt);
      const deadline=latest.status==="REQUESTED"?START_ACK_MS:STALE_MS;
      if(Number.isFinite(age)&&age>=0&&age<deadline)active=latest;
      else latest={...latest,status:"ERROR",finished_at:new Date().toISOString(),message:latest.status==="REQUESTED"
        ?"No se ha recibido RUNNING en 30 segundos: el PC no ha recogido la orden móvil."
        :(latest.message||"La ejecución dejó de actualizar la telemetría durante más de 20 minutos.")}
    }

    let fallback=null;
    if(!active){
      fallback=manualFallback(items,request,ack);
      if(fallback&&["REQUESTED","RUNNING"].includes(fallback.status)){
        const newer=!latest||stamp(fallback.requested_at)>stamp(latest.updated_at||latest.finished_at||latest.requested_at);
        const age=Date.now()-stamp(fallback.updated_at||fallback.started_at||fallback.requested_at);
        const deadline=fallback.status==="REQUESTED"?START_ACK_MS:STALE_MS;
        if(newer&&Number.isFinite(age)&&age>=0&&age<deadline)active=fallback
      }
    }

    if(active){
      if(Number(active.incident_count||0)>0&&!errors.length)errors=await readErrors();
      const ledger=incidentsFor(errors,active.started_at||active.requested_at,null);
      const seen=new Set(),merged=[];
      for(const x of [...(Array.isArray(active.incidents)?active.incidents:[]),...ledger]){
        const key=[x.at||"",x.event_id||"",x.phase||"",x.reason||""].join("|");
        if(seen.has(key))continue;seen.add(key);merged.push(x)
      }
      active.incidents=merged;
      active.incident_count=Math.max(Number(active.incident_count||0),merged.length);
      const terminalBefore=traces
        .filter(t=>["DONE","ERROR"].includes(t.status)&&runOrder(t)<runOrder(latestRaw||active))
        .sort((a,b)=>terminalOrder(a)-terminalOrder(b))
        .at(-1)||null;
      const last_run=terminalBefore?normalizeTrace(terminalBefore,errors):null;
      return res.status(200).json({ok:true,enabled,active:true,...active,last_run,can_run:enabled&&authorized(req)})
    }

    const terminalCandidates=[];
    for(const raw of traces.filter(t=>["DONE","ERROR"].includes(t.status))){
      if(Number(raw.incident_count||0)>0&&!errors.length)errors=await readErrors();
      terminalCandidates.push(normalizeTrace(raw,errors))
    }
    if(latest&&["DONE","ERROR"].includes(latest.status))terminalCandidates.push(latest);
    if(fallback&&["DONE","ERROR"].includes(fallback.status)){
      if(!errors.length)errors=await readErrors();
      const inc=incidentsFor(errors,fallback.started_at||fallback.requested_at,fallback.finished_at);
      terminalCandidates.push({...fallback,incidents:inc,incident_count:inc.length})
    }
    terminalCandidates.sort((a,b)=>{
      const aStarted=stamp(a.started_at||a.requested_at||a.finished_at||a.updated_at);
      const bStarted=stamp(b.started_at||b.requested_at||b.finished_at||b.updated_at);
      if(aStarted!==bStarted)return aStarted-bStarted;
      return stamp(a.finished_at||a.updated_at)-stamp(b.finished_at||b.updated_at)
    });
    const last_run=terminalCandidates.at(-1)||null;
    return res.status(200).json({ok:true,enabled,active:false,status:"IDLE",last_run,debug:{server_now:new Date().toISOString(),trace_count:traces.length,latest_run_id:latest?.run_id||null,latest_status:latest?.status||null,last_run_id:last_run?.run_id||null,last_run_finished_at:last_run?.finished_at||null},can_run:enabled&&authorized(req)})
  }catch(e){
    console.error(e);
    const raw=String(e?.message||e);
    const reset=raw.match(/resets at\s+(\d{9,})/i);
    const retry_at=reset?new Date(Number(reset[1])*1000).toISOString():null;
    const error=/rate limit exceeded/i.test(raw)?"GitHub temporalmente limitado; se conserva el último estado visible.":raw.slice(0,220);
    return res.status(503).json({ok:false,error,retry_at,degraded:true})
  }
}
