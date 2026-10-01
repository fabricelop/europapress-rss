const REPO=process.env.GITHUB_REPO||"fabricelop/europapress-rss";

const CONFIG={
  ttittulares:{
    branch:"control/ttittulares-run-trigger-v2",
    triggerPath:"ttittulares/run-now-trigger.json",
    ackPath:"ttittulares/run-ack.json"
  },
  ttendencias:{
    branch:"control/ttendencias-run-trigger",
    triggerPath:"trends/run-now-trigger.json",
    ackPath:"trends/run-ack.json"
  }
};

async function gh(url,options={}){
  if(!process.env.GITHUB_TOKEN)throw new Error("GITHUB_TOKEN no configurado");
  return fetch(url,{...options,headers:{
    accept:"application/vnd.github+json",
    authorization:"Bearer "+process.env.GITHUB_TOKEN,
    "x-github-api-version":"2022-11-28",
    "user-agent":"tt-pc-chat-ack",
    ...(options.headers||{})
  }})
}
function decodeContent(data){
  return Buffer.from(String(data?.content||"").replace(/\n/g,""),"base64").toString("utf8")
}
async function readJson(path,branch){
  const r=await gh("https://api.github.com/repos/"+REPO+"/contents/"+path+"?ref="+encodeURIComponent(branch));
  if(!r.ok)throw new Error("GitHub GET "+path+": "+r.status+" "+await r.text());
  const data=await r.json();
  return {doc:JSON.parse(decodeContent(data)||"{}"),sha:data.sha}
}
async function readOptionalJson(path,branch){
  const r=await gh("https://api.github.com/repos/"+REPO+"/contents/"+path+"?ref="+encodeURIComponent(branch));
  if(r.status===404)return {doc:{},sha:null};
  if(!r.ok)throw new Error("GitHub GET "+path+": "+r.status+" "+await r.text());
  const data=await r.json();
  return {doc:JSON.parse(decodeContent(data)||"{}"),sha:data.sha}
}
async function writeJson(path,branch,doc,sha,message){
  const body={
    message,
    content:Buffer.from(JSON.stringify(doc,null,2)+"\n","utf8").toString("base64"),
    branch
  };
  if(sha)body.sha=sha;
  const r=await gh("https://api.github.com/repos/"+REPO+"/contents/"+path,{
    method:"PUT",
    headers:{"content-type":"application/json"},
    body:JSON.stringify(body)
  });
  if(!r.ok)throw new Error("GitHub PUT "+path+": "+r.status+" "+await r.text());
  return r.json()
}
function stamp(v){const n=Date.parse(v||"");return Number.isFinite(n)?n:0}

export default async function handler(req,res){
  res.setHeader("cache-control","no-store");
  if(req.method!=="POST")return res.status(405).json({ok:false,error:"Método no permitido"});
  try{
    const project=String(req.body?.project||"").toLowerCase();
    const cfg=CONFIG[project];
    if(!cfg)return res.status(400).json({ok:false,error:"Proyecto no válido"});
    const command_id=String(req.body?.command_id||"").trim();
    const stage=String(req.body?.stage||"").toLowerCase();
    if(!command_id||!["picked_up","launched"].includes(stage))return res.status(400).json({ok:false,error:"Ack no válido"});

    const {doc:trigger}=await readJson(cfg.triggerPath,cfg.branch);
    if(String(trigger.command_id||"")!==command_id)return res.status(409).json({ok:false,error:"command_id ya no es el actual"});
    const requestedAt=String(trigger.requested_at||"");
    const age=Date.now()-stamp(requestedAt);
    if(!stamp(requestedAt)||age<0||age>10*60*1000)return res.status(409).json({ok:false,error:"Trigger fuera de ventana"});

    const current=await readOptionalJson(cfg.ackPath,cfg.branch);
    const now=new Date().toISOString();
    const same=String(current.doc?.command_id||"")===command_id;
    const doc={
      version:1,
      project,
      command_id,
      requested_at:requestedAt,
      stage,
      picked_up_at:same&&current.doc?.picked_up_at?current.doc.picked_up_at:now,
      launched_at:stage==="launched"?now:(same?current.doc?.launched_at||null:null),
      updated_at:now
    };
    await writeJson(cfg.ackPath,cfg.branch,doc,current.sha,"PC Chat ack "+project+" "+stage+" "+command_id);
    return res.status(200).json({ok:true,...doc})
  }catch(e){
    console.error(e);
    return res.status(500).json({ok:false,error:String(e?.message||e).slice(0,240)})
  }
}
