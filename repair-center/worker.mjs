import {PROJECTS,TARGETS} from './catalog.mjs';
import {gatherState} from './diag.mjs';
import {verifyGoogle,makeSession,readSession,agentAuthorized,sessionCookie,makeOAuthState,readOAuthState,oauthCookie} from './auth.mjs';
const API='https://api.github.com/repos/fabricelop/europapress-rss';
const JSON_HEADERS={'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer','X-Frame-Options':'DENY'};
function json(body,status=200,headers={}){return new Response(JSON.stringify(body),{status,headers:{...JSON_HEADERS,...headers}});}
function fail(code,status=400){return json({ok:false,error:code},status);}
function configured(e){return !!(e.GOOGLE_CLIENT_ID&&e.ALLOWED_EMAIL&&e.COOKIE_SECRET&&e.GITHUB_TOKEN&&e.GOOGLE_CLIENT_SECRET);}
function sameOrigin(request){const origin=request.headers.get('Origin');return origin===new URL(request.url).origin;}
const uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i;
async function bodyOf(req){if(Number(req.headers.get('content-length')||0)>4096)throw Error('body_too_large');let str=await req.text();if(str.length>4096)throw Error('body_too_large');return JSON.parse(str);}
async function gh(env,path,init={}){
 const r=await fetch(API+path,{...init,headers:{'Authorization':`Bearer ${env.GITHUB_TOKEN}`,'Accept':'application/vnd.github+json','X-GitHub-Api-Version':'2022-11-28','User-Agent':'Centro-Reparaciones',...(init.headers||{})},signal:AbortSignal.timeout(9000)});
 if(!r.ok){const e=new Error(`github_http_${r.status}`);e.status=r.status;throw e;}
 if(r.status===204)return null;
 return await r.json();
}
async function getRuns(env){return (await gh(env,'/actions/workflows/repair-center.yml/runs?event=workflow_dispatch&per_page=100')).workflow_runs||[];}
function findRun(runs,target,id){return runs.find(r=>String(r.display_title||'')===`RC ${target} ${id}`);}
async function cloudDispatch(env,target,id){
 const runs=await getRuns(env);
 const match=findRun(runs,target,id);
 if(match)return {kind:'cloud',state:'already_submitted',request_id:id,url:match.html_url};
 const active=runs.find(r=>String(r.display_title||'').startsWith(`RC ${target} `)&&['queued','in_progress','waiting','requested','pending'].includes(r.status)&&Date.now()-Date.parse(r.created_at)<10*60*1000);
 if(active)return {kind:'cloud',state:'already_running',request_id:id,url:active.html_url};
 await gh(env,'/actions/workflows/repair-center.yml/dispatches',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ref:'main',inputs:{target,request_id:id}})});
 return {kind:'cloud',state:'submitted',request_id:id,note:'La ejecución se ha solicitado; aún no está verificada la reparación.'};
}
async function localQueue(env,target,id){
 if(!env.DB)return fail('database_not_configured',503);
 const now=new Date().toISOString(),expiry=new Date(Date.now()+7*24*3600000).toISOString();
 await env.DB.prepare('INSERT OR IGNORE INTO jobs (id,target,state,created_at,updated_at,expires_at) VALUES (?,?,?,?,?,?)').bind(id,target,'queued',now,now,expiry).run();
 const job=await env.DB.prepare('SELECT id,target,state,created_at,updated_at,detail FROM jobs WHERE id=?').bind(id).first();
 if(job.target!==target)return fail('request_id_conflict',409);
 return json({ok:true,kind:'local',request_id:id,state:job.state,note:'Orden guardada. Se ejecutará únicamente cuando el agente de Windows esté conectado.'},202);
}
async function jobStatus(env,target,id){
 const p=TARGETS.get(target);if(!p)return fail('unknown_target',404);
 if(p.mode==='local'){
  if(!env.DB)return fail('database_not_configured',503);
  await settleStaleLocal(env.DB);
  const record=await env.DB.prepare('SELECT id,target,state,created_at,updated_at,detail FROM jobs WHERE id=? AND target=?').bind(id,target).first();
  return record?json({ok:true,kind:'local',...record}):fail('job_not_found',404);
 }
 if(p.mode!=='cloud')return fail('not_executable',422);
 const found=findRun(await getRuns(env),target,id);
 if(!found)return json({ok:true,kind:'cloud',request_id:id,state:'awaiting_github_run',note:'Todavía sin ejecución registrada; no implica reparación.'});
 const state=found.status==='completed'?(found.conclusion==='success'?'dispatched_unverified':'failed'):(Date.now()-Date.parse(found.created_at)>20*60*1000?'stalled':found.status);
 return json({ok:true,kind:'cloud',request_id:id,state,conclusion:found.conclusion,url:found.html_url,note:state==='dispatched_unverified'?'El despachador terminó. Hay que comprobar el workflow reparador y volver a diagnosticar.':undefined});
}
// Sólo bajo consulta explícita: nunca repetir una orden local cuyo resultado sea incierto.
async function settleStaleLocal(db){
 const stale=new Date(Date.now()-15*60000).toISOString(),now=new Date().toISOString();
 await db.prepare(`UPDATE jobs SET state='failed',detail='Agente sin confirmación durante más de 15 min; ejecución indeterminada. Revisión manual necesaria.',updated_at=?,lease=NULL WHERE state='running' AND updated_at<?`).bind(now,stale).run();
 await db.prepare(`UPDATE jobs SET state='failed',detail='La orden caducó sin conexión Windows (7 días)',updated_at=? WHERE state='queued' AND expires_at<?`).bind(now,now).run();
}
async function agent(req,env,path){
 if(!await agentAuthorized(req,env))return fail('unauthorized_agent',401);
 if(!env.DB)return fail('database_not_configured',503);
 if(path==='/api/agent/claim'){
  await settleStaleLocal(env.DB);
  const lease=crypto.randomUUID(),now=new Date().toISOString();
  const record=await env.DB.prepare(`UPDATE jobs SET state='running',updated_at=?,lease=? WHERE id=(SELECT id FROM jobs WHERE state='queued' AND expires_at > ? ORDER BY created_at LIMIT 1) RETURNING id,target,lease`).bind(now,lease,now).first();
  return json({ok:true,job:record||null});
 }
 if(path==='/api/agent/report'){
  const b=await bodyOf(req);
  if(!uuid.test(String(b.id||''))||!uuid.test(String(b.lease||''))||!['diagnosed','triggered_unverified','failed','needs_configuration'].includes(b.state)||typeof b.detail!=='string')return fail('bad_report');
  const now=new Date().toISOString();
  const result=await env.DB.prepare(`UPDATE jobs SET state=?,detail=?,updated_at=?,lease=NULL WHERE id=? AND lease=? AND state='running'`).bind(b.state,b.detail.slice(0,2000),now,b.id,b.lease).run();
  return result.meta.changes===1?json({ok:true}):fail('stale_lease',409);
 }
 return fail('not_found',404);
}
export async function handleApi(request,env){
 const url=new URL(request.url),path=url.pathname,method=request.method;
 if(path==='/api/public-config'&&method==='GET')return json({client_id:env.GOOGLE_CLIENT_ID||'',ready:configured(env)});
 if(path==='/api/health'&&method==='GET')return json({ok:true,service:'repair-center',version:'1.0.0'});
 if(path.startsWith('/api/agent/')){
  if(method!=='POST')return fail('method_not_allowed',405);
  return await agent(request,env,path);
 }
 if(path==='/api/auth/start'&&method==='GET'){
  if(!configured(env))return fail('service_not_configured',503);
  const oauth=await makeOAuthState(env);
  const redirect=new URL('/api/auth/callback',url.origin).toString();
  const google=new URL('https://accounts.google.com/o/oauth2/v2/auth');
  for(const [k,v] of Object.entries({client_id:env.GOOGLE_CLIENT_ID,redirect_uri:redirect,response_type:'code',scope:'openid email profile',state:oauth.state,code_challenge:oauth.challenge,code_challenge_method:'S256',prompt:'select_account'}))google.searchParams.set(k,v);
  return new Response(null,{status:302,headers:{Location:google.toString(),'Set-Cookie':oauthCookie(oauth.cookie),'Cache-Control':'no-store'}});
 }
 if(path==='/api/auth/callback'&&method==='GET'){
  if(!configured(env))return fail('service_not_configured',503);
  const state=await readOAuthState(request,env);
  if(!state||state.state!==url.searchParams.get('state')||!url.searchParams.get('code'))return fail('oauth_state_invalid',403);
  const redirect=new URL('/api/auth/callback',url.origin).toString();
  const tokenResp=await fetch('https://oauth2.googleapis.com/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({client_id:env.GOOGLE_CLIENT_ID,client_secret:env.GOOGLE_CLIENT_SECRET,code:url.searchParams.get('code'),grant_type:'authorization_code',redirect_uri:redirect,code_verifier:state.verifier}),signal:AbortSignal.timeout(8000)});
  if(!tokenResp.ok)return fail('oauth_code_exchange_failed',401);
  const token=await tokenResp.json();
  const identity=await verifyGoogle(token.id_token,env);
  const sess=await makeSession(identity,env);
  const headers=new Headers({'Location':'/?auth=ok','Cache-Control':'no-store'});
  headers.append('Set-Cookie',sessionCookie(sess.cookie));
  headers.append('Set-Cookie',oauthCookie('',0));
  return new Response(null,{status:302,headers});
 }
 const session=await readSession(request,env);
 if(!session)return fail('login_required',401);
 if(path==='/api/session'&&method==='GET')return json({ok:true,email:session.email,csrf:session.csrf});
 if(path==='/api/catalog'&&method==='GET')return json({ok:true,projects:PROJECTS});
 if(path==='/api/diagnose'&&method==='POST'){
  if(!sameOrigin(request)||request.headers.get('X-CSRF')!==session.csrf)return fail('invalid_csrf',403);
  if(!env.GITHUB_TOKEN)return fail('github_not_configured',503);
  return json({ok:true,...await gatherState(env)});
 }
 if(path==='/api/jobs'&&method==='GET'){
  const target=url.searchParams.get('target')||'',id=url.searchParams.get('id')||'';
  if(!uuid.test(id))return fail('invalid_request_id');
  return await jobStatus(env,target,id);
 }
 if(path==='/api/repair'&&method==='POST'){
  if(!sameOrigin(request)||request.headers.get('X-CSRF')!==session.csrf)return fail('invalid_csrf',403);
  const b=await bodyOf(request),target=String(b.target||''),id=String(b.request_id||'');
  if(!uuid.test(id))return fail('invalid_request_id');
  const proc=TARGETS.get(target);if(!proc)return fail('unknown_target',404);
  if(proc.mode==='local')return await localQueue(env,target,id);
  if(proc.mode!=='cloud')return fail('operation_not_automatable',422);
  if(!env.GITHUB_TOKEN)return fail('github_not_configured',503);
  return json({ok:true,...await cloudDispatch(env,target,id)},202);
 }
 if(path==='/api/logout'&&method==='POST'){
  if(!sameOrigin(request)||request.headers.get('X-CSRF')!==session.csrf)return fail('invalid_csrf',403);
  return json({ok:true},200,{'Set-Cookie':sessionCookie('',0)});
 }
 return fail('not_found',404);
}
export default {async fetch(request,env){
 try{
  const url=new URL(request.url);
  if(url.pathname.startsWith('/api/')){
   const res=await handleApi(request,env);
   if(typeof res.status!=='number')throw Error('invalid_status');
   return res;
  }
  if(!env.ASSETS)return fail('static_assets_not_configured',503);
  const res=await env.ASSETS.fetch(request);
  const headers=new Headers(res.headers);
  headers.set('X-Content-Type-Options','nosniff');headers.set('Referrer-Policy','no-referrer');headers.set('X-Frame-Options','DENY');
  headers.set('Content-Security-Policy',"default-src 'self'; script-src 'self' https://accounts.google.com/gsi/client; connect-src 'self' https://accounts.google.com; frame-src https://accounts.google.com; style-src 'self' 'unsafe-inline' https://accounts.google.com; img-src 'self' data: https://*.googleusercontent.com; frame-ancestors 'none'; base-uri 'self'; form-action 'self'");
  return new Response(res.body,{status:res.status,headers});
 }catch(e){
  const code=String(e.message||'unexpected_error');
  if(['invalid_jwt','invalid_jwt_json','invalid_signature','unknown_signing_key','google_identity_not_allowed','unsupported_jwt','invalid_identity_token'].includes(code))return fail('identity_not_authorized',401);
  if(['body_too_large','invalid_origin'].includes(code))return fail(code,400);
  return json({ok:false,error:'upstream_or_internal_error',reason:code.startsWith('github_http_')?code:undefined},503);
 }
 }};
