// TTActualidad isolated decision inbox for a Cloudflare Worker pilot.
// Bind a fresh KV namespace as PILOT_DECISIONS and a secret as PILOT_TOKEN.
// No production endpoints, no GitHub write, no Telegram, no auto-trigger.
const ORIGIN='https://fabricelop.github.io';
function headers(request){
 const origin=request.headers.get('Origin')||'';
 return {'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store','Access-Control-Allow-Origin':origin===ORIGIN?ORIGIN:'null','Vary':'Origin','Access-Control-Allow-Headers':'Authorization, Content-Type','Access-Control-Allow-Methods':'GET, POST, OPTIONS'}
}
function reply(body,status,request){return new Response(JSON.stringify(body),{status,headers:headers(request)})}
function authorized(request,env){
 const header=request.headers.get('Authorization')||'';
 const expected='Bearer '+String(env.PILOT_TOKEN||'');
 return Boolean(env.PILOT_TOKEN)&&header.length===expected.length&&header===expected
}
export default {
 async fetch(request,env){
  if(request.method==='OPTIONS')return new Response('',{status:204,headers:headers(request)});
  if(new URL(request.url).pathname==='/health')return reply({ok:true,kind:'isolated-ttactualidad-pilot',production_connected:false},200,request);
  if(!authorized(request,env))return reply({ok:false,error:'unauthorized'},401,request);
  if(!env.PILOT_DECISIONS)return reply({ok:false,error:'pilot_KV_not_bound'},503,request);
  const route=new URL(request.url).pathname;
  // Targeted lookup for a recently written decision. KV list() can be stale.
  if(route==='/api/decision'&&request.method==='GET'){
   const u=new URL(request.url);
   const project=u.searchParams.get('project')||'';
   const id=u.searchParams.get('event_id')||'';
   if(!['ttittulares','ttendencias'].includes(project)||!(/^[A-Za-z0-9:_-]{3,128}$/.test(id)))
     return reply({ok:false,error:'invalid_lookup'},400,request);
   const item=await env.PILOT_DECISIONS.get(project+':'+id,'json');
   return reply({ok:true,found:!!item,item:item||null,production_connected:false},200,request);
  }
  if(route==='/api/decision'&&request.method==='POST'){
   let b;try{b=await request.json()}catch{return reply({ok:false,error:'bad_json'},400,request)}
   if(!['ttittulares','ttendencias'].includes(b.project)||!['prepare','discard'].includes(b.decision)||!(/^[A-Za-z0-9:_-]{3,128}$/.test(String(b.event_id||'')))||!(/^[A-Za-z0-9-]{12,80}$/.test(String(b.request_id||''))))return reply({ok:false,error:'invalid_decision'},400,request);
   const key=b.project+':'+b.event_id;
   const previous=await env.PILOT_DECISIONS.get(key,'json');
   if(previous)return reply({ok:true,stored:true,duplicate:true,decision:previous.decision,production_connected:false},200,request);
   const row={project:b.project,event_id:b.event_id,decision:b.decision,request_id:b.request_id,received_at:new Date().toISOString(),mode:'pilot_only'};
   await env.PILOT_DECISIONS.put(key,JSON.stringify(row));
   return reply({ok:true,stored:true,duplicate:false,production_connected:false},201,request);
  }
  if(route==='/api/decisions'&&request.method==='GET'){
   const index=await env.PILOT_DECISIONS.list({limit:100});
   const entries=await Promise.all(index.keys.map(async k=>await env.PILOT_DECISIONS.get(k.name,'json')));
   return reply({ok:true,mode:'pilot_only',items:entries.filter(Boolean),has_more:!index.list_complete},200,request);
  }
  return reply({ok:false,error:'not_found'},404,request)
 }
};
