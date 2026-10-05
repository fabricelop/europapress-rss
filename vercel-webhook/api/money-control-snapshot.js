import crypto from "node:crypto";
import { Readable } from "node:stream";
import { get, head, issueSignedToken, list, presignUrl, put } from "@vercel/blob";

const SNAPSHOT_PATH="money-control/money-control.snapshot.json";
const PATCH_PATH="money-control/moneywiz-user-patch-v1.json";
const MAX_BYTES=3*1024*1024;
const MONEYWIZ_BACKUP_PREFIX="moneywiz-backups/";
const MONEYWIZ_BACKUP_MAX_BYTES=180*1024*1024;
const MONEYWIZ_PROCESSED_PREFIX="moneywiz-processed/";

function authToken(req){
  const h=String(req.headers.authorization||"");
  return h.startsWith("Bearer ")?h.slice(7).trim():"";
}
function tokenMatches(req){
  const supplied=authToken(req);
  if(!supplied)return false;
  for(const expected of [process.env.MONEYCONTROL_BRIDGE_TOKEN,process.env.MONEYWIZ_SYNC_TOKEN]){
    const value=String(expected||"");
    if(!value)continue;
    const a=Buffer.from(value),b=Buffer.from(supplied);
    if(a.length===b.length&&crypto.timingSafeEqual(a,b))return true;
  }
  return false;
}
function moneyWizUploadTokenMatches(req){
  const supplied=authToken(req),expected=String(process.env.MONEYWIZ_UPLOAD_TOKEN||"");
  if(!supplied||!expected)return false;
  const a=Buffer.from(expected),b=Buffer.from(supplied);
  return a.length===b.length&&crypto.timingSafeEqual(a,b);
}
function privateBlobOptions(extra={}){
  return {access:"private",token:process.env.BLOB_READ_WRITE_TOKEN||undefined,...extra};
}
function cleanMoneyWizFilename(v){
  const name=String(v||"").trim().replace(/\\/g,"/").split("/").pop()||"";
  if(!/^i?MoneyWiz[-_].*\.zip$/i.test(name))return "";
  if(name.length>180)return "";
  return name.replace(/[^A-Za-z0-9._-]/g,"_");
}
function requestParams(req){
  try{return new URL(req.url||"/","http://localhost").searchParams}catch{return new URLSearchParams()}
}

