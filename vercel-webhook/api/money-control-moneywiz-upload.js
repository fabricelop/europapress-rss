import crypto from "node:crypto";
import { head, issueSignedToken, list, presignUrl } from "@vercel/blob";

const PREFIX="money-control/moneywiz-backups/";
const MAX_BYTES=160*1024*1024;
const MAX_ITEMS=50;

function json(res,status,payload){
  res.status(status);
  res.setHeader("content-type","application/json; charset=utf-8");
  res.setHeader("cache-control","no-store");
  res.setHeader("x-content-type-options","nosniff");
  return res.end(JSON.stringify(payload));
}
function authToken(req){
  const h=String(req.headers.authorization||"");
  return h.startsWith("Bearer ")?h.slice(7).trim():"";
}
function tokenMatches(req){
  const expected=String(process.env.MONEYWIZ_UPLOAD_TOKEN||"");
  const supplied=authToken(req);
  if(!expected||!supplied)return false;
  const a=Buffer.from(expected),b=Buffer.from(supplied);
  return a.length===b.length&&crypto.timingSafeEqual(a,b);
}
function blobOptions(extra={}){
  return {
    storeId:process.env.BLOB_STORE_ID||undefined,
    oidcToken:process.env.VERCEL_OIDC_TOKEN||undefined,
    ...extra
  };
}
function cleanFilename(v){
  const name=String(v||"").trim().replace(/\\/g,"/").split("/").pop()||"";
  if(!/^i?MoneyWiz[-_].*\.zip$/i.test(name))return "";
  if(name.length>180)return "";
  return name.replace(/[^A-Za-z0-9._-]/g,"_");
}
async function parseBody(req){
  if(req.body&&typeof req.body==="object")return req.body;
  if(typeof req.body==="string")return JSON.parse(req.body);
  const chunks=[];
  for await(const chunk of req)chunks.push(chunk);
  const raw=Buffer.concat(chunks).toString("utf8");
  return raw?JSON.parse(raw):{};
}

export default async function handler(req,res){
  try{
    if(!tokenMatches(req))return json(res,401,{ok:false,error:"unauthorized"});
    if(!process.env.BLOB_STORE_ID)return json(res,503,{ok:false,error:"blob_not_configured"});

    if(req.method==="GET"){
      const result=await list(blobOptions({prefix:PREFIX,limit:MAX_ITEMS}));
      const backups=(result.blobs||[])
        .filter(b=>String(b.pathname||"").toLowerCase().endsWith(".zip"))
        .map(b=>({
          pathname:b.pathname,
          filename:String(b.pathname||"").slice(PREFIX.length),
          size:Number(b.size||0),
          uploadedAt:b.uploadedAt||null,
          etag:b.etag||null
        }))
        .sort((a,b)=>String(b.uploadedAt||"").localeCompare(String(a.uploadedAt||"")));
      return json(res,200,{ok:true,count:backups.length,backups,hasMore:!!result.hasMore});
    }

    if(req.method!=="POST"){
      res.setHeader("allow","GET, POST");
      return json(res,405,{ok:false,error:"method_not_allowed"});
    }

    const body=await parseBody(req);
    const action=String(body.action||"prepare");

    if(action==="prepare"){
      const filename=cleanFilename(body.filename);
      const sizeBytes=Number(body.sizeBytes||0);
      if(!filename)return json(res,400,{ok:false,error:"invalid_filename"});
      if(!Number.isFinite(sizeBytes)||sizeBytes<=0||sizeBytes>MAX_BYTES)return json(res,413,{ok:false,error:"invalid_size"});
      const pathname=PREFIX+filename;
      try{
        const existing=await head(pathname,blobOptions());
        if(existing&&Number(existing.size||0)===sizeBytes){
          return json(res,200,{ok:true,alreadyExists:true,pathname,size:Number(existing.size||0),uploadedAt:existing.uploadedAt||null});
        }
      }catch(_){}

      const validUntil=Date.now()+15*60*1000;
      const signed=await issueSignedToken(blobOptions({
        pathname,
        operations:["put"],
        validUntil,
        allowedContentTypes:["application/zip","application/x-zip-compressed","application/octet-stream"],
        maximumSizeInBytes:MAX_BYTES
      }));
      const {presignedUrl}=await presignUrl(signed,{
        operation:"put",
        pathname,
        access:"private",
        validUntil,
        allowedContentTypes:["application/zip","application/x-zip-compressed","application/octet-stream"],
        maximumSizeInBytes:MAX_BYTES,
        addRandomSuffix:false,
        allowOverwrite:false,
        cacheControlMaxAge:60
      });
      return json(res,200,{ok:true,alreadyExists:false,pathname,presignedUrl,expiresAt:new Date(validUntil).toISOString()});
    }

    if(action==="confirm"){
      const pathname=String(body.pathname||"");
      if(!pathname.startsWith(PREFIX)||!pathname.toLowerCase().endsWith(".zip"))return json(res,400,{ok:false,error:"invalid_pathname"});
      try{
        const meta=await head(pathname,blobOptions());
        return json(res,200,{ok:true,pathname,size:Number(meta.size||0),uploadedAt:meta.uploadedAt||null,etag:meta.etag||null});
      }catch(_){
        return json(res,404,{ok:false,error:"not_found"});
      }
    }

    return json(res,400,{ok:false,error:"unknown_action"});
  }catch(error){
    console.error("money-control-moneywiz-upload",error);
    return json(res,500,{ok:false,error:"upload_setup_error",detail:String(error?.message||error).slice(0,200)});
  }
}
