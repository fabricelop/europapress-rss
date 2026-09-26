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
const READY_MARKER="TTITTULARES WORK COMMIT TRIGGER READY";

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

export default async function handler(req,res){
  res.setHeader("cache-control","no-store");
  if(req.method!=="GET")return res.status(405).json({ok:false,error:"Método no permitido"});
  try{
    if(!(await triggerReady()))return res.status(200).json({ok:true,status:"DISABLED"});
    if(!authorized(req))return res.status(401).json({ok:false,error:"No autorizado"});

    const [{doc:request},items]=await Promise.all([readTrigger(),comments()]);
    const command_id=String(request.command_id||"").trim();
    const requested_at=String(request.requested_at||"").trim();
    if(!command_id||!requested_at)return res.status(200).json({ok:true,status:"IDLE"});

    const marks=items.filter(c=>String(c.body||"").startsWith(STATUS_PREFIX+command_id+"\n"));
    const last=marks.at(-1);
    let status=last?field(last.body,"status")||"REQUESTED":"REQUESTED";
    const requestAge=Date.now()-new Date(requested_at).getTime();
    if(!last&&Number.isFinite(requestAge)&&requestAge>30*60*1000)status="ERROR";
    const started=marks.find(c=>field(c.body,"status")==="RUNNING");
    const started_at=started?(field(started.body,"started_at")||started.created_at):null;
    const finished_at=["DONE","ERROR"].includes(status)&&last?(field(last.body,"finished_at")||last.created_at):null;
    // Un resultado terminal es solo informativo durante un breve intervalo.
    // Después volvemos a IDLE para que el panel recupere su estado normal y
    // no quede fijado indefinidamente mostrando un error o una ejecución antigua.
    if(["DONE","ERROR"].includes(status)&&finished_at){
      const age=Date.now()-new Date(finished_at).getTime();
      if(Number.isFinite(age)&&age>120000){
        return res.status(200).json({ok:true,status:"IDLE"});
      }
    }
    return res.status(200).json({
      ok:true,status,command_id,requested_at,started_at,finished_at,
      start_delay_seconds:started_at?seconds(requested_at,started_at):null,
      duration_seconds:started_at&&finished_at?seconds(started_at,finished_at):null,
      message:last?field(last.body,"message"):(status==="ERROR"?"Work no confirmó el arranque en 30 minutos":null)
    })
  }catch(e){
    console.error(e);
    return res.status(500).json({ok:false,error:String(e.message||e)})
  }
}
