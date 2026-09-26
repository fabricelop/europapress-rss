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
const STATUS_PREFIX="RUNSTATUS ";
const TRACE_PREFIX="TTITTULARES_RUNTRACE_V1\n";
const READY_MARKER="TTITTULARES WORK COMMIT TRIGGER READY";
const STALE_MS=45*60*1000;

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
async function comments(){
  const base=`https://api.github.com/repos/${REPO}/issues/${PR}/comments?per_page=100`;
  const first=await gh(base);
  if(!first.ok)throw new Error(`GitHub comments: ${first.status} ${await first.text()}`);
  let items=await first.json();
  const link=first.headers.get("link")||"";
  const last=link.match(/<([^>]+)>;\s*rel="last"/);
  if(last){
    const r=await gh(last[1]);
    if(!r.ok)throw new Error(`GitHub comments: ${r.status} ${await r.text()}`);
    items=await r.json()
  }
  return items
}
async function triggerReady(){
  const r=await gh(`https://api.github.com/repos/${REPO}/pulls/${PR}`);
  if(!r.ok)throw new Error(`GitHub PR: ${r.status} ${await r.text()}`);
  const pr=await r.json();
  return String(pr.body||"").includes(READY_MARKER)
}
async function readTrigger(){
  const u=`https://api.github.com/repos/${REPO}/contents/${TRIGGER_PATH}?ref=${encodeURIComponent(TRIGGER_BRANCH)}`;
  const r=await gh(u);
  if(!r.ok)return {doc:{}};
  const f=await r.json();
  const raw=Buffer.from(String(f.content||"").replace(/\n/g,""),"base64").toString("utf8");
  return {doc:JSON.parse(raw||"{}")}
}
async function readErrors(){
  const u=`https://api.github.com/repos/${REPO}/contents/ttittulares/execution-errors.json?ref=main`;
  const r=await gh(u);
  if(!r.ok)return [];
  const f=await r.json();
  const raw=Buffer.from(String(f.content||"").replace(/\n/g,""),"base64").toString("utf8");
  try{return (JSON.parse(raw||"{}").items||[]).map(x=>({at:x.at||null,event_id:x.event_id||null,phase:x.phase||null,reason:String(x.reason||"").slice(0,1200)}))}catch(_){return []}
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
  const incidents=incidentsFor(errors,started,finished);
  const incident_count=Math.max(Number(t.incident_count||0),incidents.length);
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
    finished_at:finished,
    duration_seconds:started&&finished?seconds(started,finished):null,
    message:t.message||null,
    summary:t.summary||null,
    incident_count,
    incidents
  }
}
function manualFallback(items,request){
  const command_id=String(request.command_id||"").trim();
  const requested_at=String(request.requested_at||"").trim();
  if(!command_id||!requested_at)return null;
  const marks=items.filter(c=>String(c.body||"").startsWith(STATUS_PREFIX+command_id+"\n"));
  const last=marks.at(-1);
  const status=last?field(last.body,"status")||"REQUESTED":"REQUESTED";
  const started=marks.find(c=>field(c.body,"status")==="RUNNING");
  const started_at=started?(field(started.body,"started_at")||started.created_at):null;
  const finished_at=["DONE","ERROR"].includes(status)&&last?(field(last.body,"finished_at")||last.created_at):null;
  return {
    run_id:command_id,command_id,source:"manual",source_label:"Manual",status,
    phase:status==="REQUESTED"?"preparing":status==="RUNNING"?"running":status==="DONE"?"closing":"error",
    current:0,total:0,event_id:null,title:null,requested_at,started_at,updated_at:last?.updated_at||last?.created_at||requested_at,finished_at,
    start_delay_seconds:started_at?seconds(requested_at,started_at):null,
    duration_seconds:started_at&&finished_at?seconds(started_at,finished_at):null,
    message:last?field(last.body,"message"):null,summary:null,incident_count:0,incidents:[]
  }
}

export default async function handler(req,res){
  res.setHeader("cache-control","no-store");
  if(req.method!=="GET")return res.status(405).json({ok:false,error:"Método no permitido"});
  try{
    const [enabled,items]=await Promise.all([triggerReady(),comments()]);
    const traces=items.map(traceOf).filter(Boolean).sort((a,b)=>stamp(a.comment_updated_at||a.updated_at)-stamp(b.comment_updated_at||b.updated_at));
    const latestRaw=traces.at(-1)||null;
    let errors=[];
    if(latestRaw&&Number(latestRaw.incident_count||0)>0)errors=await readErrors();
    let latest=latestRaw?normalizeTrace(latestRaw,errors):null;

    let active=null;
    if(latest&&["REQUESTED","RUNNING"].includes(latest.status)){
      const freshAt=latest.telemetry_comment_updated_at||latest.updated_at||latest.started_at||latest.requested_at;
      const age=Date.now()-stamp(freshAt);
      if(Number.isFinite(age)&&age<STALE_MS)active=latest;
      else latest={...latest,status:"ERROR",finished_at:latest.updated_at||new Date().toISOString(),message:latest.message||"La ejecución dejó de actualizar la telemetría durante más de 45 minutos."}
    }

    let fallback=null;
    if(!active){
      const {doc:request}=await readTrigger();
      fallback=manualFallback(items,request);
      if(fallback&&["REQUESTED","RUNNING"].includes(fallback.status)){
        const newer=!latest||stamp(fallback.requested_at)>stamp(latest.updated_at||latest.finished_at||latest.requested_at);
        const age=Date.now()-stamp(fallback.updated_at||fallback.started_at||fallback.requested_at);
        if(newer&&Number.isFinite(age)&&age>=0&&age<30*60*1000)active=fallback
      }
    }

    if(active){
      if(Number(active.incident_count||0)>0&&!errors.length)errors=await readErrors();
      active.incidents=incidentsFor(errors,active.started_at||active.requested_at,null);
      active.incident_count=Math.max(Number(active.incident_count||0),active.incidents.length);
      return res.status(200).json({ok:true,enabled,active:true,...active,last_run:null,can_run:enabled&&authorized(req)})
    }

    let last_run=null;
    if(latest&&["DONE","ERROR"].includes(latest.status))last_run=latest;
    else{
      const terminalTraces=traces.filter(t=>["DONE","ERROR"].includes(t.status));
      if(terminalTraces.length){
        const raw=terminalTraces.at(-1);
        if(Number(raw.incident_count||0)>0&&!errors.length)errors=await readErrors();
        last_run=normalizeTrace(raw,errors)
      }else if(fallback&&["DONE","ERROR"].includes(fallback.status)){
        if(!errors.length)errors=await readErrors();
        const inc=incidentsFor(errors,fallback.started_at||fallback.requested_at,fallback.finished_at);
        last_run={...fallback,incidents:inc,incident_count:inc.length}
      }
    }
    return res.status(200).json({ok:true,enabled,active:false,status:"IDLE",last_run,can_run:enabled&&authorized(req)})
  }catch(e){
    console.error(e);
    return res.status(500).json({ok:false,error:String(e.message||e)})
  }
}
