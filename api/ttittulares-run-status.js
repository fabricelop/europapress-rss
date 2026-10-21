import crypto from "crypto";

const REPO = "fabricelop/europapress-rss";
const PR = 2;
const RUN_PREFIX = "RUN TTITTULARES\n";
const STATUS_PREFIX = "RUNSTATUS ";
const READY_MARKER = "TTITTULARES WORK TRIGGER READY";
const RUN_KEY_HASH = "9be0b022cbade3c3f61d867c52a1e46b532525e4b8ddfc354575157f189d6962";

function authorized(req){
  const supplied=String(req.headers["x-tt-run-key"]||"");
  const actual=crypto.createHash("sha256").update(supplied).digest("hex");
  return crypto.timingSafeEqual(Buffer.from(actual),Buffer.from(RUN_KEY_HASH));
}
function field(body,name){
  const m=String(body||"").match(new RegExp("^"+name+":\\s*(.+)$","mi"));
  return m?m[1].trim():null;
}
async function ghFetch(url,token){
  return fetch(url,{headers:{
    Authorization:"Bearer "+token,
    Accept:"application/vnd.github+json",
    "X-GitHub-Api-Version":"2022-11-28"
  }});
}
async function latestComments(token){
  const first=await ghFetch(`https://api.github.com/repos/${REPO}/issues/${PR}/comments?per_page=100`,token);
  if(!first.ok)throw Error(await first.text());
  let items=await first.json();
  const link=first.headers.get("link")||"";
  const last=link.match(/<([^>]+)>;\s*rel="last"/);
  if(last){
    const r=await ghFetch(last[1],token);
    if(!r.ok)throw Error(await r.text());
    items=await r.json();
  }
  return items;
}
function seconds(a,b){
  const x=new Date(a).getTime(),y=new Date(b).getTime();
  return Number.isFinite(x)&&Number.isFinite(y)?Math.max(0,Math.round((y-x)/1000)):null;
}

export default async function handler(req,res){
  if(req.method!=="GET")return res.status(405).json({error:"method"});
  const token=process.env.GITHUB_TOKEN||"";
  if(!token)return res.status(503).json({error:"github_token_missing"});

  try{
    const comments=await latestComments(token);
    const enabled=comments.some(c=>String(c.body||"").trim()===READY_MARKER);
    if(!enabled)return res.status(200).json({status:"DISABLED"});
    if(!authorized(req))return res.status(401).json({error:"unauthorized"});
    const request=[...comments].reverse().find(c=>typeof c.body==="string"&&c.body.startsWith(RUN_PREFIX));
    if(!request)return res.status(200).json({status:"IDLE"});

    const command_id=field(request.body,"command_id");
    const requested_at=field(request.body,"requested_at")||request.created_at;
    const marks=comments.filter(c=>typeof c.body==="string"&&c.body.startsWith(STATUS_PREFIX+command_id+"\n"));
    const last=marks.at(-1);
    const status=last?field(last.body,"status")||"REQUESTED":"REQUESTED";
    const started=marks.find(c=>field(c.body,"status")==="RUNNING");
    const started_at=started?(field(started.body,"started_at")||started.created_at):null;
    const finished_at=["DONE","ERROR"].includes(status)?(field(last.body,"finished_at")||last.created_at):null;
    if(["DONE","ERROR"].includes(status)&&finished_at){
      const age=Date.now()-new Date(finished_at).getTime();
      if(Number.isFinite(age)&&age>120000){
        return res.status(200).json({status:"IDLE"});
      }
    }

    return res.status(200).json({
      status,command_id,requested_at,started_at,finished_at,
      start_delay_seconds:started_at?seconds(requested_at,started_at):null,
      duration_seconds:started_at&&finished_at?seconds(started_at,finished_at):null,
      message:last?field(last.body,"message"):null
    });
  }catch(e){
    return res.status(500).json({error:"github_error",detail:String(e.message||e)});
  }
}
