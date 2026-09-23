import crypto from "node:crypto";

const REPO=process.env.GITHUB_REPO||"fabricelop/europapress-rss";
const BRANCH=process.env.GITHUB_BRANCH||"main";
const SUBS="ttittulares/push-subscriptions.json";
const PREPARED="ttittulares/prepared.json";
const CONTROL_TOKEN_HASH="cdaa00313ab7f8031d485ac42ec8bb5d22eadf41a27e719848c8c6fcf40f3c98";

function b64url(buf){return Buffer.from(buf).toString("base64url")}
function b64d(s){return Buffer.from(String(s||"").replace(/\n/g,""),"base64").toString("utf8")}
function b64e(s){return Buffer.from(s,"utf8").toString("base64")}
function authToken(req){const h=String(req.headers.authorization||"");return h.startsWith("Bearer ")?h.slice(7).trim():""}
function authorized(req){
  const got=authToken(req);if(!got)return false;
  const expected=process.env.TTITTULARES_CONTROL_TOKEN||"";
  if(expected&&got===expected)return true;
  const digest=crypto.createHash("sha256").update(got).digest("hex");
  return crypto.timingSafeEqual(Buffer.from(digest),Buffer.from(CONTROL_TOKEN_HASH));
}
function secret(){
  const v=process.env.TTITTULARES_CONTROL_TOKEN||process.env.GITHUB_TOKEN;
  if(!v)throw new Error("Falta secreto servidor para push");
  return crypto.createHash("sha256").update("ttittulares-push:"+v).digest();
}
function enc(obj){
  const iv=crypto.randomBytes(12),key=secret(),c=crypto.createCipheriv("aes-256-gcm",key,iv);
  const body=Buffer.concat([c.update(JSON.stringify(obj),"utf8"),c.final()]);
  return {iv:b64url(iv),tag:b64url(c.getAuthTag()),data:b64url(body)}
}
function dec(v){
  const key=secret(),d=crypto.createDecipheriv("aes-256-gcm",key,Buffer.from(v.iv,"base64url"));
  d.setAuthTag(Buffer.from(v.tag,"base64url"));
  return JSON.parse(Buffer.concat([d.update(Buffer.from(v.data,"base64url")),d.final()]).toString("utf8"))
}
async function gh(path,options={}){
  if(!process.env.GITHUB_TOKEN)throw new Error("GITHUB_TOKEN no configurado");
  return fetch(`https://api.github.com/repos/${REPO}/${path}`,{...options,headers:{
    accept:"application/vnd.github+json",authorization:`Bearer ${process.env.GITHUB_TOKEN}`,
    "x-github-api-version":"2022-11-28","user-agent":"ttittulares-push",...(options.headers||{})
  }})
}
async function readJson(path,def={}){
  const r=await gh(`contents/${path}?ref=${encodeURIComponent(BRANCH)}`);
  if(r.status===404)return {doc:def,sha:null};
  if(!r.ok)throw new Error(`GitHub GET ${path}: ${r.status}`);
  const f=await r.json();return {doc:JSON.parse(b64d(f.content)||"{}"),sha:f.sha}
}
async function writeJson(path,message,doc,sha){
  const body={message,content:b64e(JSON.stringify(doc,null,2)+"\n"),branch:BRANCH};if(sha)body.sha=sha;
  const r=await gh(`contents/${path}`,{method:"PUT",headers:{"content-type":"application/json"},body:JSON.stringify(body)});
  if(!r.ok)throw new Error(`GitHub PUT ${path}: ${r.status} ${await r.text()}`)
}
function vapid(){
  const order=BigInt("0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551");
  const raw=crypto.createHash("sha256").update(Buffer.concat([Buffer.from("vapid:"),secret()])).digest();
  const n=(BigInt("0x"+raw.toString("hex"))%(order-1n))+1n;
  const d=Buffer.from(n.toString(16).padStart(64,"0"),"hex");
  const e=crypto.createECDH("prime256v1");e.setPrivateKey(d);const pub=e.getPublicKey(null,"uncompressed");
  const x=pub.subarray(1,33),y=pub.subarray(33,65);
  const key=crypto.createPrivateKey({key:{kty:"EC",crv:"P-256",x:b64url(x),y:b64url(y),d:b64url(d)},format:"jwk"});
  return {d,pub,key}
}
function hkdfExtract(salt,ikm){return crypto.createHmac("sha256",salt).update(ikm).digest()}
function hkdfExpand(prk,info,len){let out=Buffer.alloc(0),t=Buffer.alloc(0),i=1;while(out.length<len){t=crypto.createHmac("sha256",prk).update(Buffer.concat([t,info,Buffer.from([i++])])).digest();out=Buffer.concat([out,t])}return out.subarray(0,len)}
async function sendPush(sub,payload){
  const endpoint=new URL(sub.endpoint),clientPub=Buffer.from(sub.keys.p256dh,"base64url"),auth=Buffer.from(sub.keys.auth,"base64url");
  const eph=crypto.createECDH("prime256v1");eph.generateKeys();const serverPub=eph.getPublicKey(null,"uncompressed");
  const shared=eph.computeSecret(clientPub);
  const prkKey=hkdfExtract(auth,shared);
  const ikm=hkdfExpand(prkKey,Buffer.concat([Buffer.from("WebPush: info\0"),clientPub,serverPub]),32);
  const salt=crypto.randomBytes(16),prk=hkdfExtract(salt,ikm);
  const cek=hkdfExpand(prk,Buffer.from("Content-Encoding: aes128gcm\0"),16);
  const nonce=hkdfExpand(prk,Buffer.from("Content-Encoding: nonce\0"),12);
  const plain=Buffer.concat([Buffer.from(JSON.stringify(payload),"utf8"),Buffer.from([2])]);
  const cipher=crypto.createCipheriv("aes-128-gcm",cek,nonce),ct=Buffer.concat([cipher.update(plain),cipher.final(),cipher.getAuthTag()]);
  const rs=Buffer.alloc(4);rs.writeUInt32BE(4096,0);
  const body=Buffer.concat([salt,rs,Buffer.from([serverPub.length]),serverPub,ct]);

  const v=vapid(),now=Math.floor(Date.now()/1000),aud=endpoint.origin;
  const header=b64url(Buffer.from(JSON.stringify({typ:"JWT",alg:"ES256"})));
  const claims=b64url(Buffer.from(JSON.stringify({aud,exp:now+43200,sub:"mailto:ttittulares@local.invalid"})));
  const unsigned=header+"."+claims;
  const sig=crypto.sign("sha256",Buffer.from(unsigned),{key:v.key,dsaEncoding:"ieee-p1363"});
  const jwt=unsigned+"."+b64url(sig);
  const r=await fetch(sub.endpoint,{method:"POST",headers:{
    TTL:"86400","Content-Encoding":"aes128gcm",
    Authorization:`vapid t=${jwt}, k=${b64url(v.pub)}`,
    "Content-Type":"application/octet-stream"
  },body});
  return r.status;
}
async function subscribe(subscription){
  const {doc,sha}=await readJson(SUBS,{version:1,items:[],sent_event_ids:[]});
  doc.items||=[];doc.sent_event_ids||=[];
  const endpoint=String(subscription?.endpoint||"");if(!endpoint)throw new Error("Suscripción inválida");
  const endpointHash=crypto.createHash("sha256").update(endpoint).digest("hex");
  doc.items=doc.items.filter(x=>x.endpoint_hash!==endpointHash);
  doc.items.push({endpoint_hash:endpointHash,subscription:enc(subscription),updated_at:new Date().toISOString()});
  doc.updated_at=new Date().toISOString();
  await writeJson(SUBS,"Registrar notificaciones TTiTTulares",doc,sha);
  return {ok:true}
}
async function drain(){
  const [{doc,sha},{doc:prepared}]=await Promise.all([
    readJson(SUBS,{version:1,items:[],sent_event_ids:[]}),
    readJson(PREPARED,{items:[]})
  ]);
  doc.items||=[];doc.sent_event_ids||=[];
  const sent=new Set(doc.sent_event_ids.map(String));
  const pending=(prepared.items||[]).filter(x=>x.event_id&&!sent.has(String(x.event_id)));
  if(!pending.length)return {ok:true,news:0,deliveries:0,subscriptions:doc.items.length};

  const alive=[];const deliveredEvents=new Set();const attempts=[];
  for(const row of doc.items){
    let sub;
    try{sub=dec(row.subscription)}
    catch(e){attempts.push({endpoint_hash:row.endpoint_hash,status:"decrypt_error",error:String(e.message||e)});continue}
    let good=true;
    for(const item of pending){
      try{
        const code=await sendPush(sub,{
          title:"TTiTTulares · noticia lista",
          body:String(item.title||"Hay una noticia lista para publicar"),
          event_id:String(item.event_id),
          url:"/ttittulares/"
        });
        attempts.push({endpoint_hash:row.endpoint_hash,event_id:String(item.event_id),status:code});
        console.log("PUSH_RESULT",row.endpoint_hash,String(item.event_id),code);
        if(code===404||code===410){good=false;break}
        if(code>=200&&code<300)deliveredEvents.add(String(item.event_id));
      }catch(e){
        attempts.push({endpoint_hash:row.endpoint_hash,event_id:String(item.event_id),status:"error",error:String(e.message||e)});
        console.error("PUSH_ERROR",row.endpoint_hash,String(item.event_id),String(e.message||e));
      }
    }
    if(good)alive.push(row)
  }

  doc.items=alive;
  for(const eid of deliveredEvents)sent.add(eid);
  doc.sent_event_ids=[...sent].slice(-500);
  doc.last_attempt_at=new Date().toISOString();
  doc.last_attempt={pending:pending.map(x=>String(x.event_id)),delivered:[...deliveredEvents],attempts};
  doc.updated_at=new Date().toISOString();
  await writeJson(SUBS,"Actualizar notificaciones enviadas TTiTTulares",doc,sha);

  const missed=pending.map(x=>String(x.event_id)).filter(eid=>!deliveredEvents.has(eid));
  if(missed.length)console.error("PUSH_UNDELIVERED",missed.join(","));
  return {ok:missed.length===0,news:pending.length,deliveries:deliveredEvents.size,subscriptions:alive.length,missed,attempts}
}

