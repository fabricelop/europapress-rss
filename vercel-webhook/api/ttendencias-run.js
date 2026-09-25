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
const READY_MARKER="TTENDENCIAS WORK COMMIT TRIGGER READY";

async function gh(url,options={}){
  if(!process.env.GITHUB_TOKEN)throw new Error("GITHUB_TOKEN no configurado");
  return fetch(url,{...options,headers:{
    accept:"application/vnd.github+json",
    authorization:`Bearer ${process.env.GITHUB_TOKEN}`,
    "x-github-api-version":"2022-11-28",
    "user-agent":"ttendencias-run-now",
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
  if(!r.ok)throw new Error(`GitHub trigger GET: ${r.status} ${await r.text()}`);
  const f=await r.json();
  const raw=Buffer.from(String(f.content||"").replace(/\n/g,""),"base64").toString("utf8");
  return {sha:f.sha,doc:JSON.parse(raw||"{}")}
}
function field(body,name){
  const m=String(body||"").match(new RegExp("^"+name+":\\s*(.+)$","mi"));
  return m?m[1].trim():null
}
function seconds(a,b){
  const x=new Date(a).getTime(),y=new Date(b).getTime();
  return Number.isFinite(x)&&Number.isFinite(y)?Math.max(0,Math.round((y-x)/1000)):null
}

async function writeTrigger(doc,sha){
  const body={
    message:`Solicitar ejecución manual TTendencias ${doc.command_id}`,
    content:Buffer.from(JSON.stringify(doc,null,2)+"\n","utf8").toString("base64"),
    sha,
    branch:TRIGGER_BRANCH
  };
  const r=await gh(`https://api.github.com/repos/${REPO}/contents/${TRIGGER_PATH}`,{
    method:"PUT",
    headers:{"content-type":"application/json"},
    body:JSON.stringify(body)
  });
  if(!r.ok)throw new Error(`GitHub trigger PUT: ${r.status} ${await r.text()}`);
  return r.json()
}

export default async function handler(req,res){
  res.setHeader("cache-control","no-store");
  if(req.method!=="POST")return res.status(405).json({ok:false,error:"Método no permitido"});
  if(!authorized(req))return res.status(401).json({ok:false,error:"No autorizado"});
  try{
    if(!(await triggerReady()))return res.status(503).json({ok:false,error:"work_trigger_not_ready"});

    const [{doc:current,sha},items]=await Promise.all([readTrigger(),comments()]);
    const currentId=String(current.command_id||"").trim();
    const currentRequested=String(current.requested_at||"").trim();
    if(currentId&&currentRequested){
      const age=Date.now()-new Date(currentRequested).getTime();
      const marks=items.filter(c=>String(c.body||"").startsWith(STATUS_PREFIX+currentId+"\n"));
      const last=marks.at(-1);
      const st=last?field(last.body,"status"):"REQUESTED";
      if(Number.isFinite(age)&&age<45000){
        return res.status(429).json({ok:false,error:"recent_request",retry_after_seconds:Math.ceil((45000-age)/1000)})
      }
      if(Number.isFinite(age)&&age<30*60*1000&&!["DONE","ERROR"].includes(st||"REQUESTED")){
        return res.status(409).json({ok:false,error:"run_in_progress"})
      }
    }

    const requested_at=new Date().toISOString();
    const command_id=`tr-${Date.now()}-${crypto.randomBytes(3).toString("hex")}`;
    const doc={version:1,command_id,requested_at,mode:"manual"};
    let saved;
    try{
      saved=await writeTrigger(doc,sha);
    }catch(e){
      if(!String(e.message||e).includes("409")&&!String(e.message||e).includes("422"))throw e;
      const fresh=await readTrigger();
      saved=await writeTrigger(doc,fresh.sha)
    }
    return res.status(200).json({
      ok:true,command_id,requested_at,
      commit_sha:saved?.commit?.sha||null,
      trigger:"pull_request_commit_update"
    })
  }catch(e){
    console.error(e);
    return res.status(500).json({ok:false,error:String(e.message||e)})
  }
}
