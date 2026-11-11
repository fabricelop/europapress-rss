import test from 'node:test';
import assert from 'node:assert/strict';
import {anonymousGateStatus,checkLiveAccess,normalizeTtFotosOrigin} from '../scripts/check-live-access.mjs';
const origin='https://tt-fotos-independent.example.workers.dev';
test('only a standalone HTTPS root can be checked',()=>{
 assert.equal(normalizeTtFotosOrigin(origin),origin);
 for(const bad of ['http://tt-fotos.example','https://ttactualidad.rainyraven22.chatgpt.site',
  'https://chatgpt.com','https://tt-fotos.example/private','https://tt-fotos.example/?token=1']){
  assert.throws(()=>normalizeTtFotosOrigin(bad));
 }
});
test('anonymous denial and trusted Access login redirects are accepted',()=>{
 assert.equal(anonymousGateStatus(403,null,origin),'denied');
 assert.equal(anonymousGateStatus(401,null,origin),'denied');
 assert.equal(anonymousGateStatus(302,origin+'/cdn-cgi/access/login',origin),'access_login_redirect');
 assert.equal(anonymousGateStatus(302,'https://team.cloudflareaccess.com/cdn-cgi/access/login/example',origin),'access_login_redirect');
});
test('a publicly available gallery, other redirects and non-deploys fail the check',()=>{
 for(const [code,loc] of [[200,null],[503,null],[404,null],[302,'https://evil.example/login'],
  [302,'https://tt-fotos.example/home']]){
  assert.throws(()=>anonymousGateStatus(code,loc,origin));
 }
});
test('two private endpoints are checked without a login or mutating request',async()=>{
 const calls=[];
 const result=await checkLiveAccess(origin,async(url,opts)=>{
  calls.push({url,opts});
  return new Response('',{status:403});
 });
 assert.equal(result.checks.length,2);
 assert.deepEqual(calls.map(x=>new URL(x.url).pathname),['/fotos','/api/tt-fotos/v1/status']);
 assert(calls.every(x=>x.opts.method==='GET'&&x.opts.redirect==='manual'));
});
