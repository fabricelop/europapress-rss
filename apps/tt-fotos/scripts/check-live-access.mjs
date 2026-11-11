// Read-only smoke test for the new TT Fotos Worker. No credentials or photo data.
// Run only after deployment: node scripts/check-live-access.mjs https://REAL-TT-FOTOS-ORIGIN
const permittedRedirect=(location,origin)=>{
 if(!location)return false;
 try{
  const u=new URL(location,origin);
  return u.protocol==='https:'&&(
    (u.origin===origin&&u.pathname.startsWith('/cdn-cgi/access/'))||
    (u.hostname.endsWith('.cloudflareaccess.com')&&u.pathname.startsWith('/cdn-cgi/access/'))
  );
 }catch{return false}
};
export function normalizeTtFotosOrigin(value){
 const u=new URL(String(value||''));
 if(u.protocol!=='https:'||!u.hostname||u.pathname!=='/'||u.search||u.hash||u.username||u.password)
  throw Error('TT_FOTOS_ORIGIN_MUST_BE_HTTPS_ROOT');
 if(u.hostname==='ttactualidad.rainyraven22.chatgpt.site'||u.hostname==='chatgpt.com')
  throw Error('NOT_AN_INDEPENDENT_TT_FOTOS_ORIGIN');
 return u.origin;
}
export function anonymousGateStatus(status,location,origin){
 if(status===401||status===403)return 'denied';
 if([301,302,303,307,308].includes(status)&&permittedRedirect(location,origin))
  return 'access_login_redirect';
 throw Error('ANONYMOUS_GATE_UNSAFE_OR_UNAVAILABLE: HTTP '+status);
}
export async function checkLiveAccess(raw,fetcher=fetch){
 const origin=normalizeTtFotosOrigin(raw);
 const result=[];
 for(const path of ['/fotos','/api/tt-fotos/v1/status']){
  const r=await fetcher(origin+path,{
   method:'GET',cache:'no-store',redirect:'manual',
   signal:AbortSignal.timeout(10000)
  });
  result.push({path,status:r.status,gate:anonymousGateStatus(r.status,r.headers.get('location'),origin)});
  try{await r.body?.cancel()}catch{}
 }
 return {origin,checks:result,
  note:'An anonymous denial alone does not prove Cloudflare edge Access is configured. Verify protected Worker policy and login in an authorized browser.'};
}
if(process.argv[1]&&new URL('file://'+process.argv[1]).pathname===new URL(import.meta.url).pathname){
 checkLiveAccess(process.argv[2]).then(r=>{
  for(const c of r.checks)console.log('TT_FOTOS_ANON_DENIED '+c.path+' status='+c.status+' gate='+c.gate);
  console.log('TT_FOTOS_NOTE: verify Cloudflare Worker-level Access plus authenticated editor login separately.');
 },e=>{console.error('TT_FOTOS_LIVE_CHECK_FAILED '+String(e.message||e));process.exitCode=1});
}
