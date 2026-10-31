// TTActualidad LIVE V8: static pages and real editorial decisions, without Telegram or polling.
const ORIGIN='https://fabricelop.github.io';
const PROJECTS=new Set(['ttittulares','ttendencias']);
const ACTIONS=new Set(['prepare','discard','deleted','published','rework']);
const ID=/^[A-Za-z0-9:_-]{3,128}$/;
const REQUEST=/^[A-Za-z0-9-]{12,80}$/;
const COOKIE_NAME='__Host-ttactualidad_session';
const SESSION_SECONDS=30*24*60*60;
function cors(req){
 const origin=req.headers.get('Origin')||'';
 return {'Content-Type':'application/json; charset=utf-8',
  'Cache-Control':'no-store','X-Content-Type-Options':'nosniff',
  'Access-Control-Allow-Origin':origin===ORIGIN?ORIGIN:'null',
  'Vary':'Origin','Access-Control-Allow-Headers':'Authorization, Content-Type',
  'Access-Control-Allow-Credentials':'true',
  'Access-Control-Allow-Methods':'GET, POST, OPTIONS'};
}
function respond(req,data,status=200,extra={}){
 return new Response(JSON.stringify(data),{status,headers:{...cors(req),...extra}});
}
function bearerAuth(req,env){
 const auth=req.headers.get('Authorization')||'';
 const expected='Bearer '+String(env.PILOT_TOKEN||'');
 return Boolean(env.PILOT_TOKEN)&&auth.length===expected.length&&auth===expected;
}
function b64url(bytes){
 return btoa(String.fromCharCode(...bytes)).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/g,'');
}
function fromB64url(value){
 if(!/^[A-Za-z0-9_-]+$/.test(value))throw Error('invalid_base64url');
 const str=atob(value.replace(/-/g,'+').replace(/_/g,'/')+'='.repeat((4-value.length%4)%4));
 return Uint8Array.from(str,c=>c.charCodeAt(0));
}
async function sessionKey(env){
 if(!env.PILOT_TOKEN)throw Error('missing_pairing_secret');
 return crypto.subtle.importKey('raw',new TextEncoder().encode('TTActualidad session v1:'+env.PILOT_TOKEN),
  {name:'HMAC',hash:'SHA-256'},false,['sign','verify']);
}
async function issueCookie(env){
 const expires=Date.now()+SESSION_SECONDS*1000;
 const payload='v1.'+expires+'.'+crypto.randomUUID();
 const sig=new Uint8Array(await crypto.subtle.sign('HMAC',await sessionKey(env),new TextEncoder().encode(payload)));
 return COOKIE_NAME+'='+payload+'.'+b64url(sig)+'; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age='+SESSION_SECONDS;
}
async function cookieAuth(req,env){
 const header=req.headers.get('Cookie')||'';
 const cookie=header.split(';').map(x=>x.trim()).find(x=>x.startsWith(COOKIE_NAME+'='));
 if(!cookie)return false;
 try{
  const match=/^v1\.(\d{13})\.([0-9a-f-]{36})\.([A-Za-z0-9_-]{43})$/.exec(cookie.slice(COOKIE_NAME.length+1));
  if(!match)return false;
  const expiry=Number(match[1]);
  if(!Number.isSafeInteger(expiry)||expiry<Date.now()||expiry>Date.now()+SESSION_SECONDS*1000)return false;
  const payload='v1.'+match[1]+'.'+match[2];
  return await crypto.subtle.verify('HMAC',await sessionKey(env),fromB64url(match[3]),
   new TextEncoder().encode(payload));
 }catch{return false}
}
function sane(p,id){return PROJECTS.has(p)&&ID.test(String(id||''))}
function recordKey(project,id){return 'action:'+project+':'+id}
async function dispatch(env,row){
 if(env.ACTION_MODE!=='github_dispatch'||!env.GH_DISPATCH_TOKEN||!['deleted','discard','prepare','rework'].includes(row.decision))
  return {state:'pilot_only',routed:false};
 const result=await fetch('https://api.github.com/repos/fabricelop/europapress-rss/dispatches',{
  method:'POST',headers:{
   'Authorization':'Bearer '+env.GH_DISPATCH_TOKEN,'Accept':'application/vnd.github+json',
   'X-GitHub-Api-Version':'2022-11-28','User-Agent':'TTActualidad-Direct-v8',
   'Content-Type':'application/json'
  },body:JSON.stringify({event_type:'ttactualidad_action_v1',
   client_payload:{project:row.project,event_id:row.event_id,decision:row.decision,
    request_id:row.request_id,received_at:row.received_at,revision:row.revision,trend_name:row.trend_name,trend_rank:row.trend_rank}})
 });
 if(result.status!==204)throw Error('dispatch_http_'+result.status);
 return {state:'submitted',routed:true};
}
export default {
 async fetch(req,env){
  const url=new URL(req.url),route=url.pathname;
  if(req.method==='OPTIONS')return new Response('',{status:204,headers:cors(req)});
  if(route==='/health'&&req.method==='GET')
   return respond(req,{ok:true,kind:'ttactualidad-direct-live',version:'v8.1-kv-conflict-fix',
    production_connected:env.ACTION_MODE==='github_dispatch'&&Boolean(env.GH_DISPATCH_TOKEN),
    architecture:'on_demand_no_polling',session_auth:'signed_cookie_v1'});
  if(req.method==='GET'&&!route.startsWith('/api/')&&env.ASSETS)
   return env.ASSETS.fetch(req);
  // Pairing is authenticated by the existing secret once, never stored in JS localStorage.
  if(route==='/api/session'&&req.method==='POST'){
   if(req.headers.get('Origin')!==url.origin||!bearerAuth(req,env))
    return respond(req,{ok:false,error:'unauthorized'},401);
   return respond(req,{ok:true,connected:true},200,{'Set-Cookie':await issueCookie(env)});
  }
  const bearer=bearerAuth(req,env),cookie=bearer?false:await cookieAuth(req,env);
  if(!bearer&&!cookie)return respond(req,{ok:false,error:'unauthorized'},401);
  // A stolen cross-site form cannot send a deletion using the browser session.
  if(cookie&&req.method==='POST'&&req.headers.get('Origin')!==url.origin)
   return respond(req,{ok:false,error:'cross_origin_forbidden'},403);
  // TTendencias images: authenticated on-demand bridge to the EXISTING image-run API.
  // A request means queued, never generated or uploaded. No prompt is run by the Worker.
  // Keep the upstream control token as a Cloudflare secret, not in JS or a cookie.
  if(route==='/api/trend-image'&&(req.method==='GET'||req.method==='POST')){
   const imageHost='https://tt-control.fabricelop.workers.dev';
   let input;
   if(req.method==='POST'){
    if(!(req.headers.get('Content-Type')||'').toLowerCase().startsWith('application/json'))
     return respond(req,{ok:false,error:'json_required'},415);
    try{input=await req.json()}catch{return respond(req,{ok:false,error:'bad_json'},400)}
   }else input={target_id:url.searchParams.get('target_id')};
   const targetId=String(input?.target_id||'');
   const revision=Number(input?.revision);
   if(!/^[A-Za-z0-9._-]{3,128}$/.test(targetId)||
      (req.method==='POST'&&(!Number.isInteger(revision)||revision<0||revision>999)))
    return respond(req,{ok:false,error:'invalid_image_identity'},400);
   if(req.method==='GET'){
    let upstream;
    try{upstream=await fetch(imageHost+'/api/ttendencias-run-status?view=image-job&strong=1&id='+encodeURIComponent(targetId),
     {headers:{'Accept':'application/json'},signal:AbortSignal.timeout(15000)});}
    catch{return respond(req,{ok:false,error:'image_status_unreachable'},502)}
    if(upstream.status===404)return respond(req,{ok:true,found:false,target_id:targetId},200);
    if(!upstream.ok)return respond(req,{ok:false,error:'image_status_http_'+upstream.status},502);
    let result;try{result=await upstream.json()}catch{return respond(req,{ok:false,error:'image_status_invalid'},502)}
    // Never expose the upload credential, hashed secrets or the context snapshot.
    return respond(req,{ok:true,found:true,target_id:targetId,
     revision:Number(result.revision||0),command_id:String(result.command_id||''),
     status:String(result.status||''),phase:String(result.phase||''),
     requested_at:result.requested_at||null,updated_at:result.updated_at||null,
     web_image_stage:String(result.web_image?.stage||''),
     web_image_reason:String(result.web_image?.reason||'').slice(0,140)});
   }
   if(!env.TTENDENCIAS_CONTROL_TOKEN)
    return respond(req,{ok:false,error:'image_bridge_not_configured'},503);
   let upstream;
   try{upstream=await fetch(imageHost+'/api/ttendencias-run',{
    method:'POST',headers:{'content-type':'application/json','Authorization':'Bearer '+env.TTENDENCIAS_CONTROL_TOKEN},
    body:JSON.stringify({task:'images',target_id:targetId,id:targetId,revision}),
    signal:AbortSignal.timeout(25000)});}
   catch{return respond(req,{ok:false,error:'image_dispatch_unreachable'},502)}
   let result;try{result=await upstream.json()}catch{return respond(req,{ok:false,error:'image_dispatch_invalid'},502)}
   if(!upstream.ok||!result.ok)
    return respond(req,{ok:false,error:String(result.error||'image_dispatch_failed').slice(0,100),
     reason:String(result.reason||'').slice(0,100)},upstream.status===409?409:502);
   return respond(req,{ok:true,state:'REQUESTED',target_id:targetId,revision,
    command_id:String(result.command_id||''),requested_at:result.requested_at||null,
    message:'Solicitud registrada; pendiente de recogida por el PC'},202);
  }
  // +Noticia is deliberately separate from existing revisions and decisions.
  // GitHub main is the only editorial authority; 202 means dispatched, NOT saved.
  if(route==='/api/manual-news'&&req.method==='POST'){
   if(!env.PILOT_DECISIONS||env.ACTION_MODE!=='github_dispatch'||!env.GH_DISPATCH_TOKEN)
    return respond(req,{ok:false,error:'editorial_dispatch_unavailable'},503);
   if(!(req.headers.get('Content-Type')||'').toLowerCase().startsWith('application/json'))
    return respond(req,{ok:false,error:'json_required'},415);
   let body;try{body=await req.json()}catch{return respond(req,{ok:false,error:'bad_json'},400)}
   const string=x=>typeof x==='string'?x.trim():null;
   const title=string(body.title),rawUrl=string(body.url),instructions=string(body.instructions);
   const requestId=string(body.request_id);
   if(title===null||rawUrl===null||instructions===null||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(requestId||'')||
      title.length>240||rawUrl.length>2000||instructions.length>1000||
      (!title&&!rawUrl)||(title&&title.length<5))
    return respond(req,{ok:false,error:'invalid_manual_news'},400);
   let link='';
   if(rawUrl){
    try{const parsed=new URL(rawUrl);
     if(parsed.protocol!=='https:'||!parsed.hostname||parsed.username||parsed.password)
      throw Error('invalid_url');
     parsed.hash='';link=parsed.href;
    }catch{return respond(req,{ok:false,error:'invalid_https_url'},400)}
   }
   const eventId='manual-'+requestId.toLowerCase();
   let result;
   try{
    result=await fetch('https://api.github.com/repos/fabricelop/europapress-rss/dispatches',{
     method:'POST',headers:{
      'Authorization':'Bearer '+env.GH_DISPATCH_TOKEN,
      'Accept':'application/vnd.github+json',
      'X-GitHub-Api-Version':'2022-11-28',
      'Content-Type':'application/json',
      'User-Agent':'TTActualidad-Manual-v1'
     },
     body:JSON.stringify({event_type:'ttactualidad_manual_news_v1',
      client_payload:{project:'ttittulares',request_id:requestId.toLowerCase(),
       title,url:link,instructions}})
    });
   }catch{return respond(req,{ok:false,error:'github_dispatch_unreachable'},502)}
   if(result.status!==204)
    return respond(req,{ok:false,error:'github_dispatch_failed',http_status:result.status},502);
   return respond(req,{ok:true,routed:true,state:'submitted',event_id:eventId,
    message:'Pendiente de confirmación en GitHub'},202);
  }
  if(route==='/api/auth'&&req.method==='GET')
   return respond(req,{ok:true,production_connected:env.ACTION_MODE==='github_dispatch'&&Boolean(env.GH_DISPATCH_TOKEN),
    architecture:'on_demand_no_polling',session_authenticated:cookie});
  if(!env.PILOT_DECISIONS)return respond(req,{ok:false,error:'pilot_KV_not_bound'},503);
  if(route==='/api/decisions'&&req.method==='GET'){
   const listing=await env.PILOT_DECISIONS.list({limit:100,prefix:'action:'});
   const items=(await Promise.all(listing.keys.map(async x=>env.PILOT_DECISIONS.get(x.name,'json')))).filter(Boolean);
   return respond(req,{ok:true,mode:'direct',items,has_more:!listing.list_complete});
  }
  if(route==='/api/decision'&&req.method==='GET'){
   const p=url.searchParams.get('project'),id=url.searchParams.get('event_id');
   if(!sane(p,id))return respond(req,{ok:false,error:'invalid_lookup'},400);
   const row=await env.PILOT_DECISIONS.get(recordKey(p,id),'json')||
     await env.PILOT_DECISIONS.get(p+':'+id,'json');
   return respond(req,{ok:true,found:Boolean(row),item:row||null});
  }
  if(route==='/api/decision'&&req.method==='POST'){
   if(!(req.headers.get('Content-Type')||'').toLowerCase().startsWith('application/json'))
    return respond(req,{ok:false,error:'json_required'},415);
   let b;try{b=await req.json()}catch{return respond(req,{ok:false,error:'bad_json'},400)}
   const p=String(b.project||''),id=String(b.event_id||''),decision=String(b.decision||'');
   if(!sane(p,id)||!ACTIONS.has(decision)||!REQUEST.test(String(b.request_id||'')))
    return respond(req,{ok:false,error:'invalid_decision'},400);
   const synthetic=/^pilot-(?:mobile|check|install|auth|diagnostic)-/i.test(id);
   const live=env.ACTION_MODE==='github_dispatch'&&Boolean(env.GH_DISPATCH_TOKEN)&&['deleted','discard','prepare','rework'].includes(decision)&&!synthetic;
   if(live&&(!Number.isInteger(b.revision)||b.revision<0))
    return respond(req,{ok:false,error:'revision_required'},400);
   const key=recordKey(p,id);
   const existing=await env.PILOT_DECISIONS.get(key,'json');
   if(existing){
    // KV is an outbound-dispatch cache, not the authoritative editorial ledger.
    // A past trial/failed/in-flight action must never permanently lock a new
    // explicit LIVE user action. GitHub validates current state and revision.
    if(!live&&existing.decision!==decision)
     return respond(req,{ok:false,error:'already_decided',decision:existing.decision},409);
    const sameRevision=Number.isInteger(existing.revision)&&existing.revision===b.revision;
    if(existing.decision===decision&&existing.routed===true&&live&&sameRevision){
     const last=Date.parse(existing.received_at||'')||0;
     if(Date.now()-last<3*60*1000)
      return respond(req,{ok:true,stored:true,duplicate:true,state:'submitted',routed:true},200);
     // Retry after 3m is safe: GitHub checks revision and terminal status.
    }else if(!live&&existing.decision===decision)
     return respond(req,{ok:true,stored:true,duplicate:true,state:'pilot_only',routed:false},200);
   }
   const row={project:p,event_id:id,decision,request_id:String(b.request_id),
    received_at:new Date().toISOString(),mode:live?'direct':'pilot_only',
    state:'pilot_only',routed:false,revision:Number.isInteger(b.revision)?b.revision:null,trend_name:String(b.trend_name||'').slice(0,180),trend_rank:Number(b.trend_rank||0)};
   if(live){
    try{Object.assign(row,await dispatch(env,row))}
    catch(e){return respond(req,{ok:false,error:'github_dispatch_failed',details:String(e.message||e).slice(0,65)},502)}
   }
   await env.PILOT_DECISIONS.put(key,JSON.stringify(row));
   return respond(req,{ok:true,stored:true,duplicate:false,state:row.state,routed:row.routed},201);
  }
  return respond(req,{ok:false,error:'not_found'},404);
 }
};