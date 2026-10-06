import crypto from "node:crypto";
import { Readable } from "node:stream";
import { get, put } from "@vercel/blob";

const PATHNAME="money-control/money-control.state.json";
const MAX_BYTES=768*1024;

function authToken(req){
  const h=String(req.headers.authorization||"");
  return h.startsWith("Bearer ")?h.slice(7).trim():"";
}
function tokenMatches(req){
  const supplied=authToken(req);
  if(!supplied)return false;
  const candidates=[process.env.MONEYCONTROL_STATE_TOKEN,process.env.MONEYWIZ_SYNC_TOKEN].map(x=>String(x||"")).filter(Boolean);
  const b=Buffer.from(supplied);
  return candidates.some(expected=>{const a=Buffer.from(expected);return a.length===b.length&&crypto.timingSafeEqual(a,b)});
}
function blobOptions(extra={}){
  return {
    access:"private",
    storeId:process.env.BLOB_STORE_ID||undefined,
    oidcToken:process.env.VERCEL_OIDC_TOKEN||undefined,
    ...extra
  };
}
function validEnvelope(x){
  if(!x||typeof x!=="object"||Array.isArray(x))return false;
  const allowed=new Set(["format","version","kdf","iterations","updatedAt","iv","data","salt","device"]);
  if(Object.keys(x).some(k=>!allowed.has(k)))return false;
  return x.format==="money-control-state"&&
    Number(x.version||1)===1&&
    x.kdf==="PBKDF2-SHA256"&&
    Number.isInteger(x.iterations)&&x.iterations>=200000&&
    typeof x.updatedAt==="string"&&
    typeof x.iv==="string"&&x.iv.length>=12&&
    typeof x.data==="string"&&x.data.length>=16;
}
function json(res,status,payload){
  res.status(status);
  res.setHeader("content-type","application/json; charset=utf-8");
  res.setHeader("cache-control","no-store");
  return res.end(JSON.stringify(payload));
}
async function bodyText(req){
  if(typeof req.body==="string")return req.body;
  if(Buffer.isBuffer(req.body))return req.body.toString("utf8");
  if(req.body&&typeof req.body==="object")return JSON.stringify(req.body);
  const chunks=[];let total=0;
  for await(const chunk of req){
    total+=chunk.length;
    if(total>MAX_BYTES)throw Object.assign(new Error("too_large"),{code:"too_large"});
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
}

export default async function handler(req,res){
  try{
    if(!tokenMatches(req))return json(res,401,{ok:false,error:"unauthorized"});
    if(!process.env.BLOB_STORE_ID)return json(res,503,{ok:false,error:"blob_not_configured"});
    if(req.method==="GET"){
      const result=await get(PATHNAME,blobOptions({useCache:false}));
      if(!result)return json(res,404,{ok:false,error:"not_found"});
      if(result.statusCode!==200)return json(res,404,{ok:false,error:"not_found"});
      res.status(200);
      res.setHeader("content-type","application/json; charset=utf-8");
      res.setHeader("cache-control","private, no-store");
      res.setHeader("x-content-type-options","nosniff");
      return Readable.fromWeb(result.stream).pipe(res);
    }
    if(req.method==="POST"){
      const len=Number(req.headers["content-length"]||0);
      if(len>MAX_BYTES)return json(res,413,{ok:false,error:"too_large"});
      let raw;
      try{raw=await bodyText(req)}catch(e){
        if(e?.code==="too_large")return json(res,413,{ok:false,error:"too_large"});
        throw e;
      }
      if(Buffer.byteLength(raw,"utf8")>MAX_BYTES)return json(res,413,{ok:false,error:"too_large"});
      let envelope;
      try{envelope=JSON.parse(raw)}catch{return json(res,400,{ok:false,error:"invalid_json"})}
      if(!validEnvelope(envelope))return json(res,400,{ok:false,error:"invalid_state"});
      const blob=await put(PATHNAME,JSON.stringify(envelope),blobOptions({
        allowOverwrite:true,
        addRandomSuffix:false,
        cacheControlMaxAge:60,
        contentType:"application/json"
      }));
      return json(res,200,{ok:true,pathname:blob.pathname,etag:blob.etag||null});
    }
    res.setHeader("allow","GET, POST");
    return json(res,405,{ok:false,error:"method_not_allowed"});
  }catch(e){
    console.error("money-control-state",e);
    return json(res,500,{ok:false,error:"state_storage_error"});
  }
}
