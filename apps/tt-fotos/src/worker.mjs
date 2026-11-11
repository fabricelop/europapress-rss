// TT Fotos independent Worker. No runtime requests to the old Site or iPhone.
import {createTTFotosApi} from '../../../site-patches/ttactualidad-fotos-review/cloud-v1/api.mjs';
import {createGithubJobProvider} from '../../../site-patches/ttactualidad-fotos-review/cloud-v1/job-provider.mjs';
import {authenticateAccess} from './access.mjs';
import {searchEditorial,resolveEditorialCommand} from './editorial-search.mjs';
const security={
  'Cache-Control':'private, no-store',
  'X-Content-Type-Options':'nosniff',
  'Referrer-Policy':'no-referrer',
  'X-Frame-Options':'DENY',
  'Cross-Origin-Resource-Policy':'same-origin'
};
const plain=(status,msg)=>new Response(msg,{status,headers:{...security,'Content-Type':'text/plain; charset=utf-8'}});
export function createWorker({auth=authenticateAccess,apiFactory=createTTFotosApi,fetcher=fetch}={}){
  return {async fetch(request,env){
    const path=new URL(request.url).pathname;
    // Never accidentally expose /admin, internals, or a catalog of files.
    if(!['GET','HEAD','POST'].includes(request.method))return plain(405,'Method not allowed');
    if(!env.FOTOS_DB||!env.FOTOS_R2||!env.ASSETS)return plain(503,'TT Fotos storage not configured');
    let editor;
    try{editor=await auth(request,env)}catch{return plain(503,'TT Fotos authentication unavailable')}
    if(!editor?.isEditor)return plain(403,'Editor authentication required');
    if(request.method==='GET'&&path==='/api/tt-fotos/v1/editorial-search'){
      const q=new URL(request.url).searchParams.get('q')||'';
      const results=await searchEditorial(q,fetcher);
      return new Response(JSON.stringify({ok:true,items:results,coverage:'current_prepared_and_top30_only'}),{headers:{...security,'Content-Type':'application/json; charset=utf-8'}});
    }
    if(request.method==='GET'&&path==='/api/tt-fotos/v1/editorial-command'){
      const p=new URL(request.url).searchParams;
      const candidate=await resolveEditorialCommand({project:p.get('project'),editorialId:p.get('id'),revision:Number(p.get('revision'))},fetcher);
      return candidate?new Response(JSON.stringify({ok:true,candidate}),{headers:{...security,'Content-Type':'application/json; charset=utf-8'}}):plain(404,'Verified editorial job unavailable');
    }
    if(path.startsWith('/api/tt-fotos/v1/')){
      const api=apiFactory({db:env.FOTOS_DB,r2:env.FOTOS_R2,authenticate:async()=>editor,jobProvider:createGithubJobProvider(fetcher)});
      const res=await api(request);
      if(!res)return plain(404,'Not found');
      const headers=new Headers(res.headers);
      Object.entries(security).forEach(([k,v])=>headers.set(k,v));
      return new Response(res.body,{status:res.status,headers});
    }
    if(request.method!=='GET'&&request.method!=='HEAD')return plain(405,'Method not allowed');
    if(!['/','/fotos','/fotos/','/index.html'].includes(path))return plain(404,'Not found');
    const url=new URL('/index.html',request.url);
    const upstream=await env.ASSETS.fetch(new Request(url,request));
    if(!upstream.ok)return plain(503,'TT Fotos interface unavailable');
    const headers=new Headers(upstream.headers);
    Object.entries(security).forEach(([k,v])=>headers.set(k,v));
    headers.set('Content-Security-Policy',"default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' blob:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'");
    return new Response(upstream.body,{status:upstream.status,headers});
  }};
}
export default createWorker();