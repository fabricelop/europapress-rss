const enc=new TextEncoder();
function decode64(v){if(!/^[\w-]+$/.test(v))throw Error('bad_base64');return Uint8Array.from(atob(v.replace(/-/g,'+').replace(/_/g,'/')+'='.repeat((4-v.length%4)%4)),c=>c.charCodeAt(0));}
function encode64(v){return btoa(String.fromCharCode(...v)).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/g,'');}
export async function verifyGoogle(idToken,env,fetcher=fetch,now=Date.now()){
 if(typeof idToken!=='string'||idToken.length>8000)throw Error('invalid_identity_token');
 const parts=idToken.split('.');if(parts.length!==3)throw Error('invalid_jwt');
 let head,body;
 try{head=JSON.parse(new TextDecoder().decode(decode64(parts[0])));body=JSON.parse(new TextDecoder().decode(decode64(parts[1])));}catch{throw Error('invalid_jwt_json');}
 if(head.alg!=='RS256'||!head.kid||typeof head.kid!=='string')throw Error('unsupported_jwt');
 const r=await fetcher('https://www.googleapis.com/oauth2/v3/certs',{signal:AbortSignal.timeout(7000)});
 if(!r.ok)throw Error('google_keys_unavailable');
 const jwks=await r.json(); const jwk=(jwks.keys||[]).find(k=>k.kid===head.kid&&k.kty==='RSA'&&k.use==='sig');
 if(!jwk)throw Error('unknown_signing_key');
 const key=await crypto.subtle.importKey('jwk',jwk,{name:'RSASSA-PKCS1-v1_5',hash:'SHA-256'},false,['verify']);
 if(!await crypto.subtle.verify('RSASSA-PKCS1-v1_5',key,decode64(parts[2]),enc.encode(parts[0]+'.'+parts[1])))throw Error('invalid_signature');
 const sec=Math.floor(now/1000);
 if(!['accounts.google.com','https://accounts.google.com'].includes(body.iss)||body.aud!==env.GOOGLE_CLIENT_ID||!Number.isFinite(body.exp)||body.exp<=sec||body.exp>sec+86400||!Number.isFinite(body.iat)||body.iat>sec+120||body.iat<sec-86400||body.email_verified!==true||String(body.email||'').toLowerCase()!==String(env.ALLOWED_EMAIL||'').toLowerCase()||!body.sub)throw Error('google_identity_not_allowed');
 return {email:String(body.email).toLowerCase(),sub:body.sub};
}
async function hmacKey(secret){return crypto.subtle.importKey('raw',enc.encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign','verify']);}
export async function makeSession(identity,env,now=Date.now()){
 const body={email:identity.email,sub:identity.sub,exp:Math.floor(now/1000)+8*3600,csrf:crypto.randomUUID()};
 const packed=encode64(enc.encode(JSON.stringify(body)));
 const sig=encode64(new Uint8Array(await crypto.subtle.sign('HMAC',await hmacKey(env.COOKIE_SECRET),enc.encode(packed))));
 return {cookie:packed+'.'+sig,csrf:body.csrf};
}
export async function readSession(request,env,now=Date.now()){
 if(!env.COOKIE_SECRET)return null;
 const all=request.headers.get('Cookie')||'';
 const match=all.match(/(?:^|;\s*)__Host-repair_session=([^;]+)/);
 if(!match)return null;const parts=match[1].split('.');if(parts.length!==2)return null;
 try{
  const key=await hmacKey(env.COOKIE_SECRET);
  if(!await crypto.subtle.verify('HMAC',key,decode64(parts[1]),enc.encode(parts[0])))return null;
  const body=JSON.parse(new TextDecoder().decode(decode64(parts[0])));
  if(body.exp<=Math.floor(now/1000)||body.email!==String(env.ALLOWED_EMAIL).toLowerCase()||!body.csrf||!body.sub)return null;
  return body;
 }catch{return null;}
}
export async function agentAuthorized(req,env){
 const key=req.headers.get('X-Agent-Key')||'';
 if(!env.AGENT_KEY||key.length<32||key.length>256)return false;
 const a=new Uint8Array(await crypto.subtle.digest('SHA-256',enc.encode(key)));
 const b=new Uint8Array(await crypto.subtle.digest('SHA-256',enc.encode(env.AGENT_KEY)));
 let diff=0;for(let i=0;i<a.length;i++)diff|=a[i]^b[i];return diff===0;
}
export const sessionCookie=(value,maxAge=28800)=>`__Host-repair_session=${value}; Path=/; Max-Age=${maxAge}; Secure; HttpOnly; SameSite=Strict`;
export async function makeOAuthState(env,now=Date.now()){
 const body={state:crypto.randomUUID(),verifier:encode64(crypto.getRandomValues(new Uint8Array(32))),exp:Math.floor(now/1000)+600};
 const packed=encode64(enc.encode(JSON.stringify(body)));
 const signature=encode64(new Uint8Array(await crypto.subtle.sign('HMAC',await hmacKey(env.COOKIE_SECRET),enc.encode(packed))));
 const challenge=encode64(new Uint8Array(await crypto.subtle.digest('SHA-256',enc.encode(body.verifier))));
 return {cookie:packed+'.'+signature,challenge,state:body.state};
}
export async function readOAuthState(req,env,now=Date.now()){
 const v=(req.headers.get('Cookie')||'').match(/(?:^|;\s*)__Host-repair_oauth=([^;]+)/)?.[1];
 if(!v)return null;
 const parts=v.split('.');if(parts.length!==2)return null;
 try{
  if(!await crypto.subtle.verify('HMAC',await hmacKey(env.COOKIE_SECRET),decode64(parts[1]),enc.encode(parts[0])))return null;
  const state=JSON.parse(new TextDecoder().decode(decode64(parts[0])));
  return state.exp>Math.floor(now/1000)&&state.state&&state.verifier?state:null;
 }catch{return null;}
}
export const oauthCookie=(value,maxAge=600)=>`__Host-repair_oauth=${value}; Path=/; Max-Age=${maxAge}; Secure; HttpOnly; SameSite=Lax`;