async function signedPrivateUrl(pathname,operation,validUntil){
  const signed=await issueSignedToken({
    pathname,
    operations:[operation],
    validUntil,
    token:process.env.BLOB_READ_WRITE_TOKEN
  });
  const opts={operation,pathname,access:"private",validUntil};
  if(operation==="get")opts.useCache=false;
  if(operation==="put"){
    opts.allowedContentTypes=["application/json"];
    opts.maximumSizeInBytes=3*1024*1024;
    opts.addRandomSuffix=false;
    opts.allowOverwrite=true;
    opts.cacheControlMaxAge=60;
  }
  return (await presignUrl(signed,opts)).presignedUrl;
}
async function dispatchMoneyWizProcessing({current,previous}){
  const githubToken=String(process.env.GITHUB_TOKEN||"");
  let repo=String(process.env.GITHUB_REPO||"fabricelop/europapress-rss").replace(/^https?:\/\/github\.com\//,"").replace(/\.git$/,"");
  if(!repo.includes("/"))repo="fabricelop/"+repo;
  repo=repo.split("/").filter(Boolean).slice(-2).join("/");
  if(!githubToken||!repo.includes("/"))throw new Error("github_dispatch_not_configured");
  const validUntil=Date.now()+40*60*1000;
  const currentUrl=await signedPrivateUrl(current.pathname,"get",validUntil);
  const previousUrl=await signedPrivateUrl(previous.pathname,"get",validUntil);
  const stem=String(current.filename||"moneywiz").replace(/\.zip$/i,"").replace(/[^A-Za-z0-9._-]/g,"_");
  const processedPath=MONEYWIZ_PROCESSED_PREFIX+stem+".json";
  const processedPutUrl=await signedPrivateUrl(processedPath,"put",validUntil);
  const response=await fetch("https://api.github.com/repos/"+repo+"/dispatches",{
    method:"POST",
    headers:{
      "authorization":"Bearer "+githubToken,
      "accept":"application/vnd.github+json",
      "x-github-api-version":"2022-11-28",
      "content-type":"application/json",
      "user-agent":"money-control-moneywiz"
    },
    body:JSON.stringify({
      event_type:"moneywiz_backup_uploaded",
      client_payload:{
        current_url:currentUrl,
        previous_url:previousUrl,
        current_filename:current.filename,
        previous_filename:previous.filename,
        processed_put_url:processedPutUrl,
        processed_path:processedPath
      }
    })
  });
  if(response.status!==204)throw new Error("github_dispatch_"+response.status);
  return {processedPath};
}

function blobOptions(extra={}){
  return {
    access:"public",
    storeId:process.env.BLOB_STORE_ID||undefined,
    oidcToken:process.env.VERCEL_OIDC_TOKEN||undefined,
    ...extra
  };
}
function snapshotEnvelope(x){
  if(!x||typeof x!=="object"||Array.isArray(x))return false;
  const allowed=new Set(["format","version","kdf","iterations","salt","iv","data"]);
  if(Object.keys(x).some(k=>!allowed.has(k)))return false;
  return x.format==="money-control-snapshot"&&
    Number(x.version||1)===1&&x.kdf==="PBKDF2-SHA256"&&
    Number.isInteger(x.iterations)&&x.iterations>=200000&&
    typeof x.salt==="string"&&x.salt.length>=16&&
    typeof x.iv==="string"&&x.iv.length>=12&&
    typeof x.data==="string"&&x.data.length>=32;
}
function patchEnvelope(x){
  if(!x||typeof x!=="object"||Array.isArray(x))return false;
  const allowed=new Set(["format","version","kdf","iterations","salt","iv","data","sourceImportedAt","snapshotDate"]);
  if(Object.keys(x).some(k=>!allowed.has(k)))return false;
  return x.format==="moneywiz-user-patch"&&
    Number(x.version||1)===1&&x.kdf==="PBKDF2-SHA256"&&
    Number.isInteger(x.iterations)&&x.iterations>=200000&&
    typeof x.salt==="string"&&x.salt.length>=16&&
    typeof x.iv==="string"&&x.iv.length>=12&&
    typeof x.data==="string"&&x.data.length>=32&&
    /^\d{4}-\d{2}-\d{2}$/.test(String(x.snapshotDate||""))&&
    typeof x.sourceImportedAt==="string"&&x.sourceImportedAt.length>=10;
}
function json(res,status,payload){
  res.status(status);
  res.setHeader("content-type","application/json; charset=utf-8");
  res.setHeader("cache-control","no-store");
  return res.end(JSON.stringify(payload));
}
function kindOf(req){
  try{return new URL(req.url||"/","http://localhost").searchParams.get("kind")==="moneywiz-patch"?"patch":"snapshot"}catch{return"snapshot"}
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
    const params=requestParams(req);
    if(params.get("kind")==="moneywiz-processed"){
      if(!tokenMatches(req))return json(res,401,{ok:false,error:"unauthorized"});
      if(req.method!=="GET"){
        res.setHeader("allow","GET");
        return json(res,405,{ok:false,error:"method_not_allowed"});
      }
      if(!process.env.BLOB_READ_WRITE_TOKEN)return json(res,503,{ok:false,error:"backup_blob_not_configured"});
      const listed=await list(privateBlobOptions({prefix:MONEYWIZ_PROCESSED_PREFIX,limit:100}));
      const latest=(listed.blobs||[])
        .filter(b=>String(b.pathname||"").toLowerCase().endsWith(".json"))
        .sort((a,b)=>String(b.uploadedAt||"").localeCompare(String(a.uploadedAt||"")))[0];
      if(!latest)return json(res,404,{ok:false,error:"not_found"});
      const result=await get(latest.pathname,privateBlobOptions({useCache:false}));
      if(!result||result.statusCode!==200)return json(res,404,{ok:false,error:"not_found"});
      res.status(200);
      res.setHeader("content-type","application/json; charset=utf-8");
      res.setHeader("cache-control","private, no-store");
      res.setHeader("x-content-type-options","nosniff");
      return Readable.fromWeb(result.stream).pipe(res);
    }

    if(params.get("kind")==="moneywiz-backup"){
      if(!moneyWizUploadTokenMatches(req))return json(res,401,{ok:false,error:"unauthorized"});
      if(!process.env.BLOB_READ_WRITE_TOKEN)return json(res,503,{ok:false,error:"backup_blob_not_configured"});

      if(req.method==="GET"){
        const result=await list(privateBlobOptions({prefix:MONEYWIZ_BACKUP_PREFIX,limit:100}));
        const backups=(result.blobs||[])
          .filter(b=>String(b.pathname||"").toLowerCase().endsWith(".zip"))
          .map(b=>({
            pathname:b.pathname,
            filename:String(b.pathname||"").slice(MONEYWIZ_BACKUP_PREFIX.length),
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

      let body={};
      try{body=JSON.parse(await bodyText(req)||"{}")}catch{return json(res,400,{ok:false,error:"invalid_json"})}
      const action=String(body.action||"prepare");

      if(action==="prepare"){
        const filename=cleanMoneyWizFilename(body.filename),sizeBytes=Number(body.sizeBytes||0);
        if(!filename)return json(res,400,{ok:false,error:"invalid_filename"});
        if(!Number.isFinite(sizeBytes)||sizeBytes<=0||sizeBytes>MONEYWIZ_BACKUP_MAX_BYTES)return json(res,413,{ok:false,error:"invalid_size"});
        const pathname=MONEYWIZ_BACKUP_PREFIX+filename;
        try{
          const existing=await head(pathname,privateBlobOptions());
          if(existing&&Number(existing.size||0)===sizeBytes){
            return json(res,200,{ok:true,alreadyExists:true,pathname,size:Number(existing.size||0),uploadedAt:existing.uploadedAt||null});
          }
        }catch(_){}

        const validUntil=Date.now()+20*60*1000;
        const signed=await issueSignedToken({
          pathname,
          operations:["put"],
          validUntil,
          allowedContentTypes:["application/zip","application/x-zip-compressed","application/octet-stream"],
          maximumSizeInBytes:MONEYWIZ_BACKUP_MAX_BYTES,
          token:process.env.BLOB_READ_WRITE_TOKEN
        });
        const {presignedUrl}=await presignUrl(signed,{
          operation:"put",
          pathname,
          access:"private",
          validUntil,
          allowedContentTypes:["application/zip","application/x-zip-compressed","application/octet-stream"],
          maximumSizeInBytes:MONEYWIZ_BACKUP_MAX_BYTES,
          addRandomSuffix:false,
          allowOverwrite:false,
          cacheControlMaxAge:60
        });
        return json(res,200,{ok:true,alreadyExists:false,pathname,presignedUrl,expiresAt:new Date(validUntil).toISOString()});
      }

      if(action==="confirm"){
        const pathname=String(body.pathname||"");
        if(!pathname.startsWith(MONEYWIZ_BACKUP_PREFIX)||!pathname.toLowerCase().endsWith(".zip"))return json(res,400,{ok:false,error:"invalid_pathname"});
        let meta;
        try{meta=await head(pathname,privateBlobOptions())}catch(_){return json(res,404,{ok:false,error:"not_found"})}
        const listed=await list(privateBlobOptions({prefix:MONEYWIZ_BACKUP_PREFIX,limit:100}));
        const backups=(listed.blobs||[])
          .filter(b=>String(b.pathname||"").toLowerCase().endsWith(".zip"))
          .map(b=>({
            pathname:b.pathname,
            filename:String(b.pathname||"").slice(MONEYWIZ_BACKUP_PREFIX.length),
            size:Number(b.size||0),
            uploadedAt:b.uploadedAt||null
          }))
          .sort((a,b)=>String(a.uploadedAt||"").localeCompare(String(b.uploadedAt||"")));
        const idx=backups.findIndex(b=>b.pathname===pathname);
        const current=idx>=0?backups[idx]:{pathname,filename:pathname.slice(MONEYWIZ_BACKUP_PREFIX.length),size:Number(meta.size||0),uploadedAt:meta.uploadedAt||null};
        const previous=idx>0?backups[0]:null;
        if(!previous){
          return json(res,200,{ok:true,pathname,size:Number(meta.size||0),uploadedAt:meta.uploadedAt||null,seedOnly:true,processingQueued:false});
        }
        try{
          const queued=await dispatchMoneyWizProcessing({current,previous});
          return json(res,200,{ok:true,pathname,size:Number(meta.size||0),uploadedAt:meta.uploadedAt||null,seedOnly:false,processingQueued:true,...queued});
        }catch(error){
          console.error("moneywiz-dispatch",error);
          return json(res,502,{ok:false,error:"processing_dispatch_failed",pathname});
        }
      }

      return json(res,400,{ok:false,error:"unknown_action"});
    }

    if(!process.env.BLOB_STORE_ID)return json(res,503,{ok:false,error:"blob_not_configured"});
    const kind=kindOf(req),pathname=kind==="patch"?PATCH_PATH:SNAPSHOT_PATH;
    if(req.method==="GET"){
      const result=await get(pathname,blobOptions({
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
      if(kind==="patch"?!patchEnvelope(envelope):!snapshotEnvelope(envelope))return json(res,400,{ok:false,error:kind==="patch"?"invalid_patch":"invalid_snapshot"});
      const blob=await put(pathname,JSON.stringify(envelope),blobOptions({
        allowOverwrite:true,
        addRandomSuffix:false,
        cacheControlMaxAge:60,
        contentType:"application/json"
      }));
      console.log("money-control-storage-write",kind,pathname,Buffer.byteLength(raw,"utf8"));
      return json(res,200,{ok:true,kind,pathname:blob.pathname,etag:blob.etag||null});
    }
    res.setHeader("allow","GET, POST");
    return json(res,405,{ok:false,error:"method_not_allowed"});
  }catch(e){
    console.error("money-control-snapshot",e);
    return json(res,500,{ok:false,error:"snapshot_storage_error"});
  }
}
