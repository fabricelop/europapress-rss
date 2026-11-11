// Optional, narrowly scoped Cloudflare resource initialization for TT Fotos.
// INSPECT is the default. Explicit --create-missing is required for any POST.
// Existing resources are NEVER patched, renamed, emptied, or deleted.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {checkPrivateR2Responses} from './verify-private-r2.mjs';

export const D1_NAME='tt-fotos-private';
export const R2_NAME='tt-fotos-originals-private';
const UUID=/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const ACCOUNT=/^[a-f0-9]{32}$/i;

export function inspectIdentity(databases,r2,expectedId=''){
 if(!Array.isArray(databases))throw Error('D1_LIST_INVALID');
 const d1Matches=databases.filter(d=>d?.name===D1_NAME);
 if(d1Matches.length>1)throw Error('D1_NAME_NOT_UNIQUE');
 const d1=d1Matches[0]||null;
 if(d1&&(!UUID.test(d1.uuid)||expectedId&&d1.uuid.toLowerCase()!==expectedId.toLowerCase()))
  throw Error('D1_IDENTITY_MISMATCH');
 if(r2!==null&&r2?.name!==R2_NAME)throw Error('R2_IDENTITY_MISMATCH');
 return {d1Id:d1?.uuid||null,hasR2:Boolean(r2)};
}
async function requestCloudflare(method,accountPath,env,fetcher,body){
 const resp=await fetcher('https://api.cloudflare.com/client/v4/accounts/'+env.CLOUDFLARE_ACCOUNT_ID+accountPath,{
  method,
  redirect:'error',
  headers:{'Authorization':'Bearer '+env.CLOUDFLARE_API_TOKEN,'Accept':'application/json',...(body?{'Content-Type':'application/json'}:{})},
  ...(body?{body:JSON.stringify(body)}:{}),
  signal:AbortSignal.timeout(12000)
 });
 if(method==='GET'&&resp.status===404)return null;
 if(!resp.ok)throw Error('CLOUDFLARE_'+method+'_HTTP_'+resp.status);
 let data;
 try{data=await resp.json()}catch{throw Error('CLOUDFLARE_INVALID_JSON')}
 if(data?.success!==true||data.result==null)throw Error('CLOUDFLARE_UNEXPECTED_RESPONSE');
 return data.result;
}
export async function preparePrivateResources({env=process.env,fetcher=fetch,createMissing=false}={}){
 if(!ACCOUNT.test(String(env.CLOUDFLARE_ACCOUNT_ID||''))||!env.CLOUDFLARE_API_TOKEN)
  throw Error('CLOUDFLARE_ACCOUNT_AND_TOKEN_REQUIRED');
 const expected=String(env.TT_FOTOS_D1_DATABASE_ID||'');
 if(expected&&!UUID.test(expected))throw Error('EXPECTED_D1_UUID_INVALID');
 const ask=(method,path,body)=>requestCloudflare(method,path,env,fetcher,body);
 // Both remote identities are inventoried BEFORE any operation which may write.
 const [list,bucket]=await Promise.all([
  ask('GET','/d1/database?name='+encodeURIComponent(D1_NAME)+'&per_page=100'),
  ask('GET','/r2/buckets/'+R2_NAME)
 ]);
 const discovered=inspectIdentity(list,bucket,expected);
 const created=[];
 // Refuse public exposure on an already present bucket rather than silently
 // changing its settings, or creating a D1 alongside an exposed bucket.
 async function checkBucketPrivate(){
  const prefix='/r2/buckets/'+R2_NAME+'/domains/';
  const [managed,custom]=await Promise.all([
    ask('GET',prefix+'managed'),ask('GET',prefix+'custom')
  ]);
  checkPrivateR2Responses(managed,custom);
 }
 if(discovered.hasR2)await checkBucketPrivate();
 if(!createMissing)return {ready:Boolean(discovered.d1Id&&discovered.hasR2),
  d1Id:discovered.d1Id,hasR2:discovered.hasR2,created,
  missing:[...(!discovered.d1Id?[D1_NAME]:[]),...(!discovered.hasR2?[R2_NAME]:[])]};
 let d1Id=discovered.d1Id,hasR2=discovered.hasR2;
 if(!d1Id){
  // A configured UUID that does not exist is a mismatch, not authorization
  // to create a different database and silently replace its binding.
  if(expected)throw Error('EXPECTED_D1_NOT_PRESENT');
  const db=await ask('POST','/d1/database',{name:D1_NAME});
  if(db?.name!==D1_NAME||!UUID.test(db.uuid))throw Error('D1_CREATION_UNVERIFIED');
  d1Id=db.uuid;
  created.push(D1_NAME);
 }
 if(!hasR2){
  const createdBucket=await ask('POST','/r2/buckets',{name:R2_NAME});
  if(createdBucket?.name!==R2_NAME)throw Error('R2_CREATION_UNVERIFIED');
  hasR2=true;
  created.push(R2_NAME);
  await checkBucketPrivate();
 }
 return {ready:true,d1Id,hasR2,created,missing:[]};
}
export function safePreparationReport(report){
 return [
  '# TT Fotos — recursos Cloudflare independientes',
  'Estado: '+(report.ready?'LISTOS':'INCOMPLETOS'),
  'Base D1: '+(report.d1Id?'IDENTIFICADA':'FALTA'),
  'Bucket R2: '+(report.hasR2?'IDENTIFICADO Y PRIVADO':'FALTA'),
  'Creados en esta ejecución: '+(report.created.length?report.created.join(', '):'ninguno'),
  'Otros Workers, buckets y bases de datos: no modificados',
  'Access y carga de imágenes: requieren comprobaciones posteriores'
 ].join('\n')+'\n';
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
 const requested=process.argv.slice(2);
 const create=requested.length===1&&requested[0]==='--create-missing';
 if(requested.length&&(!create)){
  console.error('TT_FOTOS_PREPARE_USAGE: optional --create-missing');
  process.exitCode=2;
 }else{
  try{
   const result=await preparePrivateResources({createMissing:create});
   const summary=safePreparationReport(result);
   console.log(summary);
   if(process.env.GITHUB_STEP_SUMMARY)
    fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY,summary+'\n');
   if(result.d1Id&&process.env.GITHUB_ENV)
    fs.appendFileSync(process.env.GITHUB_ENV,'TT_FOTOS_D1_DATABASE_ID='+result.d1Id+'\n');
   if(!result.ready)process.exitCode=1;
  }catch(e){
   console.error('TT_FOTOS_PREPARE_BLOCKED '+String(e.message||e));
   process.exitCode=1;
  }
 }
}
