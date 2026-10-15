// TTActualidad PC pilot consumer. DRY RUN ONLY: no production writes/actions.
// Requires Node >=20 and TT_PILOT_TOKEN in process environment.
// No service registration, Chrome operations, Telegram, GitHub writes or launches.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import assert from 'node:assert/strict';

const PILOT='https://ttactualidad-decisions-pilot.fabricelop.workers.dev';
const RAW='https://raw.githubusercontent.com/fabricelop/europapress-rss/main/';
const STATE=path.join(process.env.LOCALAPPDATA || path.join(os.homedir(),'AppData','Local'),
  'TT_Recuperacion','TTActualidadPilot','pc-dryrun-state.json');
const WAIT=10*60_000, FRESH=15*60_000, INTERVAL=60_000;
const validKey=x=>typeof x==='string' && /^[a-z0-9:_-]{3,128}$/i.test(x);
function validProject(x){return x==='ttittulares'||x==='ttendencias'}
function iso(ms){return new Date(ms).toISOString()}
function emptyState(){return {version:1,manual:{},seen:{},automatic:{}}}
function key(p,id){return p+':'+id}
function reconcile(previous,decisions,candidates,now){
 const state=structuredClone(previous || emptyState()), log=[];
 for(const row of decisions){
  if(!row||!validProject(row.project)||!validKey(row.event_id)||
     !['prepare','discard'].includes(row.decision)||row.mode!=='pilot_only')continue;
  const id=key(row.project,row.event_id);
  const existing=state.manual[id];
  if(!existing){
   state.manual[id]={decision:row.decision,request_id:String(row.request_id||''),at:String(row.received_at||''),source:'mobile'};
   log.push({type:'MANUAL_SIMULADA',project:row.project,id:row.event_id,decision:row.decision});
  }else if(existing.decision!==row.decision){
   // An immutable KV key should never have conflicting decisions: fail closed.
   throw Error('Conflicto de decisiones para '+id);
  }
 }
 const active=new Set();
 for(const row of candidates){
  if(!row||!validProject(row.project)||!validKey(row.event_id))continue;
  const id=key(row.project,row.event_id);
  active.add(id);
  if(!state.seen[id]){
   state.seen[id]={firstObservedAt:iso(now),source:String(row.source||'unknown')};
   log.push({type:'VISTA_EN_SIMULACION',project:row.project,id:row.event_id});
  }
  if(state.manual[id]||state.automatic[id])continue;
  const observed=Date.parse(state.seen[id].firstObservedAt);
  if(Number.isFinite(observed)&&now-observed>=WAIT){
   state.automatic[id]={decision:'prepare',at:iso(now),reason:'10m_without_mobile_decision',dry_run:true};
   log.push({type:'AUTO_ELABORAR_SIMULADO',project:row.project,id:row.event_id});
  }
 }
 // Only currently live candidates can produce a timeout. Observations stay
 // in the local ledger for deduplication after restarts, never in production.
 state.updatedAt=iso(now);
 const counts={manual:Object.keys(state.manual).length,auto:Object.keys(state.automatic).length,
    active:active.size,waiting:[...active].filter(id=>!state.manual[id]&&!state.automatic[id]).length};
 return {state,log,counts};
}
function runTests(){
 const start=Date.parse('2026-10-16T08:00:00Z');
 const p={project:'ttittulares',event_id:'abc123',source:'processing_items'};
 let r=reconcile(emptyState(),[],[p],start);
 assert.equal(r.counts.waiting,1);
 assert.equal(r.counts.auto,0);
 r=reconcile(r.state,[],[p],start+599_000);
 assert.equal(r.counts.auto,0);
 r=reconcile(r.state,[],[p],start+600_000);
 assert.equal(r.counts.auto,1);
 assert.equal(r.log.filter(x=>x.type==='AUTO_ELABORAR_SIMULADO').length,1);
 r=reconcile(r.state,[],[p],start+1200_000);
 assert.equal(r.counts.auto,1);
 assert.equal(r.log.length,0);
 const dec={project:'ttittulares',event_id:'x123',decision:'discard',mode:'pilot_only',
            request_id:'test-id',received_at:iso(start)};
 let r2=reconcile(emptyState(),[dec],[{...p,event_id:'x123'}],start);
 r2=reconcile(r2.state,[dec],[{...p,event_id:'x123'}],start+700_000);
 assert.equal(r2.counts.auto,0);
 assert.equal(r2.counts.manual,1);
 assert.equal(r2.log.length,0);
 const r3=reconcile(emptyState(),[],[p],start);
 const r4=reconcile(r3.state,[],[],start+600_001);
 assert.equal(r4.counts.auto,0);
 const r5=reconcile(emptyState(),[],[p,{project:'ttendencias',event_id:'abc123'}],start);
 assert.equal(r5.counts.active,2);
 console.log('AUTOTEST OK: 10 minutos, descarte, deduplicacion, desaparicion y separacion por proyecto');
}
async function jsonFetch(url,headers={}){
 const r=await fetch(url,{headers,signal:AbortSignal.timeout(25000),cache:'no-store'});
 if(!r.ok)throw Error('HTTP '+r.status+' leyendo '+new URL(url).pathname);
 return r.json();
}
async function snapshots(now){
 const [tti,tr]=await Promise.all([
  jsonFetch(RAW+'ttittulares/status.json?t='+now),
  jsonFetch(RAW+'trends/editorial-queue.json?t='+now)
 ]);
 const candidates=[],warnings=[];
 const fresh=(s,stamp,label)=>{
  const t=Date.parse(stamp||'');
  if(!Number.isFinite(t)||t>now+90_000||now-t>FRESH){
   warnings.push(label+' desactualizado: temporizador suspendido');return false;
  }
  return true;
 };
 if(fresh(tti,tti.updated_at,'TTiTTulares')){
  for(const row of Array.isArray(tti.processing_items)?tti.processing_items:[]){
   const id=String(row.event_id||'');
   if(validKey(id))candidates.push({project:'ttittulares',event_id:id,source:'processing_items'});
  }
 }
 if(fresh(tr,tr.updated_at,'TTendencias')){
  for(const row of Array.isArray(tr.items)?tr.items:[]){
   if(!['preparing','update'].includes(String(row.status||'').toLowerCase()))continue;
   const id=String(row.id||'');
   if(validKey(id))candidates.push({project:'ttendencias',event_id:id,source:'editorial-queue'});
  }
 }
 return {candidates,warnings};
}
async function inbox(token){
 const res=await jsonFetch(PILOT+'/api/decisions',{Authorization:'Bearer '+token});
 if(!res.ok||res.mode!=='pilot_only'||!Array.isArray(res.items)){
  throw Error('La bandeja recibida no es el piloto aislado');
 }
 // IMPORTANT: Worker lists max 100 KV keys. Never silently skip older decisions.
 if(res.has_more)throw Error('Buzon de prueba supera 100 entradas: falta paginacion. Detenido sin guardar.');
 return res.items;
}
function readState(){
 if(!fs.existsSync(STATE))return emptyState();
 const parsed=JSON.parse(fs.readFileSync(STATE,'utf8'));
 if(parsed.version!==1||typeof parsed.manual!=='object'||typeof parsed.seen!=='object'||
    typeof parsed.automatic!=='object')throw Error('Estado local incompatible; no se sobrescribe');
 return parsed;
}
function saveState(state){
 fs.mkdirSync(path.dirname(STATE),{recursive:true});
 const temp=STATE+'.'+process.pid+'.tmp';
 fs.writeFileSync(temp,JSON.stringify(state,null,2),'utf8');
 fs.renameSync(temp,STATE);
}
async function runCycle(){
 const token=process.env.TT_PILOT_TOKEN||'';
 if(!/^[A-Za-z0-9_-]{32,100}$/.test(token))throw Error('Falta clave del Worker piloto en el entorno');
 const now=Date.now();
 const [rows,source]=await Promise.all([inbox(token),snapshots(now)]);
 const out=reconcile(readState(),rows,source.candidates,now);
 saveState(out.state);
 for(const event of out.log){
  console.log('DRYRUN '+event.type+' '+event.project+' '+event.id+(event.decision?' -> '+event.decision:''));
 }
 for(const warning of source.warnings)console.log('AVISO '+warning);
 console.log('DRYRUN RESUMEN manual='+out.counts.manual+' automaticas='+out.counts.auto+
   ' pendientes='+out.counts.waiting+' activas='+out.counts.active);
 console.log('SIN ACCIONES REALES. Estado local: '+STATE);
}
async function main(){
 if(process.argv.includes('--self-test')){runTests();return}
 const mode=process.argv.includes('--watch')?'watch':'once';
 console.log('TTActualidad PC - SIMULACION AISLADA. Modo '+mode);
 if(mode==='once'){await runCycle();return}
 // Deliberately no scheduled task or daemon install. Ctrl+C stops immediately.
 while(true){
  try{await runCycle()}catch(e){console.error('DRYRUN ERROR '+e.message)}
  await new Promise(resolve=>setTimeout(resolve,INTERVAL));
 }
}
main().catch(e=>{console.error('DRYRUN ERROR '+e.message);process.exitCode=1});
