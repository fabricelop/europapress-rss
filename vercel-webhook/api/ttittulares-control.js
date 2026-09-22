import crypto from "node:crypto";

const REPO=process.env.GITHUB_REPO||"fabricelop/europapress-rss";
const BRANCH=process.env.GITHUB_BRANCH||"main";
const PREPARED="ttittulares/prepared.json";
const DECISIONS="ttittulares/decisions.json";
const PROCESSING="telegram/editorial-processing.json";
const CONTROL_TOKEN_HASH="2663da5223c2313c3670a7843a0cdfabfd2dd7c8fad1ed168247866a3b1262e5";

function b64d(s){return Buffer.from(String(s||"").replace(/\n/g,""),"base64").toString("utf8")}
function b64e(s){return Buffer.from(s,"utf8").toString("base64")}
function authToken(req){const h=String(req.headers.authorization||"");return h.startsWith("Bearer ")?h.slice(7).trim():""}
function authorized(req){
  // Los previews están protegidos por Vercel Deployment Protection.
  // No pedimos un segundo token dentro de la propia app.
  if(process.env.VERCEL_ENV==="preview")return true;
  const got=authToken(req);if(!got)return false;
  const expected=process.env.TTITTULARES_CONTROL_TOKEN||"";
  if(expected)return got===expected;
  const digest=crypto.createHash("sha256").update(got).digest("hex");
  return crypto.timingSafeEqual(Buffer.from(digest),Buffer.from(CONTROL_TOKEN_HASH));
}
async function gh(path,options={}){
  if(!process.env.GITHUB_TOKEN)throw new Error("GITHUB_TOKEN no configurado");
  return fetch(`https://api.github.com/repos/${REPO}/${path}`,{
    ...options,
    headers:{accept:"application/vnd.github+json",authorization:`Bearer ${process.env.GITHUB_TOKEN}`,
      "x-github-api-version":"2022-11-28","user-agent":"ttittulares-web-control",...(options.headers||{})}
  })
}
async function readJson(path){
  const r=await gh(`contents/${path}?ref=${encodeURIComponent(BRANCH)}`);
  if(!r.ok)throw new Error(`GitHub GET ${path}: ${r.status} ${await r.text()}`);
  const f=await r.json();return {doc:JSON.parse(b64d(f.content)||"{}"),sha:f.sha}
}
async function mutateJson(path,message,fn){
  for(let attempt=1;attempt<=5;attempt++){
    const {doc,sha}=await readJson(path);const before=JSON.stringify(doc);const next=await fn(doc);
    if(JSON.stringify(next)===before)return next;
    const r=await gh(`contents/${path}`,{method:"PUT",headers:{"content-type":"application/json"},body:JSON.stringify({
      message,content:b64e(JSON.stringify(next,null,2)+"\n"),sha,branch:BRANCH
    })});
    if(r.ok)return next;
    if(![409,422].includes(r.status))throw new Error(`GitHub PUT ${path}: ${r.status} ${await r.text()}`);
    await new Promise(resolve=>setTimeout(resolve,attempt*150));
  }
  throw new Error(`Conflicto persistente actualizando ${path}`)
}
function idOf(v){return String(v||"").trim()}
async function closePrepared(eventId,status){
  const id=idOf(eventId);if(!id)throw new Error("Falta event_id");
  const now=new Date().toISOString();
  await mutateJson(DECISIONS,`${status==="published"?"Publicar":"Desestimar"} TTiTTulares desde web`,doc=>{
    doc.project||="TTiTTulares";doc.items||=[];
    const old=doc.items.find(x=>idOf(x.event_id)===id);
    if(old)Object.assign(old,{status,updated_at:now});
    else doc.items.push({event_id:id,status,updated_at:now});
    doc.updated_at=now;return doc
  });
  await mutateJson(PREPARED,"Retirar noticia cerrada de TTiTTulares web",doc=>{
    doc.items=(doc.items||[]).filter(x=>idOf(x.event_id)!==id);doc.updated_at=now;return doc
  });
  await mutateJson(PROCESSING,"Actualizar cierre web TTiTTulares",doc=>{
    for(const item of doc.items||[])if(idOf(item.event_id)===id){
      item.status=status==="published"?"PUBLISHED":"DISMISSED";
      item[status==="published"?"published_at":"dismissed_at"]=now
    }
    doc.updated_at=now;return doc
  });
  return {ok:true,event_id:id,status}
}
async function rework(eventId,instruction){
  const id=idOf(eventId),text=String(instruction||"").trim();
  if(!id)throw new Error("Falta event_id");if(!text)throw new Error("Escribe las instrucciones para rehacer.");
  const now=new Date().toISOString();
  const {doc:prepared}=await readJson(PREPARED);
  const source=(prepared.items||[]).find(x=>idOf(x.event_id)===id)||{};
  await mutateJson(PROCESSING,"Rehacer noticia TTiTTulares desde web",doc=>{
    doc.items||=[];let item=[...doc.items].reverse().find(x=>idOf(x.event_id)===id);
    if(!item){
      item={event_id:id,title:source.title||"",url:source.url||"",sources:source.sources_at_draft||[],source_count:Number(source.drafted_source_count||0),selected_at:now};
      doc.items.push(item)
    }
    item.previous_status=item.status;item.status="PROCESSING";item.selection_mode="REWRITE";
    item.rewrite_request=text;item.rewrite_requested_at=now;item.rewrite_version=Number(item.rewrite_version||0)+1;
    item.revision=Number(item.revision||source.revision||1)+1;delete item.delivered_at;delete item.published_at;delete item.dismissed_at;
    doc.updated_at=now;return doc
  });
  await mutateJson(PREPARED,"Retirar versión antigua para rehacer TTiTTulares",doc=>{
    doc.items=(doc.items||[]).filter(x=>idOf(x.event_id)!==id);doc.updated_at=now;return doc
  });
  await mutateJson(DECISIONS,"Reabrir noticia TTiTTulares desde web",doc=>{
    doc.items=(doc.items||[]).filter(x=>idOf(x.event_id)!==id);doc.updated_at=now;return doc
  });
  return {ok:true,event_id:id,status:"PROCESSING"}
}
async function backendStatus(){
  const [config,status]=await Promise.all([
    gh(`contents/ttittulares/config.json?ref=${encodeURIComponent(BRANCH)}`),
    gh(`contents/ttittulares/status.json?ref=${encodeURIComponent(BRANCH)}`)
  ]);
  return {ok:config.ok&&status.ok,status:config.ok&&status.ok?200:503}
}
export default async function handler(req,res){
  res.setHeader("cache-control","no-store");
  try{
    if(req.method==="GET"){
      const [prepared,status]=await Promise.all([readJson(PREPARED),readJson("ttittulares/status.json")]);
      return res.status(200).json({ok:true,service:"ttittulares-control",prepared:prepared.doc,status:status.doc})
    }
    if(req.method!=="POST")return res.status(405).json({ok:false,error:"Método no permitido"});
    if(!authorized(req))return res.status(401).json({ok:false,error:"No autorizado"});
    const body=req.body||{},action=String(body.action||"");
    if(action==="ping"){const backend=await backendStatus();return res.status(backend.ok?200:503).json({ok:backend.ok,access:"granted",backend})}
    if(action==="published")return res.status(200).json(await closePrepared(body.event_id,"published"));
    if(action==="dismiss")return res.status(200).json(await closePrepared(body.event_id,"dismissed"));
    if(action==="rework")return res.status(200).json(await rework(body.event_id,body.instruction));
    return res.status(400).json({ok:false,error:"Acción no válida"})
  }catch(e){console.error(e);return res.status(500).json({ok:false,error:String(e.message||e)})}
}
