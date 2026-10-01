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
const ACTIVE_MS=20*60*1000;

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
async function triggerReady(){
  const r=await gh("https://api.github.com/repos/"+REPO+"/pulls/"+PR);
  if(!r.ok)throw new Error("GitHub PR: "+r.status+" "+await r.text());
  return String((await r.json()).body||"").includes(READY_MARKER)
}
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
  const fresh=items.map(traceOf).filter(Boolean).filter(t=>["REQUESTED","RUNNING"].includes(String(t.status||""))).filter(t=>{
    const age=Date.now()-stamp(t.comment_updated_at||t.updated_at||t.started_at||t.requested_at);
    return Number.isFinite(age)&&age>=0&&age<ACTIVE_MS
  });
  fresh.sort((a,b)=>stamp(a.comment_updated_at||a.updated_at)-stamp(b.comment_updated_at||b.updated_at));
  return fresh.at(-1)||null
}
async function writeTrigger(doc,sha){
  const r=await gh("https://api.github.com/repos/"+REPO+"/contents/"+TRIGGER_PATH,{method:"PUT",headers:{"content-type":"application/json"},body:JSON.stringify({message:"Solicitar ejecución manual TTendencias "+doc.command_id,content:Buffer.from(JSON.stringify(doc,null,2)+"\n","utf8").toString("base64"),sha,branch:TRIGGER_BRANCH})});
  if(!r.ok)throw new Error("GitHub trigger PUT: "+r.status+" "+await r.text());return r.json()
}
async function createTrace(doc){
  const trace={version:1,run_id:doc.command_id,command_id:doc.command_id,source:"manual",status:"REQUESTED",phase:"preparing",current:0,total:0,trend_id:null,title:null,requested_at:doc.requested_at,started_at:null,updated_at:doc.requested_at,finished_at:null,incident_count:0,incidents:[],summary:null,message:"Solicitud recibida; esperando a ChatGPT Work."};
  const r=await gh("https://api.github.com/repos/"+REPO+"/issues/"+PR+"/comments",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({body:TRACE_PREFIX+JSON.stringify(trace)})});
  if(!r.ok)throw new Error("GitHub trace POST: "+r.status+" "+await r.text());return r.json()
}
export default async function handler(req,res){
  res.setHeader("cache-control","no-store");
  if(req.method!=="POST")return res.status(405).json({ok:false,error:"Método no permitido"});
  if(!authorized(req))return res.status(401).json({ok:false,error:"No autorizado"});
  try{
    if(!(await triggerReady()))return res.status(503).json({ok:false,error:"work_trigger_not_ready"});
    const [{doc:current,sha},items]=await Promise.all([readTrigger(),comments()]);
    if(activeTrace(items))return res.status(409).json({ok:false,error:"run_in_progress"});
    const currentId=String(current.command_id||"").trim(),currentRequested=String(current.requested_at||"").trim();
    if(currentId&&currentRequested){
      const age=Date.now()-new Date(currentRequested).getTime();
      const marks=items.filter(c=>String(c.body||"").startsWith(STATUS_PREFIX+currentId+"\n")),last=marks.at(-1),st=last?field(last.body,"status"):"REQUESTED";
      if(Number.isFinite(age)&&age<45000)return res.status(429).json({ok:false,error:"recent_request",retry_after_seconds:Math.ceil((45000-age)/1000)});
      if(Number.isFinite(age)&&age<ACTIVE_MS&&!["DONE","ERROR"].includes(st||"REQUESTED"))return res.status(409).json({ok:false,error:"run_in_progress"})
    }
    const requested_at=new Date().toISOString(),command_id="tr-"+Date.now()+"-"+crypto.randomBytes(3).toString("hex"),doc={version:1,command_id,requested_at,mode:"manual"};
    let saved;try{saved=await writeTrigger(doc,sha)}catch(e){if(!String(e.message||e).includes("409")&&!String(e.message||e).includes("422"))throw e;const fresh=await readTrigger();saved=await writeTrigger(doc,fresh.sha)}
    let trace_comment_id=null;try{trace_comment_id=(await createTrace(doc)).id||null}catch(e){console.error("trace",e)}
    return res.status(200).json({ok:true,command_id,requested_at,commit_sha:saved?.commit?.sha||null,trace_comment_id,trigger:"pull_request_commit_update"})
  }catch(e){console.error(e);return res.status(500).json({ok:false,error:String(e.message||e)})}
}
