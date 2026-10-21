// TT Chrome 9223 conservative tab cleanup, dry-run by default.
'use strict';
const fs=require('node:fs');
const path=require('node:path');
const os=require('node:os');
const cp=require('node:child_process');
let BASE='http://127.0.0.1:9223';
const DIR='C:\\TTiTTulares';
const APPLY=process.argv.includes('--apply');
const MIN_AGE=5;
const MAX_CLOSE=25;
const VERIFIED_IDLE_MS=8*60000;
const STATE_FILE=path.join(process.env.LOCALAPPDATA||os.tmpdir(),'TT_Recuperacion','chrome9223-verified-idle-homes.json');
const MIN_KEEP_HOME=3;
const MAX_SCAN=250;
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
  let last;
  for(const endpoint of [...new Set([BASE,'http://127.0.0.1:9223','http://[::1]:9223'])]){
    try{
      const r=await fetch(endpoint+'/json/list',{cache:'no-store',signal:AbortSignal.timeout(7000)});
      if(!r.ok)throw Error('CDP HTTP '+r.status);
      const j=await r.json();
      if(!Array.isArray(j))throw Error('Invalid Chrome CDP response');
      BASE=endpoint;
      return j;
    }catch(e){last=e}
  }
  throw last||Error('CDP unavailable');
}
async function inspect(t){
  if(!t.webSocketDebuggerUrl||typeof WebSocket!=='function')return {unknown:'CDP WebSocket unavailable'};
  return await new Promise(resolve=>{
    let ws,done=false;
    const timer=setTimeout(()=>finish({unknown:'CDP timeout'}),4500);
    function finish(v){if(done)return;done=true;clearTimeout(timer);try{ws&&ws.close()}catch{}resolve(v)}
    const expr=`(()=>{const buttons=[...document.querySelectorAll('button')];const stop=buttons.some(b=>/^(stop|detener|parar|cancelar)(\\b|\\s)/i.test(String(b.getAttribute('aria-label')||b.getAttribute('title')||'')))||!!document.querySelector('button[data-testid="stop-button"]');const main=document.querySelector('main');const txt=String((main&&main.innerText)||'').slice(-6000);const composer=document.querySelector('#prompt-textarea,[data-testid="prompt-textarea"],textarea,[contenteditable="true"][role="textbox"]');const draft=String(composer?.innerText||composer?.value||'').trim();const messages=document.querySelectorAll('[data-message-author-role]').length;return {url:location.href,ready:document.readyState,age:Math.floor((Date.now()-performance.timeOrigin)/60000),busy:stop||/(creating image|generating image|generando imagen|creando imagen)/i.test(txt),empty:!draft&&!messages}})()`;
    try{
      const wsUrl=BASE.includes('[::1]')?String(t.webSocketDebuggerUrl).replace('127.0.0.1','[::1]'):t.webSocketDebuggerUrl;
      ws=new WebSocket(wsUrl);
      ws.addEventListener('open',()=>{try{ws.send(JSON.stringify({id:17,method:'Runtime.evaluate',params:{expression:expr,returnByValue:true}}))}catch(e){finish({unknown:String(e.message||e)})}},{once:true});
      ws.addEventListener('message',e=>{try{const d=JSON.parse(String(e.data));if(d.id!==17)return;const val=d.result?.result?.value;if(!val||d.error)finish({unknown:String(d.error?.message||'empty')});else finish(val)}catch(e){finish({unknown:String(e.message||e)})}});
      ws.addEventListener('error',()=>finish({unknown:'CDP socket error'}));
      ws.addEventListener('close',()=>finish({unknown:'CDP socket closed'}));
    }catch(e){finish({unknown:String(e.message||e)})}
  });
}
function checkBusy(){
  // Only real Node runners count. A PowerShell -Command scan must not
  // count itself merely because its command line contains the regex.
  const ps=String.raw`$q=@(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $_.ProcessId -ne $PID -and $_.Name -eq 'node.exe' -and [string]$_.CommandLine -match '(TTiTTulares|TTendencias)ImageBridge[.]js|[\\/]Ejecutar[.]js' }); Write-Output $q.Count`;
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
  const all=await listTargets();
  // Stale pin files must not block cleanup. Preserve every currently-live pin
  // and keep three additional home tabs to avoid starving the launchers.
  const activePins=new Set([tt,tr].filter(id=>id&&all.some(t=>t.id===id&&t.type==='page')));
  if(activePins.size<2)console.log('AVISO: referencias fijas obsoletas; solo se cerrarán pestañas home verificadas; se preservan 3 de reserva.');
  const pages=all.filter(t=>t.type==='page');
  const homes=pages.filter(t=>homeUrl(t.url)&&!activePins.has(t.id));
  const scan=homes.slice(0,Math.min(MAX_SCAN,Math.max(0,homes.length-MIN_KEEP_HOME)));
  let at=0;
  const checks=new Array(scan.length);
  await Promise.all(Array.from({length:Math.min(6,scan.length)},async()=>{
    while(at<scan.length){const i=at++;checks[i]={id:scan[i].id,result:await inspect(scan[i])}}
  }));
  // Repeated independent inspections are safer than navigation-time age.
  // A renderer reload can reset performance.timeOrigin even for an old tab.
  let previous={};
  try { previous=JSON.parse(fs.readFileSync(STATE_FILE,'utf8')) } catch {}
  const now=Date.now();
  const firstIdle={};
  for(const {id,result} of checks){
    if(!homeUrl(result.url)||result.ready!=='complete'||result.busy||!result.empty||result.unknown)continue;
    const old=previous[id];
    firstIdle[id]=old&&Number.isFinite(old.since)&&old.since<=now&&old.since>now-24*3600000
      ?{since:old.since,checked:now}:{since:now,checked:now};
  }
  if(APPLY){
    const output=path.dirname(STATE_FILE);
    fs.mkdirSync(output,{recursive:true});
    const staged=STATE_FILE+'.'+process.pid+'.tmp';
    fs.writeFileSync(staged,JSON.stringify(firstIdle),'utf8');
    fs.renameSync(staged,STATE_FILE);
  }
  const unknown=checks.filter(x=>x.result.unknown).length;
  const inspectedEmpty=checks.filter(x=>x.result.empty).length;
  const inspectedYoung=checks.filter(x=>x.result.empty && Number(x.result.age)<MIN_AGE).length;
  const qualified=checks.filter(x=>homeUrl(x.result.url)&&x.result.ready==='complete'&&!x.result.busy&&x.result.empty&&firstIdle[x.id]&&now-firstIdle[x.id].since>=VERIFIED_IDLE_MS)
    .sort((a,b)=>b.result.age-a.result.age);
  console.log('\n=== TT CHROME 9223: LIMPIEZA CONSERVADORA ===');
  console.log('Modo:',APPLY?'APLICAR':'SOLO SIMULACION');
  console.log('Pestañas totales:',pages.length);
  console.log('Pestañas home no fijas:',homes.length);
  console.log('Verificadas:',checks.length,'| Estado desconocido (protegidas):',unknown);
  console.log('Home sin borradores/mensajes:',inspectedEmpty,'| De ellas demasiado recientes:',inspectedYoung);
  console.log('Verificadas como vacías durante al menos '+Math.round(VERIFIED_IDLE_MS/60000)+' min en pasadas distintas:',qualified.length);
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
    if(!cur||!homeUrl(cur.url)||activePins.has(cur.id))continue;
    if(now.filter(t=>t.type==='page'&&homeUrl(t.url)&&!activePins.has(t.id)).length<=MIN_KEEP_HOME)break;
    const state=await inspect(cur);
    if(state.unknown||!homeUrl(state.url)||state.busy||!state.empty||state.ready!=='complete')continue;
    if(!firstIdle[c.id]||Date.now()-firstIdle[c.id].since<VERIFIED_IDLE_MS)continue;
    // Fail closed on a pin changed during this run.
    const currentPins=[tabPin('ttittulares-image-tab.json'),tabPin('ttendencias-image-tab.json')];
    if(currentPins.some(id=>id===cur.id)||currentPins.some(id=>id&&!activePins.has(id)&&now.some(t=>t.id===id)))break;
    const response=await fetch(BASE+'/json/close/'+encodeURIComponent(cur.id),{signal:AbortSignal.timeout(5000)});
    if(!response.ok)throw Error('Chrome rechazó cierre '+cur.id+': HTTP '+response.status);
    closed++;log.push({id:cur.id,observedIdleMin:Math.round((Date.now()-firstIdle[c.id].since)/60000)});
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
