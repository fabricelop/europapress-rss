// TTActualidad pilot. One event per human action, no scheduled requests.
// Read-only GitHub pages app; decisions stay isolated unless an explicit
// GitHub dispatch token is configured by the owner in a future cutover.
const ORIGIN='https://fabricelop.github.io';
const PROJECTS=new Set(['ttittulares','ttendencias']);
const ACTIONS=new Set(['prepare','discard','deleted','published']);
const ID=/^[A-Za-z0-9:_-]{3,128}$/;
const REQUEST=/^[A-Za-z0-9-]{12,80}$/;
function cors(req){
 const origin=req.headers.get('Origin')||'';
 return {'Content-Type':'application/json; charset=utf-8',
  'Cache-Control':'no-store','X-Content-Type-Options':'nosniff',
  'Access-Control-Allow-Origin':origin===ORIGIN?ORIGIN:'null',
  'Vary':'Origin','Access-Control-Allow-Headers':'Authorization, Content-Type',
  'Access-Control-Allow-Methods':'GET, POST, OPTIONS'};
}
function respond(req,data,status=200){return new Response(JSON.stringify(data),{status,headers:cors(req)})}
function access(req,env){
 const auth=req.headers.get('Authorization')||'';
 const expected='Bearer '+String(env.PILOT_TOKEN||'');
 return Boolean(env.PILOT_TOKEN)&&auth.length===expected.length&&auth===expected;
}
function sane(p,id){return PROJECTS.has(p)&&ID.test(String(id||''))}
function recordKey(project,id){return 'action:'+project+':'+id}
async function dispatch(env,row){
 // The pilot has NO production integration until both variables are configured.
 if(env.ACTION_MODE!=='github_dispatch'||!env.GH_DISPATCH_TOKEN)
  return {state:'pilot_only',routed:false};
 const result=await fetch('https://api.github.com/repos/fabricelop/europapress-rss/dispatches',{
  method:'POST',
  headers:{'Authorization':'Bearer '+env.GH_DISPATCH_TOKEN,'Accept':'application/vnd.github+json',
   'X-GitHub-Api-Version':'2022-11-28','User-Agent':'TTActualidad-pilot-v2',
   'Content-Type':'application/json'},
  body:JSON.stringify({event_type:'ttactualidad_action_v1',
   client_payload:{project:row.project,event_id:row.event_id,decision:row.decision,
    request_id:row.request_id,received_at:row.received_at,revision:row.revision}}),
 });
 if(result.status!==204)throw new Error('dispatch_http_'+result.status);
 return {state:'submitted',routed:true};
}
export default {
 async fetch(req,env){
  if(req.method==='OPTIONS')return new Response('',{status:204,headers:cors(req)});
  const url=new URL(req.url),route=url.pathname;
  if(route==='/health'&&req.method==='GET')
   return respond(req,{ok:true,kind:'isolated-ttactualidad-pilot',production_connected:env.ACTION_MODE==='github_dispatch'&&Boolean(env.GH_DISPATCH_TOKEN),
    architecture:'on_demand_no_polling'});
  // Public static pilot UI, icons and manifest. API routes stay private.
  // Without this, Wrangler uploads assets but "/" returns unauthorized.
  if(req.method==='GET'&&!route.startsWith('/api/')&&env.ASSETS)
   return env.ASSETS.fetch(req);
  if(!access(req,env))return respond(req,{ok:false,error:'unauthorized'},401);
  if(!env.PILOT_DECISIONS)return respond(req,{ok:false,error:'pilot_KV_not_bound'},503);
  if(route==='/api/decisions'&&req.method==='GET'){
   const listing=await env.PILOT_DECISIONS.list({limit:100,prefix:'action:'});
   const items=(await Promise.all(listing.keys.map(async x=>env.PILOT_DECISIONS.get(x.name,'json')))).filter(Boolean);
   return respond(req,{ok:true,mode:'pilot_only',items,has_more:!listing.list_complete,
    production_connected:env.ACTION_MODE==='github_dispatch'&&Boolean(env.GH_DISPATCH_TOKEN)});
  }
  if(route==='/api/decision'&&req.method==='GET'){
   const p=url.searchParams.get('project'),id=url.searchParams.get('event_id');
   if(!sane(p,id))return respond(req,{ok:false,error:'invalid_lookup'},400);
   const row=await env.PILOT_DECISIONS.get(recordKey(p,id),'json')||
     await env.PILOT_DECISIONS.get(p+':'+id,'json'); // legacy pilot test rows
   return respond(req,{ok:true,found:Boolean(row),item:row||null,production_connected:false});
  }
  if(route==='/api/decision'&&req.method==='POST'){
   let b;try{b=await req.json()}catch{return respond(req,{ok:false,error:'bad_json'},400)}
   const p=String(b.project||''),id=String(b.event_id||''),decision=String(b.decision||'');
   if(!sane(p,id)||!ACTIONS.has(decision)||!REQUEST.test(String(b.request_id||'')))
    return respond(req,{ok:false,error:'invalid_decision'},400);
   // Only owner-selected news may be dispatched; synthetic test events
   // will always remain isolated, even after future dispatch activation.
   const synthetic=/^pilot-(?:mobile|check|install|auth|diagnostic)-/i.test(id);
   const k=recordKey(p,id);
   const existing=await env.PILOT_DECISIONS.get(k,'json');
   if(existing){
    if(existing.decision!==decision)return respond(req,{ok:false,error:'already_decided',decision:existing.decision},409);
    return respond(req,{ok:true,stored:true,duplicate:true,state:existing.state,
     routed:existing.routed===true,production_connected:existing.routed===true},200);
   }
   const row={project:p,event_id:id,decision,request_id:String(b.request_id),
    received_at:new Date().toISOString(),mode:'pilot_only',state:'pilot_only',
    routed:false,revision:Number.isInteger(b.revision)?b.revision:null};
   // Acknowledgment from KV is NOT confirmation of real deletion.
   // On dispatch failure preserve an accurate receipt, not a fake success.
   if(!synthetic){
    try{Object.assign(row,await dispatch(env,row))}
    catch(e){row.state='dispatch_failed';row.error=String(e.message||e).slice(0,65)}
   }
   await env.PILOT_DECISIONS.put(k,JSON.stringify(row));
   return respond(req,{ok:true,stored:true,duplicate:false,state:row.state,
    routed:row.routed,production_connected:row.routed},201);
  }
  return respond(req,{ok:false,error:'not_found'},404);
 }
};