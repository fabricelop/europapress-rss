// TT Fotos Cloudflare readiness audit. GET requests only; no secrets in output.
// This is an inventory, NOT deployment authorization.
import {checkPrivateR2Responses} from './verify-private-r2.mjs';

const ACCOUNT=/^[a-f0-9]{32}$/i;
const UUID=/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const AUD=/^[a-f0-9]{64}$/i;
const WORKER='tt-fotos-independent';
const D1='tt-fotos-private';
const R2='tt-fotos-originals-private';
const ROOT='https://api.cloudflare.com/client/v4';

export function settingsCheck(env){
 const issues=[];
 const required=['CLOUDFLARE_API_TOKEN','CLOUDFLARE_ACCOUNT_ID','TT_FOTOS_D1_DATABASE_ID','TT_FOTOS_ACCESS_ISSUER','TT_FOTOS_ACCESS_AUD','TT_FOTOS_ALLOWED_EMAIL'];
 for(const k of required)if(!String(env[k]||'').trim())issues.push('MISSING_'+k);
 if(env.CLOUDFLARE_ACCOUNT_ID&&!ACCOUNT.test(env.CLOUDFLARE_ACCOUNT_ID))issues.push('INVALID_ACCOUNT_ID');
 if(env.TT_FOTOS_D1_DATABASE_ID&&!UUID.test(env.TT_FOTOS_D1_DATABASE_ID))issues.push('INVALID_D1_ID');
 if(env.TT_FOTOS_ACCESS_AUD&&!AUD.test(env.TT_FOTOS_ACCESS_AUD))issues.push('INVALID_ACCESS_AUD');
 if(env.TT_FOTOS_ACCESS_ISSUER){
  try{
   const u=new URL(env.TT_FOTOS_ACCESS_ISSUER);
   if(u.protocol!=='https:'||!u.hostname.endsWith('.cloudflareaccess.com')||u.pathname!=='/'||u.search||u.hash)issues.push('INVALID_ACCESS_ISSUER');
  }catch{issues.push('INVALID_ACCESS_ISSUER')}
 }
 if(env.TT_FOTOS_ALLOWED_EMAIL){
  const emails=String(env.TT_FOTOS_ALLOWED_EMAIL).split(',').map(x=>x.trim());
  if(emails.some(x=>!/^[^\s@,]+@[^\s@,.]+(?:\.[^\s@,.]+)+$/.test(x)))
   issues.push('INVALID_EDITOR_EMAIL_ALLOWLIST');
 }
 return issues;
}
export function verifyInventory(d1,r2,managed,custom){
 if(d1?.name!==D1)throw Error('DEDICATED_D1_MISSING_OR_DIFFERENT');
 if(r2?.name!==R2)throw Error('DEDICATED_R2_MISSING_OR_DIFFERENT');
 checkPrivateR2Responses(managed,custom);
 return true;
}
export function findAccessApplication(apps,aud,workerId){
 if(!Array.isArray(apps))throw Error('ACCESS_LIST_UNAVAILABLE');
 const exact=apps.filter(a=>a?.aud===aud&&a?.type==='self_hosted');
 if(exact.length!==1)throw Error('DEDICATED_ACCESS_APP_NOT_FOUND_OR_AMBIGUOUS');
 const a=exact[0];
 // Destinations are checked as well as AUD. Never accept an account-wide
 // Access app as proof that this standalone Worker is protected.
 const ds=Array.isArray(a.destinations)?a.destinations:[];
 const valid=ds.some(d=>d?.type==='worker'&&d.worker_id===workerId);
 if(!valid)throw Error('WORKER_LEVEL_ACCESS_NOT_CONFIGURED');
 return {id:a.id||null,aud:a.aud,workerIds:ds.filter(d=>d.type==='worker').map(d=>d.worker_id)};
}
async function apiGet(path,env,fetcher=fetch){
 const r=await fetcher(ROOT+path,{
  method:'GET',redirect:'error',headers:{Authorization:'Bearer '+env.CLOUDFLARE_API_TOKEN,Accept:'application/json'},
  signal:AbortSignal.timeout(12000)
 });
 if(!r.ok)throw Error('CLOUDFLARE_READ_FAILED_HTTP_'+r.status);
 const body=await r.json();
 if(body?.success!==true||body.result==null)throw Error('CLOUDFLARE_API_ERROR_OR_UNEXPECTED_RESULT');
 return body.result;
}
export async function auditCloudflare(env=process.env,fetcher=fetch){
 const failures=settingsCheck(env);
 if(failures.length)return {ready:false,checks:[],blockers:failures};
 const base='/accounts/'+env.CLOUDFLARE_ACCOUNT_ID;
 const checks=[],blockers=[];
 const probe=async(label,path,validate)=>{
  try{
   const result=await apiGet(path,env,fetcher);
   if(validate)validate(result);
   checks.push(label+':PASS');
   return result;
  }catch(e){
   checks.push(label+':BLOCKED');
   blockers.push(label+':'+String(e.message||e).replace(/[^A-Z0-9_]/gi,'_').slice(0,96));
   return null;
  }
 };
 const d1=await probe('D1',base+'/d1/database/'+env.TT_FOTOS_D1_DATABASE_ID,
   r=>{if(r.name!==D1||String(r.uuid||'').toLowerCase()!==env.TT_FOTOS_D1_DATABASE_ID.toLowerCase())throw Error('WRONG_D1')});
 const r2=await probe('R2',base+'/r2/buckets/'+R2,
   r=>{if(r.name!==R2)throw Error('WRONG_R2')});
 if(r2){
  const prefix=base+'/r2/buckets/'+R2+'/domains/';
  const managed=await probe('R2_DEV_PRIVATE',prefix+'managed',
    r=>{if(r.enabled!==false)throw Error('PUBLIC_R2_DEV_DOMAIN')});
  const custom=await probe('R2_CUSTOM_PRIVATE',prefix+'custom',
    r=>{if(!Array.isArray(r.domains)||r.domains.some(d=>d.enabled!==false))throw Error('PUBLIC_OR_UNKNOWN_CUSTOM_DOMAIN')});
  if(d1&&managed&&custom)verifyInventory(d1,r2,managed,custom);
 }
 const worker=await probe('STANDALONE_WORKER',base+'/workers/workers/'+WORKER,
   r=>{if(r.name!==WORKER||!r.id)throw Error('NOT_THE_STANDALONE_WORKER')});
 const apps=await probe('ACCESS_AUDIENCE',base+'/access/apps?aud='+encodeURIComponent(env.TT_FOTOS_ACCESS_AUD)+'&per_page=100',
   r=>findAccessApplication(r,env.TT_FOTOS_ACCESS_AUD,worker?.id));
 // Even a correctly scoped Access app needs policy and live authentication verification.
 if(apps){checks.push('ACCESS_POLICY_AND_LOGIN:REQUIRES_LIVE_VERIFICATION')}
 return {ready:blockers.length===0,checks,blockers};
}
export function safeReport(report){
 return ['## TT Fotos Cloudflare — verificación de solo lectura','',
  'Preparado para despliegue: **'+(report.ready?'SÍ, comprobaciones preliminares':'NO, faltan requisitos')+'**','',
  ...report.checks.map(s=>'- '+s),
  ...report.blockers.map(s=>'- Pendiente: '+s),
  '',
  'Sin desplegar ni modificar Cloudflare. Verificar Access efectivo y conexión ChatGPT Imágenes por separado.',''].join('\n');
}
if(process.argv[1]){
 const {fileURLToPath}=await import('node:url');
 const path=await import('node:path');
 if(path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  let report;
  try{report=await auditCloudflare()}catch(e){report={ready:false,checks:[],blockers:['UNEXPECTED_PREFLIGHT_FAILURE']}}
  const output=safeReport(report);
  console.log(output);
  if(process.env.GITHUB_STEP_SUMMARY){
   const fs=await import('node:fs');
   fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY,output+'\n');
  }
  if(!report.ready)process.exitCode=1;
 }
}
