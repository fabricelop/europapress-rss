import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';

const ORIGIN='https://private.test';
const id='trv2-aabbccddeeff001122334455';
const secret={AUTH_PASSWORD:'test-password-more-than-16',SESSION_SECRET:'test-long-session-secret-for-the-private-worker'};
const ranking={project:'ttactualidad-v2',country:'ES',count:1,items:[{trend_id:id,name:'Tendencia',rank:1,status:'explicada',revision:2,image_available:false,explanation:'Esta es la explicación editorial',entered_top30_at:'2026-11-16T09:00:00Z'}]};
const realFetch=globalThis.fetch;
globalThis.fetch=async url=>String(url).includes('web-top30.json')?Response.json(ranking):realFetch(url);

function db(){
 const tickets=new Map();
 return {tickets,prepare(sql){
  let args=[];
  return {
   bind(...values){args=values;return this},
   async run(){
    if(sql.startsWith('INSERT INTO manual_image_tickets'))tickets.set(args[0],{trend_id:args[1],revision:args[2],sha256:args[3],mime:args[4],bytes:args[5],expires_at_ms:args[6],redeemed_at_ms:null});
    else assert.match(sql,/^CREATE TABLE/);
   },
   async first(){
    if(sql.startsWith('UPDATE manual_image_tickets')){
     const row=tickets.get(args[1]);if(!row||row.redeemed_at_ms!==null||row.expires_at_ms<=args[2])return null;
     row.redeemed_at_ms=args[0];return row;
    }
    throw Error('no radar');
   },
   async all(){
    if(sql.includes('FROM re_requests')||sql.includes('FROM re_x_context')||sql.includes('FROM incident_rex_requests')||sql.includes('FROM image_suppressions')||sql.includes('FROM public_image_prefs'))return {results:[]};
    throw Error('no radar');
   }
  };
 }};
}
async function session(env){const r=await worker.fetch(new Request(ORIGIN+'/api/login',{method:'POST',headers:{origin:ORIGIN,'x-ttv2-action':'1','content-type':'application/json'},body:JSON.stringify({password:secret.AUTH_PASSWORD})}),env);assert.equal(r.status,200);return r.headers.get('set-cookie').split(';')[0]}
test('manual paste tickets are authenticated, bound to one revision, short-lived and redeemable once',async()=>{
 const env={...secret,MARKS_DB:db()};const cookie=await session(env);
 const payload={trend_id:id,revision:2,sha256:'e'.repeat(64),mime:'image/png',bytes:450000};
 const req=(key,origin=ORIGIN)=>new Request(ORIGIN+'/api/manual-image-ticket',{method:'POST',headers:{cookie,origin,'x-ttv2-action':'1','content-type':'application/json'},body:JSON.stringify({...payload,...key})});
 assert.equal((await worker.fetch(req({},'https://evil.invalid'),env)).status,405);
 assert.equal((await worker.fetch(req({revision:3}),env)).status,409);
 const response=await worker.fetch(req({}),env);assert.equal(response.status,200,await response.clone().text());
 const {ticket,expires_at_ms}=await response.json();assert.ok(expires_at_ms<=Date.now()+300000);
 assert.equal(env.MARKS_DB.tickets.size,1);
 const redeem=()=>worker.fetch(new Request(ORIGIN+'/api/manual-image-ticket/redeem',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({ticket})}),env);
 const first=await redeem();assert.equal(first.status,200);assert.equal((await first.json()).sha256,payload.sha256);
 assert.equal((await redeem()).status,409);
 assert.equal((await worker.fetch(new Request(ORIGIN+'/api/manual-image-ticket/redeem',{method:'POST',body:JSON.stringify({ticket:'x'.repeat(43)})}),env)).status,409);
});
