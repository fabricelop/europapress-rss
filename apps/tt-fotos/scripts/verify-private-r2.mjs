// Read-only verification: reject a TT Fotos bucket with any public R2 exposure.
// Requires a scoped Cloudflare API token in the environment; never logs it.
const ACCOUNT=/^[a-f0-9]{32}$/i;
const BUCKET='tt-fotos-originals-private';
export function checkPrivateR2Responses(managed, custom) {
 if(!managed||typeof managed!=='object'||managed.enabled!==false)
  throw Error('TT_FOTOS_R2_MANAGED_PUBLIC_OR_UNKNOWN');
 if(!custom||!Array.isArray(custom.domains))
  throw Error('TT_FOTOS_R2_CUSTOM_DOMAINS_UNKNOWN');
 if(custom.domains.some(d=>!d||d.enabled!==false))
  throw Error('TT_FOTOS_R2_CUSTOM_DOMAIN_PUBLIC_OR_UNKNOWN');
 return {bucket:BUCKET,private:true,customDomainCount:custom.domains.length};
}
async function readCloudflare(path,token,fetcher){
 const response=await fetcher('https://api.cloudflare.com/client/v4'+path,{
  method:'GET',
  headers:{'Authorization':'Bearer '+token,'Accept':'application/json'},
  redirect:'error',
  signal:AbortSignal.timeout(12000)
 });
 if(!response.ok)throw Error('CLOUDFLARE_PRIVATE_R2_CHECK_HTTP_'+response.status);
 let body;
 try{body=await response.json()}catch{throw Error('CLOUDFLARE_PRIVATE_R2_CHECK_INVALID_JSON')}
 if(body?.success!==true||!body.result||typeof body.result!=='object')
  throw Error('CLOUDFLARE_PRIVATE_R2_CHECK_INVALID_RESPONSE');
 return body.result;
}
export async function verifyPrivateR2Environment(env=process.env,fetcher=fetch){
 const account=String(env.CLOUDFLARE_ACCOUNT_ID||'');
 const token=String(env.CLOUDFLARE_API_TOKEN||'');
 if(!ACCOUNT.test(account)||!token)throw Error('CLOUDFLARE_PRIVATE_R2_AUTH_MISSING');
 const prefix='/accounts/'+account+'/r2/buckets/'+BUCKET+'/domains/';
 const [managed,custom]=await Promise.all([
  readCloudflare(prefix+'managed',token,fetcher),
  readCloudflare(prefix+'custom',token,fetcher)
 ]);
 const verified=checkPrivateR2Responses(managed,custom);
 console.log('TT_FOTOS_R2_PRIVATE_VERIFIED public_dev_url=false enabled_custom_domains=0');
 return verified;
}
if(process.argv[1]){
 const {fileURLToPath}=await import('node:url');
 const path=await import('node:path');
 if(path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  try{await verifyPrivateR2Environment()}
  catch(e){console.error('TT_FOTOS_R2_PRIVACY_BLOCKED '+String(e?.message||e));process.exitCode=1}
 }
}
