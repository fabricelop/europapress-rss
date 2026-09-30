import crypto from "node:crypto";

const CONTROL_TOKEN_HASHES=[
  "2663da5223c2313c3670a7843a0cdfabfd2dd7c8fad1ed168247866a3b1262e5",
  "e6dc803e75f1bad2c6caee93b1a7fce3df540f70c8313a7e08a998506d0dcb61"
];
function authToken(req){const h=String(req.headers.authorization||"");return h.startsWith("Bearer ")?h.slice(7).trim():""}
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
const STATUS_PREFIX="RUNSTATUS ";
const TRACE_PREFIX="TTENDENCIAS_RUNTRACE_V1\n";
const READY_MARKER="TTENDENCIAS WORK COMMIT TRIGGER READY";
const STALE_MS=20*60*1000;
const START_ACK_MS=3*60*1000;
const RUNTIME_PATH="trends/editorial-runtime.json";
const EXPLAINED_PATH="trends/telegram-manual-explained.json";
const MAIN_BRANCH="main";

async function gh(url,options={}){
  if(!process.env.GITHUB_TOKEN)throw new Error("GITHUB_TOKEN no configurado");
  return fetch(url,{...options,headers:{
    accept:"application/vnd.github+json",
    authorization:"Bearer "+process.env.GITHUB_TOKEN,
    "x-github-api-version":"2022-11-28",
    "user-agent":"ttendencias-run-status",
    ...(options.headers||{})
  }})
}
async function comments(){
  const since=new Date(Date.now()-24*60*60*1000).toISOString();
  let url="https://api.github.com/repos/"+REPO+"/issues/"+PR+"/comments?per_page=100&since="+encodeURIComponent(since);
  const items=[];
  for(let page=0;page<10&&url;page++){
    const r=await gh(url);
    if(!r.ok)throw new Error("GitHub comments: "+r.status+" "+await r.text());
    items.push(...await r.json());
    const link=r.headers.get("link")||"";
    const next=link.match(/<([^>]+)>;\s*rel="next"/);
    url=next?next[1]:null
  }
  return items
}
async function triggerReady(){
  const r=await gh("https://api.github.com/repos/"+REPO+"/pulls/"+PR);
  if(!r.ok)throw new Error("GitHub PR: "+r.status+" "+await r.text());
  const pr=await r.json();
  return String(pr.body||"").includes(READY_MARKER)
}
async function readTrigger(){
  const u="https://api.github.com/repos/"+REPO+"/contents/"+TRIGGER_PATH+"?ref="+encodeURIComponent(TRIGGER_BRANCH);
  const r=await gh(u);
  if(!r.ok)return {doc:{}};
  const f=await r.json();
  const raw=Buffer.from(String(f.content||"").replace(/\n/g,""),"base64").toString("utf8");
  return {doc:JSON.parse(raw||"{}")}
}
async function readMainJson(path){
  try{
    const u="https://api.github.com/repos/"+REPO+"/contents/"+path+"?ref="+encodeURIComponent(MAIN_BRANCH);
    const r=await gh(u);
    if(!r.ok)return {};
    const f=await r.json();
    const raw=Buffer.from(String(f.content||"").replace(/\n/g,""),"base64").toString("utf8");
    return JSON.parse(raw||"{}");
  }catch(_){return {}}
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
function sourceLabel(v){return v==="manual"?"Manual":v==="scheduled"?"Automática":v==="chat"?"Chat":String(v||"")}
function terminalStatus(v){return ["DONE","DONE_WITH_INCIDENTS","ERROR"].includes(String(v||""))}
function normalizeTrace(t){
  const started=t.started_at||t.requested_at||t.updated_at||null;
  const finished=t.finished_at||(terminalStatus(t.status)?t.updated_at:null);
  const incidents=Array.isArray(t.incidents)?t.incidents.slice(-8):[];
  return {
    run_id:t.run_id||t.command_id||null,
    command_id:t.command_id||t.run_id||null,
    source:t.source||"chat",
    source_label:sourceLabel(t.source||"chat"),
    status:t.status||"RUNNING",
    phase:t.phase||null,
    current:Number(t.current||0),
    total:Number(t.total||0),
    trend_id:t.trend_id||t.event_id||null,
    title:t.title||t.trend_name||null,
    requested_at:t.requested_at||null,
    started_at:t.started_at||started,
    updated_at:t.updated_at||t.comment_updated_at||null,
    finished_at:finished,
    start_delay_seconds:t.requested_at&&started?seconds(t.requested_at,started):null,
    duration_seconds:started&&finished?seconds(started,finished):null,
    message:t.message||null,
    summary:t.summary||null,
    incident_count:Math.max(Number(t.incident_count||0),incidents.length),
    incidents
  }
}
function runtimeFallback(doc){
  const stored=doc&&typeof doc.last_run==="object"&&doc.last_run?doc.last_run:null;
  if(stored){
    const normalized=normalizeTrace({...stored,source:stored.source||"chat"});
    if(terminalStatus(normalized.status)&&stamp(normalized.finished_at||normalized.updated_at||normalized.started_at))return normalized;
  }
  const finished=doc?.last_completed_at||doc?.updated_at||null;
  if(!finished||!stamp(finished))return null;
  const failed=String(doc?.status||"").toLowerCase()==="failure";
  return normalizeTrace({
    run_id:"runtime-"+String(finished).replace(/[^0-9]/g,"").slice(0,14),
    source:"chat",
    status:failed?"ERROR":"DONE",
    phase:failed?"error":"closing",
    started_at:doc?.last_started_at||finished,
    updated_at:doc?.updated_at||finished,
    finished_at:finished,
    summary:doc?.summary||null,
    message:failed?(doc?.error||"Ejecución editorial fallida"):null
  });
}
function persistedExplanationFallback(doc){
  const items=(doc?.items||[]).filter(x=>
    String(x?.status||"")==="explained" &&
    String(x?.explanation||"").trim() &&
    stamp(x?.explained_at)
  );
  if(!items.length)return null;
  items.sort((a,b)=>stamp(a.explained_at)-stamp(b.explained_at));
  const latest=items.at(-1);
  const ts=latest.explained_at;
  const same=items.filter(x=>Math.abs(stamp(x.explained_at)-stamp(ts))<1500);
  return normalizeTrace({
    run_id:"persisted-"+String(ts).replace(/[^0-9]/g,"").slice(0,14),
    source:"chat",
    status:"DONE",
    phase:"closing",
    started_at:ts,
    updated_at:ts,
    finished_at:ts,
    current:same.length,
    total:same.length,
    summary:{trends_processed:same.length,trends_explained:same.length},
    message:"Recuperada desde la persistencia editorial verificada en main."
  });
}
function manualFallback(items,request){
  const command_id=String(request.command_id||"").trim();
  const requested_at=String(request.requested_at||"").trim();
  if(!command_id||!requested_at)return null;
  const marks=items.filter(c=>String(c.body||"").startsWith(STATUS_PREFIX+command_id+"\n"));
  const last=marks.at(-1);
  const rawStatus=last?field(last.body,"status")||"REQUESTED":"REQUESTED";
  const started=marks.find(c=>field(c.body,"status")==="RUNNING");
  const started_at=started?(field(started.body,"started_at")||started.created_at):null;
  const noStart=rawStatus==="REQUESTED"&&!started_at&&Date.now()-stamp(requested_at)>=START_ACK_MS;
  const staleRunning=rawStatus==="RUNNING"&&Date.now()-stamp(last?.updated_at||last?.created_at||requested_at)>=STALE_MS;
  const status=(noStart||staleRunning)?"ERROR":rawStatus;
  const lastActivity=last?.updated_at||last?.created_at||requested_at;
  const finished_at=noStart||staleRunning?lastActivity:(["DONE","ERROR"].includes(status)&&last?(field(last.body,"finished_at")||last.created_at):null);
  const timeoutMessage=noStart
    ?"No se ha recibido RUNNING: ningún ejecutor ha recogido el activador. El commit del PR #7 no inicia la elaboración por sí solo."
    :staleRunning?"La ejecución no actualiza su estado desde hace más de 20 minutos.":null;
  return {
    run_id:command_id,command_id,source:"manual",source_label:"Manual",status,
    phase:status==="REQUESTED"?"preparing":status==="RUNNING"?"running":status==="DONE"?"closing":"error",
    current:0,total:0,trend_id:null,title:null,requested_at,started_at,
    updated_at:lastActivity,finished_at,
    start_delay_seconds:started_at?seconds(requested_at,started_at):null,
    duration_seconds:started_at&&finished_at?seconds(started_at,finished_at):null,
    message:timeoutMessage||(last?field(last.body,"message"):null),summary:null,incident_count:0,incidents:[]
  }
}

export default async function handler(req,res){
  res.setHeader("cache-control","no-store");
  if(req.method!=="GET")return res.status(405).json({ok:false,error:"Método no permitido"});
  try{
    const [enabled,items,{doc:request},runtimeDoc,explainedDoc]=await Promise.all([
      triggerReady(),comments(),readTrigger(),readMainJson(RUNTIME_PATH),readMainJson(EXPLAINED_PATH)
    ]);
    const traces=items.map(traceOf).filter(Boolean).sort((a,b)=>stamp(a.updated_at||a.comment_updated_at)-stamp(b.updated_at||b.comment_updated_at));
    let latest=traces.length?normalizeTrace(traces.at(-1)):null;
    const fallback=manualFallback(items,request);
    let active=null;

    if(latest&&["REQUESTED","RUNNING"].includes(latest.status)){
      const lastActivity=latest.updated_at||latest.started_at||latest.requested_at;
      const age=Date.now()-stamp(lastActivity);
      const deadline=latest.status==="REQUESTED"?START_ACK_MS:STALE_MS;
      if(Number.isFinite(age)&&age>=0&&age<deadline)active=latest;
      else latest={...latest,status:"ERROR",finished_at:lastActivity||null,message:latest.status==="REQUESTED"
        ?"No se ha recibido RUNNING: ningún ejecutor ha recogido el activador en 3 minutos."
        :(latest.message||"La ejecución dejó de actualizar la telemetría durante más de 20 minutos.")}
    }
    if(!active&&fallback&&["REQUESTED","RUNNING"].includes(fallback.status)){
      const age=Date.now()-stamp(fallback.updated_at||fallback.started_at||fallback.requested_at);
      if(Number.isFinite(age)&&age>=0&&age<20*60*1000)active=fallback
    }

    if(active)return res.status(200).json({ok:true,enabled,active:true,...active,last_run:null,can_run:enabled&&authorized(req)});

    const terminal=traces.map(normalizeTrace).filter(t=>terminalStatus(t.status));
    if(latest&&terminalStatus(latest.status))terminal.push(latest);
    if(fallback&&terminalStatus(fallback.status))terminal.push(fallback);
    const runtime=runtimeFallback(runtimeDoc);
    const persisted=persistedExplanationFallback(explainedDoc);
    if(runtime)terminal.push(runtime);
    if(persisted)terminal.push(persisted);
    // El "último run" debe representar la ejecución más reciente iniciada/solicitada,
    // no el comentario terminal actualizado más tarde. Un activador antiguo puede cerrarse
    // con ERROR mucho después y no debe ocultar una ejecución real posterior.
    terminal.sort((a,b)=>{
      const aStarted=stamp(a.started_at||a.requested_at||a.finished_at||a.updated_at);
      const bStarted=stamp(b.started_at||b.requested_at||b.finished_at||b.updated_at);
      if(aStarted!==bStarted)return aStarted-bStarted;
      return stamp(a.finished_at||a.updated_at)-stamp(b.finished_at||b.updated_at);
    });
    const last_run=terminal.at(-1)||null;

    return res.status(200).json({ok:true,enabled,active:false,status:"IDLE",last_run,can_run:enabled&&authorized(req)})
  }catch(e){
    console.error(e);
    return res.status(500).json({ok:false,error:String(e.message||e)})
  }
}
