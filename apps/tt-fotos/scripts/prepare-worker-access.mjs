// Exact, opt-in Cloudflare Access initialization for the standalone TT Fotos Worker.
// Inspect by default. Never alter existing apps or policies; never touch other Workers.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const WORKER_NAME='tt-fotos-independent';
const ACCOUNT=/^[a-f0-9]{32}$/i;
const AUD=/^[a-f0-9]{64}$/i;
const MAIL=/^[^\s@,]+@[^\s@,.]+(?:\.[^\s@,.]+)+$/;

export function editorEmails(raw){
 const emails=String(raw||'').split(',').map(x=>x.trim().toLowerCase());
 if(!emails.length||emails.some(x=>!MAIL.test(x))||new Set(emails).size!==emails.length)
  throw Error('TT_FOTOS_EDITOR_ALLOWLIST_INVALID');
 return emails;
}
export function chooseWorker(workers){
 if(!Array.isArray(workers))throw Error('CLOUDFLARE_WORKER_LIST_INVALID');
 const exact=workers.filter(x=>x?.name===WORKER_NAME&&typeof x.id==='string'&&x.id.length>0);
 if(exact.length!==1)throw Error('TT_FOTOS_WORKER_NOT_FOUND_OR_AMBIGUOUS');
 return exact[0];
}
export function chooseAccessApp(apps,workerId,expectedAud=''){
 if(!Array.isArray(apps))throw Error('ACCESS_APPLICATION_LIST_INVALID');
 const candidates=apps.filter(a=>a?.destinations?.some(d=>d?.type==='worker'&&d.worker_id===workerId));
 if(candidates.length>1)throw Error('MULTIPLE_ACCESS_APPS_FOR_TT_FOTOS');
 const a=candidates[0]||null;
 if(a){
  if(a.type!=='self_hosted'||!AUD.test(String(a.aud||''))||
    expectedAud&&a.aud!==expectedAud||!a.id)
   throw Error('TT_FOTOS_ACCESS_IDENTITY_MISMATCH');
  // All traffic for this worker must be behind sign-in. An override allows
  // access bypass, even when the application has otherwise valid policies.
  if(a.destinations.some(d=>d?.type==='worker'&&d.worker_id===workerId&&d.overrides?.length))
   throw Error('TT_FOTOS_ACCESS_PUBLIC_OVERRIDE');
 }
 return a;
}
export function validateEditorPolicies(policies,emails){
 if(!Array.isArray(policies)||!policies.length)throw Error('ACCESS_POLICIES_MISSING');
 const allowed=new Set();
 for(const p of policies){
  if(p?.decision!=='allow')throw Error('ACCESS_POLICY_NOT_EXCLUSIVE_ALLOW');
  if(!Array.isArray(p.include)||!p.include.length)throw Error('ACCESS_POLICY_INCLUDE_INVALID');
  for(const rule of p.include){
   const email=rule?.email?.email?.toLowerCase();
   if(!email||!emails.includes(email))throw Error('ACCESS_POLICY_TOO_BROAD');
   allowed.add(email);
  }
 }
 if(allowed.size!==emails.length)throw Error('EDITOR_NOT_INCLUDED_IN_ACCESS');
 return true;
}
async function cloudflare(method,path,env,fetcher,data){
 const r=await fetcher('https://api.cloudflare.com/client/v4/accounts/'+env.CLOUDFLARE_ACCOUNT_ID+path,{
  method,redirect:'error',headers:{
   Authorization:'Bearer '+env.CLOUDFLARE_API_TOKEN,Accept:'application/json',
   ...(data?{'Content-Type':'application/json'}:{})
  },...(data?{body:JSON.stringify(data)}:{}),signal:AbortSignal.timeout(12000)
 });
 if(!r.ok)throw Error('CLOUDFLARE_ACCESS_HTTP_'+r.status);
 let response;
 try{response=await r.json()}catch{throw Error('CLOUDFLARE_ACCESS_INVALID_JSON')}
 if(response?.success!==true||response.result==null)throw Error('CLOUDFLARE_ACCESS_BAD_RESPONSE');
 if(response.result_info?.total_pages>1)throw Error('CLOUDFLARE_ACCESS_PAGINATION_REQUIRES_REVIEW');
 return response.result;
}
export async function prepareWorkerAccess({env=process.env,fetcher=fetch,createMissing=false}={}){
 if(!ACCOUNT.test(String(env.CLOUDFLARE_ACCOUNT_ID||''))||!env.CLOUDFLARE_API_TOKEN)
  throw Error('ACCESS_CLOUDFLARE_TOKEN_AND_ACCOUNT_REQUIRED');
 const emails=editorEmails(env.TT_FOTOS_ALLOWED_EMAIL);
 const expectedAud=String(env.TT_FOTOS_ACCESS_AUD||'');
 if(expectedAud&&!AUD.test(expectedAud))throw Error('ACCESS_EXPECTED_AUD_INVALID');
 const request=(method,p,data)=>cloudflare(method,p,env,fetcher,data);
 const worker=chooseWorker(await request('GET','/workers/workers?per_page=100'));
 let apps=await request('GET','/access/apps?per_page=100');
 let app=chooseAccessApp(apps,worker.id,expectedAud);
 let created=false;
 if(!app){
  if(!createMissing)return {ready:false,worker:WORKER_NAME,created:false,aud:null,reason:'ACCESS_APP_MISSING'};
  if(expectedAud)throw Error('EXPECTED_ACCESS_APP_NOT_FOUND');
  // Narrow, explicit email policy on this Worker and on previews.
  const body={
   name:'TT Fotos independiente — editores',
   type:'self_hosted',
   destinations:[{type:'worker',worker_id:worker.id}],
   policies:[{decision:'allow',include:emails.map(email=>({email:{email}}))}]
  };
  app=await request('POST','/access/apps',body);
  if(app?.type!=='self_hosted'||!AUD.test(String(app.aud||''))||!app.id)
   throw Error('NEW_ACCESS_APP_UNVERIFIED');
  if(!app.destinations?.some(d=>d?.type==='worker'&&d.worker_id===worker.id))
   throw Error('NEW_ACCESS_APP_WRONG_WORKER');
  created=true;
 }
 const policies=await request('GET','/access/apps/'+encodeURIComponent(app.id)+'/policies');
 validateEditorPolicies(policies,emails);
 return {ready:true,worker:WORKER_NAME,created,aud:app.aud,reason:'ACCESS_EXACT_EDITOR_POLICY'};
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
 const args=process.argv.slice(2),create=args.length===1&&args[0]==='--create-missing';
 if(args.length&&!create){
  console.error('TT_FOTOS_ACCESS_USAGE: optional --create-missing');
  process.exitCode=2;
 }else{
  try{
   const result=await prepareWorkerAccess({createMissing:create});
   console.log('TT_FOTOS_ACCESS '+(result.ready?'VERIFIED':'MISSING')+
    ' worker='+result.worker+' created='+result.created);
   if(process.env.GITHUB_STEP_SUMMARY)
    fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY,
     'TT Fotos Access: '+(result.ready?'protegido y limitado a correos autorizados':'aún no configurado')+
     (result.created?' (aplicación nueva)':'')+'\n');
   if(result.aud&&process.env.GITHUB_ENV)
    fs.appendFileSync(process.env.GITHUB_ENV,'TT_FOTOS_ACCESS_AUD='+result.aud+'\n');
   if(!result.ready)process.exitCode=1;
  }catch(e){
   console.error('TT_FOTOS_ACCESS_BLOCKED '+String(e.message||e));
   process.exitCode=1;
  }
 }
}
