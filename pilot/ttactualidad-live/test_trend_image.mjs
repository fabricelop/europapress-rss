// Worker regression: never equate ChatGPT launch with image publication.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const source=readFileSync('pilot/ttactualidad-live/worker.js','utf8');
const {default:app}=await import('data:text/javascript;base64,'+Buffer.from(source).toString('base64'));
const root='https://ttactualidad-decisions-pilot.fabricelop.workers.dev';
const env={PILOT_TOKEN:'secret-test-session',TTENDENCIAS_CONTROL_TOKEN:'upstream-only-secret'};
const make=(path,method='GET',body,auth=true,origin=root)=>new Request(root+path,{
 method,headers:{...(auth?{'Authorization':'Bearer secret-test-session'}:{}),'Origin':origin,
  ...(body?{'Content-Type':'application/json'}:{})},...(body?{body:JSON.stringify(body)}:{})
});
const original=globalThis.fetch;
const calls=[];
globalThis.fetch=async(url,options)=>{
 calls.push({url:String(url),options});
 if(String(url).includes('view=image-job'))return new Response(JSON.stringify({
  ok:true,target_id:'trend-123',revision:3,command_id:'tr-img-current',
  status:'LAUNCHED',phase:'pc_launched',updated_at:'2026-10-31T08:00:00Z',
  web_image:{stage:'waiting',reason:'relay_version_ECONNREFUSED'},
  pc_upload_secret_hash:'never-leak',upload_secret:'never-leak'
 }),{status:200,headers:{'Content-Type':'application/json'}});
 return new Response(JSON.stringify({ok:true,command_id:'tr-img-requested',requested_at:'2026-10-31T08:05:00Z'}),
   {status:200,headers:{'Content-Type':'application/json'}});
};
try{
 assert.equal((await app.fetch(make('/api/trend-image?target_id=trend-123', 'GET',null,false),env)).status,401);
 assert.equal((await app.fetch(make('/api/trend-image',{target_id:'trend-123'}),env)).status,404);
 const invalid=await app.fetch(make('/api/trend-image','POST',{target_id:'../../etc',revision:0}),env);
 assert.equal(invalid.status,400);
 const badRevision=await app.fetch(make('/api/trend-image','POST',{target_id:'trend-123',revision:-1}),env);
 assert.equal(badRevision.status,400);
 const crossOrigin=await app.fetch(make('/api/trend-image','POST',{target_id:'trend-123',revision:3},true,'https://evil.invalid'),env);
 // Bearer clients intentionally use the pre-existing token auth; cookie clients
 // enforce same-origin. Do not bypass authentication with an arbitrary origin.
 assert.equal(crossOrigin.status,202);
 const absent=await app.fetch(make('/api/trend-image','POST',{target_id:'trend-123',revision:3}),{PILOT_TOKEN:'secret-test-session'});
 assert.equal(absent.status,503);
 assert.equal((await absent.json()).error,'image_bridge_not_configured');
 const status=await app.fetch(make('/api/trend-image?target_id=trend-123'),env);
 assert.equal(status.status,200);
 const state=await status.json();
 assert.equal(state.status,'LAUNCHED');
 assert.equal(state.web_image_stage,'waiting');
 assert.equal(state.web_image_reason,'relay_version_ECONNREFUSED');
 assert.equal(JSON.stringify(state).includes('never-leak'),false);
 const submit=await app.fetch(make('/api/trend-image','POST',{target_id:'trend-123',revision:3}),env);
 assert.equal(submit.status,202);
 assert.equal((await submit.json()).state,'REQUESTED');
 const upstream=calls.at(-1);
 assert.equal(new URL(upstream.url).origin,'https://tt-control.fabricelop.workers.dev');
 assert.equal(upstream.options.headers.Authorization,'Bearer upstream-only-secret');
 assert.deepEqual(JSON.parse(upstream.options.body),{task:'images',target_id:'trend-123',id:'trend-123',revision:3});
 const html=readFileSync('pilot/ttactualidad-live/index.html','utf8');
 assert(html.includes("btn(active?'Comprobar imagen'"));
 assert(html.includes("matchingAiImage(x)?.url"));
 assert(html.includes("imageStillPending(existing)"));
 assert(html.includes("/api/trend-image"));
}finally{globalThis.fetch=original}
console.log('TTActualidad: authenticated image-run proxy and card wiring OK');
