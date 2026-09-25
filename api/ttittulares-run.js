import crypto from "crypto";

const REPO = "fabricelop/europapress-rss";
const PR = 2;
const RUN_PREFIX = "RUN TTITTULARES\n";
const RUN_KEY_HASH = "9be0b022cbade3c3f61d867c52a1e46b532525e4b8ddfc354575157f189d6962";

function authorized(req){
  const supplied=String(req.headers["x-tt-run-key"]||"");
  const actual=crypto.createHash("sha256").update(supplied).digest("hex");
  return crypto.timingSafeEqual(Buffer.from(actual),Buffer.from(RUN_KEY_HASH));
}
async function ghFetch(url,token,options={}){
  return fetch(url,{...options,headers:{
    Authorization:"Bearer "+token,
    Accept:"application/vnd.github+json",
    "X-GitHub-Api-Version":"2022-11-28",
    ...(options.headers||{})
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

export default async function handler(req,res){
  if(req.method!=="POST")return res.status(405).json({error:"method"});
  const token=process.env.GITHUB_TOKEN||"";
  if(!token)return res.status(503).json({error:"github_token_missing"});
  if(!authorized(req))return res.status(401).json({error:"unauthorized"});

  try{
    const comments=await latestComments(token);
    const enabled=comments.some(c=>String(c.body||"").trim()===READY_MARKER);
    if(!enabled)return res.status(503).json({error:"work_trigger_not_ready"});
    const latest=[...comments].reverse().find(c=>typeof c.body==="string"&&c.body.startsWith(RUN_PREFIX));
    if(latest){
      const age=Date.now()-new Date(latest.created_at).getTime();
      if(Number.isFinite(age)&&age<45000){
        return res.status(429).json({error:"recent_request",retry_after_seconds:Math.ceil((45000-age)/1000)});
      }
    }

    const requested_at=new Date().toISOString();
    const command_id=`tt-${Date.now()}-${crypto.randomBytes(3).toString("hex")}`;
    const body=`${RUN_PREFIX}command_id: ${command_id}\nrequested_at: ${requested_at}\nmode: manual`;
    const post=await ghFetch(`https://api.github.com/repos/${REPO}/issues/${PR}/comments`,token,{
      method:"POST",
      headers:{"Content-Type":"application/json"},
      body:JSON.stringify({body})
    });
    if(!post.ok)throw Error(await post.text());
    const created=await post.json();
    return res.status(200).json({ok:true,command_id,requested_at,comment_id:created.id});
  }catch(e){
    return res.status(500).json({error:"github_error",detail:String(e.message||e)});
  }
}
