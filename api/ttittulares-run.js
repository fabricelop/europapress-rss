import crypto from "crypto";

const REPO = "fabricelop/europapress-rss";
const RUN_PREFIX = "RUN TTITTULARES\n";

function safeEqual(a,b){
  const aa=Buffer.from(String(a||"")), bb=Buffer.from(String(b||""));
  return aa.length===bb.length && crypto.timingSafeEqual(aa,bb);
}
async function ghFetch(url,token,options={}){
  return fetch(url,{...options,headers:{
    Authorization:"Bearer "+token,
    Accept:"application/vnd.github+json",
    "X-GitHub-Api-Version":"2022-11-28",
    ...(options.headers||{})
  }});
}
async function latestComments(token,pr){
  const first=await ghFetch(`https://api.github.com/repos/${REPO}/issues/${pr}/comments?per_page=100`,token);
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
  const secret=process.env.TTITTULARES_RUN_SECRET||"";
  const pr=Number(process.env.TTITTULARES_RUN_PR_NUMBER||0);
  if(!token||!secret||!Number.isInteger(pr)||pr<1)return res.status(503).json({error:"run_not_configured"});
  const supplied=String(req.headers["x-tt-run-key"]||"");
  if(!safeEqual(supplied,secret))return res.status(401).json({error:"unauthorized"});

  try{
    const comments=await latestComments(token,pr);
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
    const post=await ghFetch(`https://api.github.com/repos/${REPO}/issues/${pr}/comments`,token,{
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
