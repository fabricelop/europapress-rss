import test from 'node:test';
import assert from 'node:assert/strict';
import {webcrypto} from 'node:crypto';
import {authenticateAccess} from '../src/access.mjs';
if(!globalThis.crypto)globalThis.crypto=webcrypto;
const e={CF_ACCESS_ISSUER:'https://my-team.cloudflareaccess.com',CF_ACCESS_AUD:'tt-fotos-audience',TT_FOTOS_ALLOWED_EMAIL:'editor@example.org'};
const b64=s=>Buffer.from(typeof s==='string'?s:JSON.stringify(s)).toString('base64url');
async function fixture(){
 const pair=await crypto.subtle.generateKey({name:'RSASSA-PKCS1-v1_5',modulusLength:2048,publicExponent:new Uint8Array([1,0,1]),hash:'SHA-256'},true,['sign','verify']);
 const key=await crypto.subtle.exportKey('jwk',pair.publicKey);key.kid='test';key.alg='RS256';
 const fetcher=async()=>new Response(JSON.stringify({keys:[key]}),{status:200,headers:{'content-type':'application/json'}});
 async function make(claims={},header={}){
   const now=Math.floor(Date.now()/1000),h=b64({alg:'RS256',kid:'test',...header}),p=b64({iss:e.CF_ACCESS_ISSUER,aud:e.CF_ACCESS_AUD,email:'editor@example.org',iat:now,exp:now+3600,...claims});
   const bytes=new TextEncoder().encode(h+'.'+p),sig=await crypto.subtle.sign('RSASSA-PKCS1-v1_5',pair.privateKey,bytes);
   return `${h}.${p}.${Buffer.from(sig).toString('base64url')}`;
 }
 const request=t=>new Request('https://tt-fotos.example/fotos',{headers:{'Cf-Access-Jwt-Assertion':t}});
 return {make,fetcher,request};
}
test('accepts only signed, unexpired, allowed Cloudflare Access editor',async()=>{
 const t=await fixture();const v=await authenticateAccess(t.request(await t.make()),e,t.fetcher);
 assert.equal(v.email,'editor@example.org');assert.equal(v.isEditor,true);
});
test('rejects missing token, spoofed email, wrong audience and forged signatures',async()=>{
 const t=await fixture();const token=await t.make();
 assert.equal(await authenticateAccess(new Request('https://tt-fotos.example/fotos',{headers:{'Cf-Access-Authenticated-User-Email':'editor@example.org'}}),e,t.fetcher),null);
 assert.equal(await authenticateAccess(t.request(await t.make({email:'attacker@example.org'})),e,t.fetcher),null);
 assert.equal(await authenticateAccess(t.request(await t.make({aud:'other-app'})),e,t.fetcher),null);
 const pieces=token.split('.');pieces[1]=b64({iss:e.CF_ACCESS_ISSUER,aud:e.CF_ACCESS_AUD,email:'editor@example.org',extra:'forged',iat:Math.floor(Date.now()/1000),exp:Math.floor(Date.now()/1000)+3600});
 assert.equal(await authenticateAccess(t.request(pieces.join('.')),e,t.fetcher),null);
});
test('rejects expired, future and wrong issuer Access JWTs',async()=>{
 const t=await fixture(),now=Math.floor(Date.now()/1000);
 assert.equal(await authenticateAccess(t.request(await t.make({exp:now-120})),e,t.fetcher),null);
 assert.equal(await authenticateAccess(t.request(await t.make({iat:now+300})),e,t.fetcher),null);
 assert.equal(await authenticateAccess(t.request(await t.make({iss:'https://wrong.cloudflareaccess.com'})),e,t.fetcher),null);
});
test('fail closed when issuer or editor allowlist is not configured',async()=>{
 const t=await fixture();const req=t.request(await t.make());
 await assert.rejects(()=>authenticateAccess(req,{...e,CF_ACCESS_ISSUER:'http://bad.example'},t.fetcher),/ACCESS_ISSUER_CONFIGURATION_INVALID/);
 await assert.rejects(()=>authenticateAccess(req,{...e,TT_FOTOS_ALLOWED_EMAIL:'*'},t.fetcher),/ACCESS_CONFIGURATION_REQUIRED/);
});