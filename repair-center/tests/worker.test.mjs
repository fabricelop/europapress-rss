import test from 'node:test';
import assert from 'node:assert/strict';
import {webcrypto} from 'node:crypto';
import {analyze} from '../diag.mjs';
import {PROJECTS,TARGETS} from '../catalog.mjs';
import {verifyGoogle,makeSession,readSession,makeOAuthState,readOAuthState,sessionCookie} from '../auth.mjs';
import {handleApi} from '../worker.mjs';
if(!globalThis.crypto)globalThis.crypto=webcrypto;
const env={COOKIE_SECRET:'a-dummy-random-secret-with-at-least-32-chars',ALLOWED_EMAIL:'persona@example.com',GOOGLE_CLIENT_ID:'abc.apps.googleusercontent.com',GOOGLE_CLIENT_SECRET:'dummy',GITHUB_TOKEN:'dummy',AGENT_KEY:'this-is-a-very-long-agent-key-123456'};
const uuid='4ff52653-956d-4440-8c03-09b4ccf8f8de';
const req=(path,init={})=>new Request('https://test.example'+path,init);
const signed=async()=>{const s=await makeSession({email:env.ALLOWED_EMAIL,sub:'google123'},env);return {cookie:'__Host-repair_session='+s.cookie,csrf:s.csrf};};
const post=async(path,body,auth,extra={})=>req(path,{method:'POST',headers:{'Origin':'https://test.example','Content-Type':'application/json','X-CSRF':auth.csrf,'Cookie':auth.cookie,...extra},body:JSON.stringify(body)});
test('catálogo cubre proyectos y no permite reiniciar Telegram retirado',()=>{
 assert.equal(PROJECTS.length,10);
 assert.equal(TARGETS.get('ttittulares.telegram').mode,'disabled');
 assert.equal(TARGETS.get('ttendencias.telegram').mode,'disabled');
 assert.equal(TARGETS.get('ttittulares.editorial').mode,'inspect');
 assert.equal(TARGETS.get('ttittulares.radar').workflow,'radar-no-d1.yml');
 assert.equal(new Set([...TARGETS.keys()]).size,[...TARGETS.keys()].length);
});
test('análisis detecta atraso real sin declarar correctos los datos ausentes',()=>{
 const now=Date.parse('2026-10-16T21:00:00Z');
 const checks=analyze({ttStatus:{radar_at:'2026-10-16T20:25:00Z',ready_count:2,problematic_count:4},ttQueue:{items:[{status:'processing',selected_at:'2026-10-16T19:30:00Z'}]},trRecent:{captured_at:'2026-10-16T20:58:00Z'},trQueue:{items:[{status:'preparing',requested_at:'2026-10-16T17:00:00Z'}]},slrRequests:{requests:[{type:'evaluate',tweet_id:'15'}]},slrState:{processed:[]}},now);
 assert.equal(checks.ttRadar.status,'warning');assert.equal(checks.ttEditorial.overdue,1);
 assert.equal(checks.ttImages.problematic,4);assert.equal(checks.trRadar.status,'ok');
 assert.equal(checks.trEditorial.pending,1);assert.equal(checks.slrEditorial.pending,1);
 assert.equal(analyze({},now).ttRadar.status,'unknown');
});
test('sesión firmada valida identidad, caducidad y alteración',async()=>{
 const now=Date.parse('2026-10-16T20:00:00Z');
 const s=await makeSession({email:env.ALLOWED_EMAIL,sub:'x'},env,now);
 const r=req('/',{headers:{Cookie:'__Host-repair_session='+s.cookie}});
 assert.equal((await readSession(r,env,now+1000)).email,env.ALLOWED_EMAIL);
 assert.equal(await readSession(r,env,now+9*3600000),null);
 const hacked=req('/',{headers:{Cookie:'__Host-repair_session='+s.cookie.slice(0,-2)+'zz'}});
 assert.equal(await readSession(hacked,env,now+1000),null);
});
test('estado OAuth firmado y caduco',async()=>{
 const now=Date.now(),s=await makeOAuthState(env,now);
 assert.equal((await readOAuthState(req('/',{headers:{Cookie:'__Host-repair_oauth='+s.cookie}}),env,now+1000)).state,s.state);
 assert.equal(await readOAuthState(req('/',{headers:{Cookie:'__Host-repair_oauth='+s.cookie}}),env,now+700000),null);
});
test('Google RSA ID token verifica firma, correo, audiencia y vencimiento',async()=>{
 const pair=await crypto.subtle.generateKey({name:'RSASSA-PKCS1-v1_5',modulusLength:2048,publicExponent:new Uint8Array([1,0,1]),hash:'SHA-256'},true,['sign','verify']);
 const publicJwk=await crypto.subtle.exportKey('jwk',pair.publicKey);publicJwk.kid='our-test-key';publicJwk.use='sig';
 const encode=x=>Buffer.from(typeof x==='string'?x:JSON.stringify(x)).toString('base64url');
 const now=Math.floor(Date.now()/1000);
 async function jwt(payload){const a=encode({alg:'RS256',kid:'our-test-key'}),b=encode(payload),c=Buffer.from(await crypto.subtle.sign('RSASSA-PKCS1-v1_5',pair.privateKey,new TextEncoder().encode(a+'.'+b))).toString('base64url');return `${a}.${b}.${c}`;}
 const fetcher=async()=>({ok:true,json:async()=>({keys:[publicJwk]})});
 const payload={iss:'https://accounts.google.com',aud:env.GOOGLE_CLIENT_ID,sub:'99',email:env.ALLOWED_EMAIL,email_verified:true,iat:now,exp:now+3600};
 assert.equal((await verifyGoogle(await jwt(payload),env,fetcher)).email,env.ALLOWED_EMAIL);
 await assert.rejects(async()=>verifyGoogle(await jwt({...payload,aud:'other'}),env,fetcher),/google_identity_not_allowed/);
 await assert.rejects(async()=>verifyGoogle(await jwt({...payload,email:'attacker@gmail.com'}),env,fetcher),/google_identity_not_allowed/);
 const tampered=(await jwt(payload)).replace(/.$/,'a');
 await assert.rejects(()=>verifyGoogle(tampered,env,fetcher),/invalid_signature|invalid_jwt/);
});
test('sin login se deniegan catálogo, diagnóstico y reparación',async()=>{
 for(const path of ['/api/catalog','/api/session'])assert.equal((await handleApi(req(path),env)).status,401);
 assert.equal((await handleApi(req('/api/repair',{method:'POST',headers:{Origin:'https://test.example'},body:'{}'}),env)).status,401);
});
test('no se acepta POST sin Origin y CSRF, ni petición de Telegram desactivado',async()=>{
 const s=await signed();
 assert.equal((await handleApi(req('/api/repair',{method:'POST',headers:{Cookie:s.cookie},body:'{}'}),env)).status,403);
 assert.equal((await handleApi(req('/api/repair',{method:'POST',headers:{Cookie:s.cookie,Origin:'https://evil.example'},body:'{}'}),env)).status,403);
 assert.equal((await handleApi(await post('/api/repair',{target:'ttendencias.telegram',request_id:uuid},s),env)).status,422);
 assert.equal((await handleApi(await post('/api/repair',{target:'../bad',request_id:uuid},s),env)).status,404);
});
test('cloud dispatcher envía solo una acción lista blanca, nunca una reparación exitosa ficticia',async()=>{
 const s=await signed(),calls=[];const old=globalThis.fetch;
 globalThis.fetch=async(url,opts)=>{calls.push({url,opts});if(url.includes('/runs?'))return new Response(JSON.stringify({workflow_runs:[]}),{status:200});if(url.includes('/dispatches'))return new Response(null,{status:204});throw Error('unexpected_fetch');};
 try{
  const res=await handleApi(await post('/api/repair',{target:'ttittulares.radar',request_id:uuid},s),env);
  assert.equal(res.status,202);const body=await res.json();assert.equal(body.state,'submitted');
  assert.match(calls[1].url,/repair-center.yml\/dispatches$/);
  const sent=JSON.parse(calls[1].opts.body);assert.equal(sent.inputs.target,'ttittulares.radar');
  assert.equal(sent.ref,'main');
 }finally{globalThis.fetch=old;}
});
test('se bloquea solicitud duplicada que ya está en curso',async()=>{
 const s=await signed();let count=0;const old=globalThis.fetch;
 globalThis.fetch=async()=>{count++;return new Response(JSON.stringify({workflow_runs:[{display_title:'RC ttittulares.radar '+uuid,status:'in_progress',created_at:new Date().toISOString(),html_url:'https://github.com/test'}]}));};
 try{const r=await (await handleApi(await post('/api/repair',{target:'ttittulares.radar',request_id:uuid},s),env)).json();assert.equal(r.state,'already_submitted');assert.equal(count,1);}finally{globalThis.fetch=old;}
});
test('orden local encola sin ejecutar al PC y conserva orden duplicada',async()=>{
 const s=await signed(),store=new Map();
 const localEnv={...env,DB:{
  prepare(sql){return {
   bind(...args){return {
    async run(){if(sql.startsWith('INSERT')&&!store.has(args[0]))store.set(args[0],{id:args[0],target:args[1],state:'queued',created_at:args[3],updated_at:args[4]});return {meta:{changes:1}};},
    async first(){return store.get(args[0])||null;}
   };}
  };}
 }};

 const r=await handleApi(await post('/api/repair',{target:'ttittulares.windows',request_id:uuid},s),localEnv);
 assert.equal(r.status,202);assert.equal((await r.json()).state,'queued');assert.equal(store.size,1);
});
test('agente sin clave válida no puede reclamar órdenes',async()=>{
 const r=await handleApi(req('/api/agent/claim',{method:'POST',headers:{'X-Agent-Key':'bad'}}),env);assert.equal(r.status,401);
});
test('no hay temporizadores ni cron declarados para diagnósticos remotos',async()=>{
 assert.equal(PROJECTS.every(p=>p.processes.every(x=>!('schedule' in x))),true);
});
test('el punto de salud no revela secretos y configuración pública solo da client_id',async()=>{
 const [h,c]=await Promise.all([handleApi(req('/api/health'),env),handleApi(req('/api/public-config'),env)]);
 assert.equal(h.status,200);assert.equal((await h.json()).ok,true);
 const publicConfig=await c.text();assert.equal(publicConfig.includes(env.GITHUB_TOKEN),false);assert.equal(publicConfig.includes(env.GOOGLE_CLIENT_SECRET),false);
});
test('OAuth inicia redirección PKCE con cookie firmada y rechaza callback sin estado',async()=>{
 const r=await handleApi(req('/api/auth/start'),env);assert.equal(r.status,302);
 const u=new URL(r.headers.get('Location'));assert.equal(u.hostname,'accounts.google.com');
 assert.equal(u.searchParams.get('code_challenge_method'),'S256');assert.equal(u.searchParams.get('response_type'),'code');
 assert.match(r.headers.get('Set-Cookie'),/SameSite=Lax/);
 const cb=await handleApi(req('/api/auth/callback?code=fake&state=fake'),env);assert.equal(cb.status,403);
});
test('cabecera pública no admite exponer APIs privadas mediante GET sin cookie',async()=>{
 assert.equal((await handleApi(req('/api/jobs?target=ttittulares.radar&id='+uuid),env)).status,401);
 assert.equal((await handleApi(req('/api/diagnose'),env)).status,401);
});
test('GH no disponible devuelve excepción, no falso despacho exitoso',async()=>{
 const auth=await signed();const old=globalThis.fetch;
 globalThis.fetch=async()=>new Response(JSON.stringify({message:'rate limited'}),{status:403});
 try{await assert.rejects(async()=>handleApi(await post('/api/repair',{target:'ttendencias.radar',request_id:uuid},auth),env),/github_http_403/);}finally{globalThis.fetch=old;}
});
