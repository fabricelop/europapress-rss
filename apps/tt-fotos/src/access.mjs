// Cloudflare Access JWT verification for a standalone, editor-only Worker.
// Never trust the unverified Cf-Access-Authenticated-User-Email header.
const encoder=new TextEncoder();
const dec=new TextDecoder();
const encRe=/^[A-Za-z0-9_-]+$/;
function decode(input){
  if(!encRe.test(input)||input.length>16384)throw Error('INVALID_JWT_ENCODING');
  const base=input.replace(/-/g,'+').replace(/_/g,'/');
  const binary=atob(base+'='.repeat((4-base.length%4)%4));
  return Uint8Array.from(binary,c=>c.charCodeAt(0));
}
function payload(input){return JSON.parse(dec.decode(decode(input)))}
const issuerURL=value=>{
  const u=new URL(String(value||''));
  if(u.protocol!=='https:'||!u.hostname.endsWith('.cloudflareaccess.com')||u.pathname!=='/'||u.search||u.hash||u.username||u.password)
    throw Error('ACCESS_ISSUER_CONFIGURATION_INVALID');
  return u.origin;
};
export async function authenticateAccess(request,env,fetcher=fetch,clock=Date.now){
  const issuer=issuerURL(env.CF_ACCESS_ISSUER);
  const audience=String(env.CF_ACCESS_AUD||'');
  const allow=String(env.TT_FOTOS_ALLOWED_EMAIL||'').split(',').map(x=>x.trim().toLowerCase()).filter(Boolean);
  if(!audience||!allow.length||allow.includes('*'))throw Error('ACCESS_CONFIGURATION_REQUIRED');
  const jwt=request.headers.get('Cf-Access-Jwt-Assertion');
  if(!jwt||jwt.length>12000)return null;
  let parts,header,claims;
  try{
    parts=jwt.split('.');if(parts.length!==3)return null;
    header=payload(parts[0]);claims=payload(parts[1]);
    if(header.alg!=='RS256'||typeof header.kid!=='string'||header.kid.length>256)return null;
    const time=Math.floor(clock()/1000);
    if(claims.iss!==issuer||!(typeof claims.aud==='string'?claims.aud===audience:Array.isArray(claims.aud)&&claims.aud.includes(audience)))return null;
    if(!Number.isFinite(claims.exp)||claims.exp<=time-30||!Number.isFinite(claims.iat)||claims.iat>time+60||claims.nbf!=null&&(!Number.isFinite(claims.nbf)||claims.nbf>time+60))return null;
    if(!allow.includes(String(claims.email||'').toLowerCase()))return null;
    const r=await fetcher(issuer+'/cdn-cgi/access/certs',{redirect:'error',signal:AbortSignal.timeout(5000)});
    if(!r.ok)return null;
    const jwks=await r.json();const jwk=(jwks.keys||[]).find(k=>k.kid===header.kid&&k.kty==='RSA'&&(!k.alg||k.alg==='RS256'));
    if(!jwk)return null;
    const key=await crypto.subtle.importKey('jwk',jwk,{name:'RSASSA-PKCS1-v1_5',hash:'SHA-256'},false,['verify']);
    const signed=encoder.encode(parts[0]+'.'+parts[1]);
    const good=await crypto.subtle.verify('RSASSA-PKCS1-v1_5',key,decode(parts[2]),signed);
    if(!good)return null;
    return {isEditor:true,email:claims.email,source:'verified_cloudflare_access_jwt'};
  }catch{return null}
}