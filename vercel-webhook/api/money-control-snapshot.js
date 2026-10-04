import crypto from "node:crypto";
import { Readable } from "node:stream";
import { get, put } from "@vercel/blob";

const PATHNAME="money-control/money-control.snapshot.json";
const MAX_BYTES=3*1024*1024;

function authToken(req){
  const h=String(req.headers.authorization||"");
  return h.startsWith("Bearer ")?h.slice(7).trim():"";
}
function tokenMatches(req){
  const expected=String(process.env.MONEYCONTROL_BRIDGE_TOKEN||"");
  const supplied=authToken(req);
  if(!expected||!supplied)return false;
  const a=Buffer.from(expected),b=Buffer.from(supplied);
  return a.length===b.length&&crypto.timingSafeEqual(a,b);
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
  const allowed=new Set(["format","version","kdf","iterations","salt","iv","data"]);
  if(Object.keys(x).some(k=>!allowed.has(k)))return false;
  return x.format==="money-control-snapshot"&&
    Number(x.version||1)===1&&
    x.kdf==="PBKDF2-SHA256"&&
    Number.isInteger(x.iterations)&&x.iterations>=200000&&
    typeof x.salt==="string"&&x.salt.length>=16&&
    typeof x.iv==="string"&&x.iv.length>=12&&
    typeof x.data==="string"&&x.data.length>=32;
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
    if(!process.env.BLOB_STORE_ID)return json(res,503,{ok:false,error:"blob_not_configured"});
    if(req.method==="GET"){
      const result=await get(PATHNAME,blobOptions({
        useCache:false,
        ifNoneMatch:req.headers["if-none-match"]||undefined
      }));
      if(!result)return json(res,404,{ok:false,error:"not_found"});
      res.setHeader("cache-control","private, no-store");
      res.setHeader("x-content-type-options","nosniff");
      res.setHeader("referrer-policy","no-referrer");
      if(result.blob?.etag)res.setHeader("etag",result.blob.etag);
      if(result.statusCode===304)return res.status(304).end();
      if(result.statusCode!==200)return json(res,404,{ok:false,error:"not_found"});
      res.status(200);
      res.setHeader("content-type","application/json; charset=utf-8");
      return Readable.fromWeb(result.stream).pipe(res);
    }
    if(req.method==="POST"){
      if(!tokenMatches(req))return json(res,401,{ok:false,error:"unauthorized"});
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
      if(!validEnvelope(envelope))return json(res,400,{ok:false,error:"invalid_snapshot"});
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
    console.error("money-control-snapshot",e);
    return json(res,500,{ok:false,error:"snapshot_storage_error"});
  }
}
