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
const RUN_PREFIX="RUN TTITTULARES\n";
const STATUS_PREFIX="RUNSTATUS ";
const READY_MARKER="TTITTULARES WORK TRIGGER READY";
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

export default async function handler(req,res){
  res.setHeader("cache-control","no-store");
  if(req.method!=="POST")return res.status(405).json({ok:false,error:"Método no permitido"});
  if(!authorized(req))return res.status(401).json({ok:false,error:"No autorizado"});
  try{
    const items=await comments();
    const enabled=items.some(c=>String(c.body||"").trim()===READY_MARKER);
    if(!enabled)return res.status(503).json({ok:false,error:"work_trigger_not_ready"});

    const latest=[...items].reverse().find(c=>String(c.body||"").startsWith(RUN_PREFIX));
    if(latest){
      const age=Date.now()-new Date(latest.created_at).getTime();
      if(Number.isFinite(age)&&age<45000){
        return res.status(429).json({ok:false,error:"recent_request",retry_after_seconds:Math.ceil((45000-age)/1000)})
      }
      const latestId=String(latest.body||"").match(/^command_id:\s*(.+)$/mi)?.[1]?.trim();
      if(latestId){
        const states=items.filter(c=>String(c.body||"").startsWith(STATUS_PREFIX+latestId+"\n"));
        const lastState=states.at(-1);
        const st=String(lastState?.body||"").match(/^status:\s*(.+)$/mi)?.[1]?.trim();
        if(age<30*60*1000&&["REQUESTED","RUNNING"].includes(st||"RUNNING")){
          return res.status(409).json({ok:false,error:"run_in_progress"})
        }
      }
    }

    const requested_at=new Date().toISOString();
    const command_id=`tt-${Date.now()}-${crypto.randomBytes(3).toString("hex")}`;
    const body=`${RUN_PREFIX}command_id: ${command_id}\nrequested_at: ${requested_at}\nmode: manual`;
    const r=await gh(`https://api.github.com/repos/${REPO}/issues/${PR}/comments`,{
      method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({body})
    });
    if(!r.ok)throw new Error(`GitHub POST: ${r.status} ${await r.text()}`);
    const created=await r.json();
    return res.status(200).json({ok:true,command_id,requested_at,comment_id:created.id})
  }catch(e){
    console.error(e);
    return res.status(500).json({ok:false,error:String(e.message||e)})
  }
}
