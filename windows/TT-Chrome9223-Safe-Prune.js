// TT Chrome 9223 conservative tab cleanup, dry-run by default.
'use strict';
const fs=require('node:fs');
const path=require('node:path');
const os=require('node:os');
const cp=require('node:child_process');
const BASE='http://127.0.0.1:9223';
const DIR='C:\\TTiTTulares';
const APPLY=process.argv.includes('--apply');
const MIN_AGE=30;
const MAX_CLOSE=8;
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
function tabPin(file){
  try{return String(JSON.parse(fs.readFileSync(path.join(DIR,file),'utf8')).target_id||'')}
  catch{return ''}
}
function homeUrl(u) {
  try {const x=new URL(u);return x.hostname==='chatgpt.com'&&x.pathname==='/'&&!x.search&&!x.hash}
  catch{return false}
}
async function listTargets(){
  const r=await fetch(BASE+'/json/list',{cache:'no-store',signal:AbortSignal.timeout(6500)});
  if(!r.ok)throw Error('CDP HTTP '+r.status);
  const j=await r.json();
  if(!Array.isArray(j))throw Error('Invalid Chrome CDP response');
  return j;
}
async function inspect(t){
  if(!t.webSocketDebuggerUrl||typeof WebSocket!=='function')return {unknown:'CDP WebSocket unavailable'};
  return await new Promise(resolve=>{
    let ws,done=false;
    const timer=setTimeout(()=>finish({unknown:'CDP timeout'}),4500);
    function finish(v){if(done)return;done=true;clearTimeout(timer);try{ws&&ws.close()}catch{}resolve(v)}
    const expr=`(()=>{const buttons=[...document.querySelectorAll('button')];const stop=buttons.some(b=>/^(stop|detener|parar|cancelar)(\\b|\\s)/i.test(String(b.getAttribute('aria-label')||b.getAttribute('title')||'')))||!!document.querySelector('button[data-testid="stop-button"]');const main=document.querySelector('main');const txt=String((main&&main.innerText)||'').slice(-6000);return {url:location.href,ready:document.readyState,age:Math.floor((Date.now()-performance.timeOrigin)/60000),busy:stop||/(creating image|generating image|generando imagen|creando imagen)/i.test(txt)}})()`;
    try{
      ws=new WebSocket(t.webSocketDebuggerUrl);
      ws.addEventListener('open',()=>{try{ws.send(JSON.stringify({id:17,method:'Runtime.evaluate',params:{expression:expr,returnByValue:true}}))}catch(e){finish({unknown:String(e.message||e)})}},{once:true});
      ws.addEventListener('message',e=>{try{const d=JSON.parse(String(e.data));if(d.id!==17)return;const val=d.result?.result?.value;if(!val||d.error)finish({unknown:String(d.error?.message||'empty')});else finish(val)}catch(e){finish({unknown:String(e.message||e)})}});
      ws.addEventListener('error',()=>finish({unknown:'CDP socket error'}));
      ws.addEventListener('close',()=>finish({unknown:'CDP socket closed'}));
    }catch(e){finish({unknown:String(e.message||e)})}
  });
}
function checkBusy(){
  // Fail closed if the Windows process inventory cannot be inspected.
  const ps=`$q=@(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $_.Name -in @('node.exe','powershell.exe','pwsh.exe') -and [string]$_.CommandLine -match '(TTiTTulares|TTendencias)ImageBridge[.]js|[\\\\/]Ejecutar[.]js' }); Write-Output $q.Count`;
  const r=cp.spawnSync('powershell.exe',['-NoProfile','-NonInteractive','-Command',ps],{encoding:'utf8',timeout:14000,windowsHide:true});
  if(r.error||r.status!==0)throw Error('No se puede verificar si hay trabajos activos');
  const n=Number(String(r.stdout||'').trim());
  if(!Number.isInteger(n))throw Error('Respuesta no válida de comprobación de trabajos');
  if(n>0)throw Error('Hay '+n+' bridge(s)/lanzador(es) activo(s); posponiendo limpieza');
}
(async()=>{
  checkBusy();
  const tt=tabPin('ttittulares-image-tab.json');
  const tr=tabPin('ttendencias-image-tab.json');
  if(!tt||!tr||tt===tr)throw Error('Pestañas fijas TT no identificadas de forma segura');
  const all=await listTargets();
  if(!all.some(t=>t.id===tt&&t.type==='page')||!all.some(t=>t.id===tr&&t.type==='page'))throw Error('Alguna pestaña TT fija está ausente; posponiendo limpieza');
  const pages=all.filter(t=>t.type==='page');
  const homes=pages.filter(t=>homeUrl(t.url)&&t.id!==tt&&t.id!==tr);
  const checks=[];
  for(const t of homes){
    const result=await inspect(t);
    checks.push({id:t.id,result});
  }
  const unknown=checks.filter(x=>x.result.unknown).length;
  // No cleanup at all if any home candidate cannot be inspected.
  if(unknown)throw Error('Hay '+unknown+' pestañas candidatas sin estado verificable; no se cerrará ninguna');
  const qualified=checks.filter(x=>homeUrl(x.result.url)&&x.result.ready==='complete'&&!x.result.busy&&x.result.age>=MIN_AGE)
    .sort((a,b)=>b.result.age-a.result.age);
  console.log('\n=== TT CHROME 9223: LIMPIEZA CONSERVADORA ===');
  console.log('Modo:',APPLY?'APLICAR':'SOLO SIMULACION');
  console.log('Pestañas totales:',pages.length);
  console.log('Pestañas home no fijas:',homes.length);
  console.log('Candidatas seguras por criterio (>='+MIN_AGE+' min en home):',qualified.length);
  console.log('Límite por pasada:',MAX_CLOSE);
  const toClose=qualified.slice(0,MAX_CLOSE);
  for(const c of toClose)console.log('  '+String(c.id).slice(0,14)+'  '+c.result.age+' min');
  if(!APPLY){
    console.log('NINGUNA pestaña cerrada. Para aplicar usa --apply; se volverán a verificar.');
    return;
  }
  let closed=0;
  const log=[];
  for(const c of toClose){
    checkBusy();
    const now=await listTargets();
    const cur=now.find(t=>t.id===c.id&&t.type==='page');
    if(!cur||!homeUrl(cur.url)||cur.id===tt||cur.id===tr)continue;
    const state=await inspect(cur);
    if(state.unknown||!homeUrl(state.url)||state.busy||state.ready!=='complete'||state.age<MIN_AGE)continue;
    // Verify pinned targets have not disappeared during this run.
    if(!now.some(t=>t.id===tt)||!now.some(t=>t.id===tr))break;
    const response=await fetch(BASE+'/json/close/'+encodeURIComponent(cur.id),{signal:AbortSignal.timeout(5000)});
    if(!response.ok)throw Error('Chrome rechazó cierre '+cur.id+': HTTP '+response.status);
    closed++;log.push({id:cur.id,ageMin:state.age});
    await sleep(350);
  }
  const dir=path.join(process.env.LOCALAPPDATA||os.tmpdir(),'TT_Recuperacion');
  fs.mkdirSync(dir,{recursive:true});
  const logFile=path.join(dir,'safe-tab-prune-'+new Date().toISOString().replace(/[:.]/g,'-')+'.json');
  fs.writeFileSync(logFile,JSON.stringify({when:new Date().toISOString(),closed:log},null,2),'utf8');
  console.log('Pestañas cerradas:',closed);
  console.log('Registro:',logFile);
  console.log('Chrome principal, pestañas fijas y conversaciones no-home: conservados.');
})().catch(e=>{console.error('LIMPIEZA POSPUESTA:',String(e.message||e));process.exitCode=1});