async function testPush(){
  const {doc}=await readJson(SUBS,{version:1,items:[]});
  const attempts=[];let delivered=0;const alive=[];
  for(const row of doc.items||[]){
    let sub;
    try{sub=dec(row.subscription)}catch(e){attempts.push({endpoint_hash:row.endpoint_hash,status:"decrypt_error"});continue}
    try{
      const code=await sendPush(sub,{title:"TTiTTulares",body:"Notificaciones funcionando",event_id:"push-test-"+Date.now(),url:"/ttittulares/"});
      attempts.push({endpoint_hash:row.endpoint_hash,status:code});
      if(code>=200&&code<300){delivered++;alive.push(row)}
    }catch(e){attempts.push({endpoint_hash:row.endpoint_hash,status:"error",error:String(e.message||e)})}
  }
  return {ok:delivered>0,delivered,attempts}
}

export default async function handler(req,res){
  res.setHeader("cache-control","no-store");
  try{
    if(req.method==="GET"){
      const v=vapid();return res.status(200).json({ok:true,publicKey:b64url(v.pub)})
    }
    if(req.method!=="POST")return res.status(405).json({ok:false,error:"Método no permitido"});
    const body=req.body||{};
    if(body.action==="subscribe"){
      if(!authorized(req))return res.status(401).json({ok:false,error:"No autorizado"});
      return res.status(200).json(await subscribe(body.subscription))
    }
    if(body.action==="drain"){
      const out=await drain();return res.status(out.ok?200:503).json(out)
    }
    if(body.action==="test"){
      if(!authorized(req))return res.status(401).json({ok:false,error:"No autorizado"});
      const out=await testPush();return res.status(out.ok?200:503).json(out)
    }
    return res.status(400).json({ok:false,error:"Acción no válida"})
  }catch(e){console.error(e);return res.status(500).json({ok:false,error:String(e.message||e)})}
}
