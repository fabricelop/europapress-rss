#requires -Version 5.1
<#
TT_EDITORIAL_RESCUE_V1 -- ONE FILE LOCAL INSTALLER
PowerShell (Windows) 5.1; Node.js >=22; no external npm dependencies.
Installs a guarded editorial-only runner for C:\TTiTTulares\Ejecutar.js.
Default: backup + preflight + conservative CDP cleanup + install + one send/project + verify GitHub queue snapshots.
-AuditOnly: read-only (no files changed, no tabs opened or closed).
-NoDispatch: install, cleanup and test composer only; don't send editorial prompts.
-Rollback: restore ORIGINAL Ejecutar.js after checking no launcher is running.
Never modifies queues, images, Cloudflare, other apps, the 9234 browser or GitHub.
IMPORTANT: Browser/composer/queue health cannot be guaranteed by this installer.
#>
[CmdletBinding()]
param([switch]$AuditOnly,[switch]$NoDispatch,[switch]$Rollback,[switch]$SafeRestart)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$Base='C:\TTiTTulares'
$Store=Join-Path $Base 'TT-Editorial-Rescue'
$Target=Join-Path $Base 'Ejecutar.js'
$Guard=Join-Path $Base 'TT-Editorial-Guard.js'
$Previous=Join-Path $Base 'Ejecutar.TT-Original.js'
$Manifest=Join-Path $Store 'installed.json'
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$logdir=Join-Path $env:LOCALAPPDATA 'TT_Recuperacion'
New-Item -ItemType Directory -Path $logdir -Force | Out-Null
$Log=Join-Path $logdir ('editorial-rescue-'+$stamp+'.log')
function Note([string]$Message) {
  $line=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+' TT_RESCUE '+$Message
  Write-Host $line
  Add-Content -LiteralPath $Log -Value $line -Encoding UTF8
}
function Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash }
function RunnerProcesses {
  return @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop | Where-Object {
    [string]$_.CommandLine -match '(?i)(?:[\\/]|\b)(?:Ejecutar[.]js|Ejecutar[.]TT-Original[.]js|TT-Editorial-Guard[.]js)(?:\s|"|$)'
  })
}
function EnsureNotRunning {
  $live=@(RunnerProcesses)
  if($live.Count -gt 0){throw ('No se puede sustituir Ejecucion activa: '+(($live|ForEach-Object{$_.ProcessId}) -join ',')+'. Reintenta sin finalizar los trabajos.')}
}
function NodeCheck([string]$File,[string]$node) {
  & $node --check $File
  if($LASTEXITCODE -ne 0){throw ('Node syntax invalid: '+$File)}
}
function QueueSnapshot([string]$Path) {
  try {
    $u='https://raw.githubusercontent.com/fabricelop/europapress-rss/main/'+$Path+'?t='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $data=Invoke-RestMethod -Uri $u -TimeoutSec 12 -Headers @{'Cache-Control'='no-cache';'User-Agent'='TT-Editorial-Rescue-V1'} -ErrorAction Stop
    $active=@($data.items|Where-Object{([string]$_.status) -in @('PROCESSING','preparing','update')})
    return [pscustomobject]@{active=$active.Count; count=$data.count; updated_at=$data.updated_at}
  } catch {return $null}
}
if(-not(Test-Path -LiteralPath $Base)){throw 'No existe C:\TTiTTulares: sin cambios.'}
$node=(Get-Command 'node.exe' -ErrorAction Stop).Source
$version=& $node -p 'process.versions.node'
$major=[int]([string]$version).Split('.')[0]
if($major -lt 22){throw ('Node.js '+$version+' sin soporte CDP global requerido. Instala Node >=22; no se ha tocado Ejecutar.js.')}
if((& $node -p 'typeof WebSocket') -ne 'function'){throw 'Node WebSocket global no disponible: NO SE TOCA NADA.'}
Note ('BEGIN mode='+$(if($Rollback){'rollback'}elseif($AuditOnly){'audit'}else{'install'})+' node='+$version)
function NoteMemory([string]$Stage){
  try {
    $m=Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
    Note ('MEMORY '+$Stage+' committed_gb='+[math]::Round([double]$m.CommittedBytes/1GB,2)+' limit_gb='+[math]::Round([double]$m.CommitLimit/1GB,2))
  }catch{Note ('MEMORY '+$Stage+' unavailable')}
  try {
    $roots=@(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction Stop | Where-Object {
      [string]$_.CommandLine -match '--remote-debugging-port(?:=|\s+)92(?:23|34)(?:\s|$)' -and [string]$_.CommandLine -notmatch '(?:^|\s)--type='
    })
    $safe=@($roots|ForEach-Object {if([string]$_.CommandLine -match '9223'){'9223:'+($_.ProcessId)}else{'9234:'+($_.ProcessId)}})
    Note ('CHROME_ROOTS '+$Stage+' '+($safe -join ','))
  }catch{Note ('CHROME_ROOTS '+$Stage+' unavailable')}
}
NoteMemory 'before'
$beforeTT=QueueSnapshot 'ttittulares/editorial-queue.json'
$beforeTR=QueueSnapshot 'trends/editorial-queue.json'
Note ('GITHUB BEFORE titulares='+$(if($beforeTT){$beforeTT.active}else{'unavailable'})+' tendencias='+$(if($beforeTR){$beforeTR.active}else{'unavailable'}))
if($Rollback){
  EnsureNotRunning
  if(-not(Test-Path -LiteralPath $Manifest)){throw 'No existe manifiesto de instalación: no revertir a ciegas.'}
  $meta=Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
  if(-not(Test-Path -LiteralPath $meta.backup)){throw 'Copia de seguridad ausente; rollback bloqueado.'}
  if((Hash $meta.backup) -ne [string]$meta.sha256){throw 'Backup no coincide con su SHA256: rollback bloqueado.'}
  $tmp=$Target+'.rollback-tmp'
  Copy-Item -LiteralPath $meta.backup -Destination $tmp -Force -ErrorAction Stop
  Move-Item -LiteralPath $tmp -Destination $Target -Force -ErrorAction Stop
  NodeCheck $Target $node
  Remove-Item -LiteralPath $Manifest -Force -ErrorAction Stop
  if(Test-Path -LiteralPath $Previous){Remove-Item -LiteralPath $Previous -Force -ErrorAction Stop}
  Note 'ROLLBACK OK: Ejecutar.js original restaurado; los respaldos y las colas se conservan.'
  Note ('LOG '+$Log)
  exit 0
}
# Embedded Node engine is used for LOCAL CDP only, with strict fail-closed checks.
$engine=@'
'use strict';
// TT_EDITORIAL_GUARD_V1. Never opens, reads or writes TTImages outputs.
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process');
const HOME='C:\\TTiTTulares',STATE=path.join(HOME,'TT-Editorial-Rescue'),CDP='http://127.0.0.1:9223';
const MODE=process.argv[2]||'--audit',PROJECT=process.argv[3]||'';
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const fail=s=>{throw Error(String(s))};
const note=s=>console.log('TT_GUARD '+s);
const idSafe=x=>/^[0-9a-f-]{12,80}$/i.test(String(x||''));
const chat=u=>{try{const x=new URL(u);return x.protocol==='https:'&&x.hostname==='chatgpt.com'}catch{return false}};
const landing=u=>{try{const x=new URL(u);return chat(u)&&(/^\/g\/g-p-[a-z0-9-]+\/?$/i.test(x.pathname)||/^\/project\/[a-z0-9-]+\/?$/i.test(x.pathname))}catch{return false}};
const backoff=(x)=>Math.min(5000,Math.max(500,x));
function readJSON(f){try{return JSON.parse(fs.readFileSync(f,'utf8'))}catch{return null}}
function atomic(f,x){fs.mkdirSync(path.dirname(f),{recursive:true});const t=f+'.'+process.pid+'.tmp';fs.writeFileSync(t,JSON.stringify(x,null,2)+'\n','utf8');fs.renameSync(t,f)}
function pinIds(){return new Set(['ttittulares-image-tab.json','ttendencias-image-tab.json'].map(f=>readJSON(path.join(HOME,f))?.target_id).filter(Boolean).map(String))}
async function targets(){const r=await fetch(CDP+'/json/list',{signal:AbortSignal.timeout(7000),cache:'no-store'});if(!r.ok)fail('CDP list '+r.status);const a=await r.json();if(!Array.isArray(a))fail('CDP invalid targets');return a.filter(t=>t.type==='page')}
class WS {
  constructor(url){this.url=url;this.ws=null;this.n=0;this.waiting=new Map()}
  async open(){
    if(typeof WebSocket!=='function')fail('Node WebSocket global unavailable');
    const w=this.ws=new WebSocket(this.url);
    await new Promise((ok,bad)=>{const timer=setTimeout(()=>bad(Error('CDP connect timeout')),7000);w.addEventListener('open',()=>{clearTimeout(timer);ok()},{once:true});w.addEventListener('error',()=>{clearTimeout(timer);bad(Error('CDP WebSocket failed'))},{once:true})});
    w.addEventListener('message',ev=>{let m;try{m=JSON.parse(String(ev.data))}catch{return}const p=this.waiting.get(m.id);if(!p)return;this.waiting.delete(m.id);m.error?p.bad(Error(String(m.error.message||'CDP error'))):p.ok(m.result)});
    w.addEventListener('close',()=>{for(const p of this.waiting.values())p.bad(Error('CDP closed'));this.waiting.clear()});
  }
  async call(method,params={},ms=8000){const id=++this.n;let timer;return await new Promise((ok,bad)=>{timer=setTimeout(()=>{this.waiting.delete(id);bad(Error('CDP '+method+' timeout'))},ms);this.waiting.set(id,{ok:x=>{clearTimeout(timer);ok(x)},bad:e=>{clearTimeout(timer);bad(e)}});try{this.ws.send(JSON.stringify({id,method,params}))}catch(e){this.waiting.delete(id);clearTimeout(timer);bad(e)}})}
  async eval(exp){const x=await this.call('Runtime.evaluate',{expression:exp,returnByValue:true,awaitPromise:false},8500);if(x?.exceptionDetails||!x?.result||x.result.value===undefined)throw Error('CDP eval returned no value');return x.result.value}
  close(){try{this.ws?.close()}catch{}}
}
const expr=(()=>{return `(()=>{let visible=e=>e&&e.getClientRects().length&&getComputedStyle(e).visibility!=='hidden'&&getComputedStyle(e).display!=='none';let ed=[document.querySelector('#prompt-textarea'),document.querySelector('[data-testid="prompt-textarea"]'),...document.querySelectorAll('main [contenteditable="true"][role="textbox"],main textarea')].find(visible);let raw=String(ed?.value??ed?.textContent??'');let hints=[ed?.getAttribute('data-placeholder'),ed?.getAttribute('placeholder'),ed?.querySelector('[data-placeholder]')?.getAttribute('data-placeholder')].filter(Boolean).map(x=>String(x).trim());let placeholderOnly=!!raw.trim()&&hints.includes(raw.trim());let v=placeholderOnly?'':raw;let us=[...document.querySelectorAll('[data-message-author-role="user"]')],aa=document.querySelectorAll('[data-message-author-role="assistant"]');let stop=!!document.querySelector('button[data-testid="stop-button"]')||[...document.querySelectorAll('button')].some(b=>/^(stop generating|stop response|detener generaci[oó]n|detener respuesta|parar generaci[oó]n|cancel generation|cancelar generaci[oó]n)(\\b|\\s)/i.test(String(b.getAttribute('aria-label')||b.getAttribute('title')||'')));let busy=stop||!!document.querySelector('main [aria-busy="true"], [data-testid="loading-spinner"]');let shield=!!document.querySelector('[role="dialog"][aria-modal="true"],iframe[src*="challenge"],iframe[src*="captcha"]');let rect=ed?.getBoundingClientRect();return {url:location.href,ready:document.readyState,editor:!!ed,editorTag:ed?.tagName||null,editorId:ed?.id||null,placeholderMatch:placeholderOnly,editorLength:v.trim().length,editorText:v.slice(0,9000),users:us.length,assistants:aa.length,busy,shield,focused:document.hasFocus(),navMin:Math.max(0,(Date.now()-performance.timeOrigin)/60000),lastUser:String(us.at(-1)?.textContent||'').slice(0,4000),editorRect:rect?{x:rect.x,y:rect.y,w:rect.width,h:rect.height}:null}})()`})();
async function inspect(t){if(!t?.webSocketDebuggerUrl)return {unknown:'CDP target socket absent'};let c=new WS(t.webSocketDebuggerUrl);try{await c.open();return await c.eval(expr)}catch(e){return {unknown:String(e.message||e).slice(0,140)}}finally{c.close()}}
async function scan(list,parallel=5){let idx=0;let a=new Array(list.length);await Promise.all(Array.from({length:Math.min(parallel,list.length)},async()=>{while(idx<list.length){let i=idx++;a[i]=await inspect(list[i])}}));return a}
function protection(t,s,pins){
 if(pins.has(t.id))return 'image_pin';
 if(!chat(t.url)||!chat(s?.url)||t.url!==s.url)return 'not_verified_chat';
 if(s.unknown||s.ready!=='complete')return 'unknown_or_loading';
 if(s.focused||s.busy||s.shield||s.editorLength!==0||s.users!==0||s.assistants!==0)return 'active_or_content';
 if(s.navMin<20)return 'too_recent';
 return '';
}
async function closeVerified(t){const n=await targets(),current=n.find(x=>x.id===t.id);if(!current||current.url!==t.url||pinIds().has(t.id))return false;let s=await inspect(current);if(protection(current,s,pinIds()))return false;const r=await fetch(CDP+'/json/close/'+encodeURIComponent(t.id),{signal:AbortSignal.timeout(6000)});return r.ok}
async function cleanup(){
 const all=await targets(),pins=pinIds();note('AUDIT pages='+all.length+' pinned='+all.filter(t=>pins.has(t.id)).length);
 const states=await scan(all,5);let eligible=[],reasons={};
 for(let i=0;i<all.length;i++){
  const t=all[i],s=states[i];const why=protection(t,s,pins);
  reasons[why||'eligible']=(reasons[why||'eligible']||0)+1;
  // Never touch an untracked conversation with rendered content, unknown state or a title.
  if(!why && landing(t.url) && (!t.title||/^(ChatGPT|New chat|Nuevo chat)(\s*[-–].*)?$/i.test(String(t.title).trim())))eligible.push({t,s});
 }
 note('AUDIT categories='+JSON.stringify(reasons)+' candidate_blank='+eligible.length);
 atomic(path.join(STATE,'last-audit.json'),{at:new Date().toISOString(),pages:all.length,reasons,candidates:eligible.map(x=>({id:x.t.id.slice(0,12),ageMinutes:Math.floor(x.s.navMin)}))});
 if(MODE==='--audit'||MODE==='--probe')return {all,eligible};
 // TWO independent observations. No forced close of unreadable/working tabs.
 if(eligible.length){await sleep(12000)}
 const current=await targets();let closed=0;
 for(const {t,s} of eligible){
  if(closed>=35)break;
  const cur=current.find(x=>x.id===t.id);
  if(!cur||cur.url!==t.url||pinIds().has(t.id))continue;
  const v=await inspect(cur);
  if(protection(cur,v,pinIds()))continue;
  if(v.url!==s.url||v.users!==s.users||v.assistants!==s.assistants)continue;
  // Recheck immediately before each close; preserve at least 2 healthy blank tabs.
  if((await targets()).length<=2)break;
  if(await closeVerified(cur)){closed++;note('CLOSED_VERIFIED_BLANK id='+cur.id.slice(0,12))}
 }
 note('PRUNE closed='+closed+' pages_after='+(await targets()).length);
 return {closed};
}
function projectUrl(project){
 // These are merely hints; never guess a project URL from another project.
 const original=path.join(HOME,'Ejecutar.TT-Original.js');let src='';try{src=fs.readFileSync(original,'utf8')}catch{}
 const urls=[...src.matchAll(/https:\/\/chatgpt\.com\/(?:g\/g-p-[a-zA-Z0-9-]+|project\/[a-zA-Z0-9-]+)\/?/g)].map(x=>({url:x[0],pos:x.index}));
 const options=[];for(const u of urls){const near=src.slice(Math.max(0,u.pos-220),Math.min(src.length,u.pos+220)).toLowerCase();if(near.includes(project==='titulares'?'titulares':'tendencias'))options.push(u.url)}
 const unique=[...new Set(options)];return unique.length===1?unique[0]:'https://chatgpt.com/';
}
function ledger(marker){return path.join(STATE,'sent',marker.replace(/[^a-zA-Z0-9_.-]/g,'_').slice(0,130)+'.json')}
function lock(){fs.mkdirSync(STATE,{recursive:true});const f=path.join(STATE,'dispatch.lock');for(let i=0;i<2;i++){try{fs.writeFileSync(f,JSON.stringify({pid:process.pid,at:Date.now()}),{flag:'wx'});return()=>{try{let j=readJSON(f);if(j?.pid===process.pid)fs.unlinkSync(f)}catch{}}}catch(e){if(e.code!=='EEXIST')throw e;let old=readJSON(f);if(!old?.pid||Date.now()-Number(old.at||0)<10000)fail('another editorial send is locking Chrome');try{process.kill(Number(old.pid),0);fail('another editorial sender pid='+old.pid)}catch(err){if(err?.code!=='ESRCH')throw err;fs.unlinkSync(f)}}}fail('could not obtain dispatch lock')}
async function pruneFailedOwned(){
 const dir=path.join(STATE,'sent');let entries=[];
 try{entries=fs.readdirSync(dir).filter(f=>f.endsWith('.json')).map(f=>readJSON(path.join(dir,f))).filter(x=>x?.status==='preflight_failed'&&idSafe(String(x.target||'')))}catch{}
 const owned=new Set(entries.map(x=>x.target)),pins=pinIds();let closed=0;
 for(const t of await targets()){
  if(closed>=30)break;
  if(!owned.has(t.id)||pins.has(t.id)||!chat(t.url))continue;
  const v=await inspect(t);
  if(v.unknown||v.ready!=='complete'||v.focused||v.busy||v.shield||v.users!==0||v.assistants!==0||!v.editor||v.editorText.length>4000)continue;
  const backup=path.join(process.env.LOCALAPPDATA||STATE,'TT_Recuperacion','editorial-drafts','abandoned-'+t.id+'.json');
  if(!fs.existsSync(backup))atomic(backup,{at:new Date().toISOString(),target:t.id,url:v.url,text:v.editorText});
  const now=(await targets()).find(x=>x.id===t.id);
  if(!now||now.url!==t.url||pinIds().has(t.id))continue;
  const check=await inspect(now);
  if(check.unknown||check.focused||check.busy||check.shield||check.users!==0||check.assistants!==0||check.editorText!==v.editorText)continue;
  const response=await fetch(CDP+'/json/close/'+encodeURIComponent(t.id),{signal:AbortSignal.timeout(6000)}).catch(()=>null);
  if(response?.ok){closed++;note('CLOSED_FAILED_OWNED_TAB id='+t.id.slice(0,12))}
 }
 note('FAILED_OWNED_PRUNE closed='+closed);
 return closed;
}
async function preflight(){
 await pruneFailedOwned();
 const pages=await targets(),pins=pinIds();const states=await scan(pages,4);
 note('PREFLIGHT pages='+pages.length+' image_pins='+pages.filter(p=>pins.has(p.id)).length+' unknown='+states.filter(s=>!!s.unknown).length+' busy='+states.filter(s=>!!s.busy).length);
 // Historical conversation tabs are not active editorial jobs. Do not
 // stall BOTH queues merely because they are still open. Fail closed for
 // active/untracked sends below; keep a generous hard resource ceiling.
 if(pages.length>48)fail('TOO_MANY_TABS_HARD_CAP '+pages.length+'; preserve protected tabs');
 if(pages.length>18)note('EDITORIAL_TAB_SOFT_PRESSURE '+pages.length+'; originals preserved');
 const busy=pages.filter((t,i)=>states[i].busy&&!pins.has(t.id));
 // A single independently confirmed editorial response may continue while
 // another project is dispatched. Other work, including unknown image tabs,
 // blocks new launches (never steal or close it).
 const confirmedIds=new Set();
 try{for(const f of fs.readdirSync(path.join(STATE,'sent'))){const j=readJSON(path.join(STATE,'sent',f));if(j?.status==='confirmed'&&j.target)confirmedIds.add(j.target)}}catch{}
 if(busy.length>1||busy.some(t=>!confirmedIds.has(t.id)))fail('OTHER_CHAT_ACTIVITY: no new editorial launch during unrecognized active reply');
 return pages;
}
async function checkMarkerExisting(marker){
 const pp=await targets();for(const t of pp){if(!chat(t.url)||!t.webSocketDebuggerUrl)continue;const s=await inspect(t);if(String(s.lastUser||'').includes(marker))return t}
 return null;
}
async function createTarget(url){
 // Only create a tab when preflight passes. This is the ONLY tab-creation point.
 const r=await fetch(CDP+'/json/new?'+encodeURIComponent(url),{method:'PUT',signal:AbortSignal.timeout(8500)});
 if(!r.ok)fail('CDP create target '+r.status);
 const t=await r.json();if(!idSafe(t.id)||!t.webSocketDebuggerUrl)fail('Invalid new CDP target');return t;
}
async function waitEditor(c,ms=50000){const end=Date.now()+ms;while(Date.now()<end){let s;try{s=await c.eval(expr)}catch{await sleep(900);continue}if(s.editor&&chat(s.url)&&s.ready==='complete'&&!s.shield&&!s.busy)return s;await sleep(1000)}return null}
async function confirmUser(c,marker,ms=35000){const end=Date.now()+ms;while(Date.now()<end){let s;try{s=await c.eval(expr)}catch{await sleep(700);continue}if(s.lastUser.includes(marker)&&s.editorLength===0){return s}await sleep(700)}return null}
async function send(){
 if(!['titulares','tendencias'].includes(PROJECT))fail('unknown project');
 const buf=String(process.env.TT_CHAT_MESSAGE_B64||'');if(!buf)fail('missing TT_CHAT_MESSAGE_B64');
 const msg=Buffer.from(buf,'base64').toString('utf8');
 const expected=PROJECT==='titulares'?'TTITTULARES_EDITORIAL_JOB_V2':'TTENDENCIAS_EDITORIAL_JOB_V2';
 const marker=msg.match(new RegExp('\\b'+expected+'\\s+([a-zA-Z0-9._-]{8,90})'));
 if(!marker)fail('not a recognized editorial JOB V2 request');
 const unique=marker[0],f=ledger(unique),entry=readJSON(f);
 note('MODE MODO: ENVIO REAL project='+PROJECT+' marker='+unique);
 if(entry?.status==='confirmed'){note('MENSAJE ENVIADO: already confirmed marker='+unique);return}
 const release=lock();let c,created=null;let submitted=false;
 try{
  const existing=await checkMarkerExisting(unique);
  if(existing){atomic(f,{status:'confirmed',at:new Date().toISOString(),target:existing.id,marker:unique,source:'observed_existing_user_message'});note('MENSAJE ENVIADO: existing user bubble verified');return}
  if(entry?.status==='submit_intent')fail('AMBIGUOUS_PREVIOUS_SEND: never resend without verifying pending conversation');
  await cleanup();await preflight();
  const url=projectUrl(PROJECT);
  note('OPEN_EDITORIAL route='+(url.includes('/g/')?'project':'home'));
  created=await createTarget(url);atomic(f,{status:'created',at:new Date().toISOString(),target:created.id,marker:unique});
  c=new WS(created.webSocketDebuggerUrl);await c.open();
  let s=await waitEditor(c,40000);
  if(!s&&url!=='https://chatgpt.com/'){
    note('PROJECT_EDITOR_UNAVAILABLE, NAVIGATE_HOME_ONE_TIME');
    await c.call('Page.navigate',{url:'https://chatgpt.com/'},10000);
    s=await waitEditor(c,30000);
  }
  if(!s)fail('No aparece el cuadro de escritura (despues de project + home preflight)');
  // Project landing sometimes recovers existing chat history in the new bot-owned tab.
  // Only navigate when the composer is empty, not busy and without a modal.
  if(s.editorLength===0 && (s.users>0||s.assistants>0) && !s.busy && !s.shield){
    note('PROJECT_LANDING_HISTORY; NAVIGATE_BOT_OWNED_TAB_HOME');
    await c.call('Page.navigate',{url:'https://chatgpt.com/'},10000);
    s=await waitEditor(c,30000);
  }
  if(s && (s.editorLength>0||s.users>0||s.assistants>0) && !s.busy && !s.shield){
    // The home route can restore a previous conversation or draft. Click New chat only
    // in this bot-owned tab and verify the resulting page before typing.
    note('HOME_RESTORED_HISTORY; CLICK_NEW_CHAT_BOT_OWNED_TAB');
    const clicked=await c.eval(`(()=>{const links=[...document.querySelectorAll('a,button')];const e=links.find(x=>x.getClientRects().length && (x.getAttribute('data-testid')==='create-new-chat-button'||/^(new chat|nuevo chat)$/i.test(String(x.getAttribute('aria-label')||x.textContent||'').trim())));if(!e)return false;e.click();return true})()`);
    if(!clicked)fail('NEW_CHAT_CONTROL_UNAVAILABLE: preserve restored conversation');
    const blankUntil=Date.now()+30000;
    do { await sleep(650); s=await c.eval(expr).catch(()=>null); }
    while(Date.now()<blankUntil && (!s||s.ready!=='complete'||!s.editor||s.busy||s.shield||s.editorLength!==0||s.users!==0||s.assistants!==0));
  }
  if(s&&s.users===0&&s.assistants===0&&s.editorLength>0&&!s.busy&&!s.shield){
    // A restored draft on this newly created bot-owned tab blocks every run.
    // Preserve its exact bytes locally before clearing only this tab's composer.
    if(s.editorLength>4000||s.editorText.length>4000||s.editorText.trim().length!==s.editorLength)fail('RESTORED_DRAFT_TOO_LARGE: preserve without editing');
    const backup=path.join(process.env.LOCALAPPDATA||STATE,'TT_Recuperacion','editorial-drafts',unique.replace(/[^a-zA-Z0-9._-]/g,'_')+'.json');
    if(fs.existsSync(backup))fail('RESTORED_DRAFT_BACKUP_EXISTS: preserve without editing');
    atomic(backup,{at:new Date().toISOString(),marker:unique,target:created.id,url:s.url,text:s.editorText});
    note('RESTORED_DRAFT_BACKED_UP_LOCAL length='+s.editorLength);
    const focusDraft=await c.eval(`(()=>{const x=document.querySelector('#prompt-textarea')||document.querySelector('[data-testid="prompt-textarea"]')||document.querySelector('main [contenteditable="true"][role="textbox"]');if(!x||!x.getClientRects().length)return false;x.focus();return document.activeElement===x||x.contains(document.activeElement)})()`);
    if(!focusDraft)fail('RESTORED_DRAFT_FOCUS_FAILED: backup retained');
    await c.call('Input.dispatchKeyEvent',{type:'keyDown',key:'a',code:'KeyA',windowsVirtualKeyCode:65,modifiers:2});
    await c.call('Input.dispatchKeyEvent',{type:'keyUp',key:'a',code:'KeyA',windowsVirtualKeyCode:65,modifiers:2});
    await c.call('Input.dispatchKeyEvent',{type:'keyDown',key:'Backspace',code:'Backspace',windowsVirtualKeyCode:8});
    await c.call('Input.dispatchKeyEvent',{type:'keyUp',key:'Backspace',code:'Backspace',windowsVirtualKeyCode:8});
    await sleep(700);s=await c.eval(expr);
    if(!s||s.editorLength!==0||s.users!==0||s.assistants!==0)fail('RESTORED_DRAFT_CLEAR_UNVERIFIED: backup retained');
    note('RESTORED_DRAFT_CLEARED_BOT_TAB backup='+path.basename(backup));
  }
  if(!s||s.editorLength!==0||s.users!==0||s.assistants!==0){
    note('NEW_CHAT_NOT_BLANK state='+JSON.stringify({url:s?.url?.slice(0,180),ready:s?.ready,editor:s?.editor,editorLength:s?.editorLength,editorTag:s?.editorTag,editorId:s?.editorId,placeholderMatch:s?.placeholderMatch,users:s?.users,assistants:s?.assistants,busy:s?.busy,shield:s?.shield}));
    fail('Fresh tab has draft or chat content; refusing to overwrite');
  }
  const focused=await c.eval(`(()=>{const x=[document.querySelector('#prompt-textarea'),document.querySelector('[data-testid="prompt-textarea"]'),...document.querySelectorAll('main [contenteditable="true"][role="textbox"],main textarea')].find(e=>e&&e.getClientRects().length);if(!x)return false;x.focus();return document.activeElement===x||x.contains(document.activeElement)})()`);
  if(!focused)fail('COMPOSER_NOT_FOCUSED: do not type into unknown control');
  await c.call('Input.insertText',{text:msg},15000);
  // React may commit the edit asynchronously: verify before attempting send.
  let validated=false;
  for(let attempt=0;attempt<10;attempt++){
    await sleep(500);
    s=await c.eval(expr);
    if(s.editor && s.editorText.includes(unique) && s.editorLength>=msg.length*0.8){validated=true;break}
    if(s.editorLength>0&&!s.editorText.includes(unique))
      fail('DRAFT_NOT_OURS: preserve unexpected draft; never overwrite');
  }
  if(!validated)fail('DRAFT_NOT_VERIFIED: preserve unconfirmed draft; do not send');
  // Intent logged BEFORE the click. If uncertain, do not automatically send a duplicate.
  atomic(f,{status:'submit_intent',at:new Date().toISOString(),target:created.id,marker:unique});submitted=true;
  const btn=await c.eval(`(()=>{const selectors=['button[data-testid="send-button"]','button[aria-label="Send prompt"]','button[aria-label="Enviar mensaje"]','button[aria-label="Send message"]'];let b=selectors.map(s=>document.querySelector(s)).find(x=>x&&!x.disabled&&x.getClientRects().length);if(!b)return null;const r=b.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()`);
  if(btn&&btn.x>0&&btn.y>0){await c.call('Input.dispatchMouseEvent',{type:'mousePressed',x:btn.x,y:btn.y,button:'left',clickCount:1});await c.call('Input.dispatchMouseEvent',{type:'mouseReleased',x:btn.x,y:btn.y,button:'left',clickCount:1});}
  else {await c.call('Input.dispatchKeyEvent',{type:'keyDown',key:'Enter',code:'Enter',windowsVirtualKeyCode:13,nativeVirtualKeyCode:13});await c.call('Input.dispatchKeyEvent',{type:'keyUp',key:'Enter',code:'Enter',windowsVirtualKeyCode:13,nativeVirtualKeyCode:13})}
  s=await confirmUser(c,unique,40000);
  if(!s)fail('TRANSMISSION_UNVERIFIED: no rendered user bubble with exact marker (never claim sent)');
  atomic(f,{status:'confirmed',at:new Date().toISOString(),target:created.id,marker:unique,urlKind:s.url.includes('/c/')?'conversation':'other'});
  note('MENSAJE ENVIADO; exact user message confirmed in browser target='+created.id.slice(0,14));
  note('EJECUCION LANZADA.');
  const watch=path.join(HOME,'TT-Editorial-Tab-Watch.js');
  if(fs.existsSync(watch)){try{const child=cp.spawn(process.execPath,[watch,'--register',created.id,s.url],{detached:true,stdio:'ignore',windowsHide:true});child.unref();note('WATCH_REGISTERED')}catch(e){note('WARN watcher '+e.message)}}
 }catch(e){note('ERROR: '+String(e.message||e).replace(/[\r\n]/g,' ').slice(0,280));process.exitCode=2;
  // Do not close a possible draft or sent-but-unconfirmed tab.
  if(created&&!submitted){
   const now=(await targets().catch(()=>[])).find(t=>t.id===created.id);
   if(now){let v=await inspect(now);if(!v.unknown&&!v.busy&&v.users===0&&v.assistants===0&&v.editorLength===0&&!v.shield){try{await fetch(CDP+'/json/close/'+encodeURIComponent(now.id),{signal:AbortSignal.timeout(4000)});note('CLOSED_OWN_EMPTY_FAILED_LAUNCH')}catch{}}}
  }
  if(!submitted){atomic(f,{status:'preflight_failed',at:new Date().toISOString(),target:created?.id||null,marker:unique})}
 }finally{try{c?.close()}catch{}release()}
}
async function main(){
 if(MODE==='--selftest'){
  if(!idSafe('1234567890abcdef')||chat('https://evilchatgpt.com/')||!chat('https://chatgpt.com/'))fail('selftest route');
  const s='TTENDENCIAS_EDITORIAL_JOB_V2 tr-test-12345678';if(!/TTENDENCIAS_EDITORIAL_JOB_V2\s+[a-zA-Z0-9._-]{8,90}/.test(s))fail('selftest marker');
  note('SELFTEST_OK regex route marker, Node='+process.versions.node);return
 }
 if(MODE==='--audit'){await cleanup();return}
 if(MODE==='--cleanup'){await pruneFailedOwned();for(let cycle=0;cycle<4;cycle++){const b=(await targets()).length;note('CLEANUP_PASS '+(cycle+1)+' pages='+b);if(b<=18)break;const r=await cleanup();if(!r.closed)break;}return}
 if(MODE==='--inspect-failed'){
  const dir=path.join(STATE,'sent');
  const files=fs.readdirSync(dir).filter(x=>x.endsWith('.json')).map(x=>({name:x,full:path.join(dir,x),time:fs.statSync(path.join(dir,x)).mtimeMs})).sort((a,b)=>b.time-a.time);
  const recent=files.map(x=>readJSON(x.full)).find(x=>x?.status==='preflight_failed'&&x.target);
  if(!recent)fail('NO_RECENT_PREFLIGHT_TARGET');
  const t=(await targets()).find(x=>x.id===recent.target);
  if(!t)fail('TARGET_NOT_AVAILABLE');
  const v=await inspect(t);
  note('SAFE_COMPOSITOR_STATE '+JSON.stringify({urlKind:v.url?.includes('/c/')?'conversation':v.url?.includes('/g/')?'project':'home',editor:v.editor,editorTag:v.editorTag,editorId:v.editorId,placeholderMatch:v.placeholderMatch,editorLength:v.editorLength,users:v.users,assistants:v.assistants,busy:v.busy,shield:v.shield}));
  return;
 }
 if(MODE==='--probe'){
  await cleanup();await pruneFailedOwned();let pp=await targets();if(pp.length>48)fail('NO_PROBE hard tab cap');
  let t=await createTarget('https://chatgpt.com/'),c=new WS(t.webSocketDebuggerUrl);try{await c.open();let s=await waitEditor(c,40000);if(!s)fail('COMPOSER_NOT_READY: user login, page load or quota may be blocking');note('COMPOSER_OK no message sent');}
  finally{c.close();let n=(await targets()).find(x=>x.id===t.id);if(n){let st=await inspect(n);if(!st.unknown&&!st.busy&&st.users===0&&st.assistants===0&&st.editorLength===0)await fetch(CDP+'/json/close/'+encodeURIComponent(t.id)).catch(()=>{})}}
  return;
 }
 if(MODE==='--send'){await send();return}
 fail('unknown mode');
}
main().catch(e=>{console.error('TT_GUARD ERROR: '+String(e.message||e));process.exitCode=2});
'@
$wrapper=@'
'use strict';
// TT_EDITORIAL_SAFE_WRAPPER_V1 - transparent for non-editorial (including TTImages) invocations.
const {spawn}=require('node:child_process'),path=require('node:path');
const enviar = process.argv.includes("--enviar");
const raw=String(process.env.TT_CHAT_MESSAGE_B64||'');
let message='';try{message=Buffer.from(raw,'base64').toString('utf8')}catch{}
const isEditorial=enviar&&/^(TTITTULARES|TTENDENCIAS)_EDITORIAL_JOB_V2\s+[A-Za-z0-9._-]{8,90}\s+\|/.test(message);
const base=__dirname;
const script=path.join(base,isEditorial?'TT-Editorial-Guard.js':'Ejecutar.TT-Original.js');
const args=isEditorial?[script,'--send',process.argv[2]==='titulares'?'titulares':'tendencias']:[script,...process.argv.slice(2)];
const child=spawn(process.execPath,args,{cwd:process.cwd(),env:process.env,stdio:'inherit',windowsHide:true});
for(const sig of ['SIGINT','SIGTERM'])process.on(sig,()=>{try{child.kill(sig)}catch{}});
child.on('error',e=>{console.error('ERROR: TT wrapper delegate failed '+e.message);process.exitCode=2});
child.on('exit',(code,signal)=>{process.exitCode=code===null?2:code});
'@
if($AuditOnly){
  $tmp=Join-Path $env:TEMP ('tt-rescue-audit-'+[guid]::NewGuid().ToString('N')+'.js')
  try{
    [IO.File]::WriteAllText($tmp,$engine,(New-Object System.Text.UTF8Encoding($false)))
    NodeCheck $tmp $node
    & $node $tmp --selftest
    if($LASTEXITCODE -ne 0){throw 'Selftest falló'}
    & $node $tmp --audit
    Note 'AUDIT ONLY: no local scripts modified; no tabs closed.'
  }finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
  Note ('LOG '+$Log)
  exit 0
}
EnsureNotRunning
# Never deploy while the main executable is missing or already differs from our backup without inspection.
if(-not(Test-Path -LiteralPath $Target)){throw 'Ejecutar.js no encontrado: sin cambios.'}
if(Test-Path -LiteralPath $Manifest){
  $meta=Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
  if(-not(Test-Path -LiteralPath $Previous)){throw 'Instalación anterior sin original. DETENIDO.'}
  if((Hash $Previous) -ne [string]$meta.sha256){throw 'Original sidecar no coincide con manifest. DETENIDO.'}
  $current=[IO.File]::ReadAllText($Target,[Text.Encoding]::UTF8)
  if(-not $current.Contains('TT_EDITORIAL_SAFE_WRAPPER_V1')){throw 'Ejecutar.js cambió desde la última instalación. DETENIDO para no sobrescribir.'}
  Note 'Existing V1 wrapper found; validating and updating only the guarded engine.'
}else{
  if(Test-Path -LiteralPath $Previous){throw 'Existe Ejecutar.TT-Original.js sin manifiesto. No sobrescribir.'}
  if(([IO.File]::ReadAllText($Target,[Text.Encoding]::UTF8)).Contains('TT_EDITORIAL_SAFE_WRAPPER_V1')){throw 'Wrapper detectado sin manifest. No sobrescribir.'}
}
New-Item -ItemType Directory -Path $Store -Force | Out-Null
$backupDir=Join-Path $Store ('backup-'+$stamp)
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$backup=Join-Path $backupDir 'Ejecutar.js.original.bak'
if(Test-Path -LiteralPath $Manifest){
  $meta=Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
  Copy-Item -LiteralPath $Previous -Destination $backup -ErrorAction Stop
}else{
  Copy-Item -LiteralPath $Target -Destination $backup -ErrorAction Stop
}
$sha=Hash $backup
$stagedGuard=Join-Path $backupDir 'TT-Editorial-Guard.js'
$stagedWrapper=Join-Path $backupDir 'Ejecutar.wrapper.js'
$utf8=New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($stagedGuard,$engine,$utf8)
[IO.File]::WriteAllText($stagedWrapper,$wrapper,$utf8)
NodeCheck $stagedGuard $node
NodeCheck $stagedWrapper $node
& $node $stagedGuard --selftest
if($LASTEXITCODE -ne 0){throw 'Autoprueba local del motor falló; copia original preservada.'}
# Offline preflight completed before any replacement.
$installed=$false
try {
  EnsureNotRunning
  if(-not(Test-Path -LiteralPath $Manifest)){Copy-Item -LiteralPath $backup -Destination $Previous -ErrorAction Stop}
  Copy-Item -LiteralPath $stagedGuard -Destination ($Guard+'.new') -Force -ErrorAction Stop
  Move-Item -LiteralPath ($Guard+'.new') -Destination $Guard -Force -ErrorAction Stop
  Copy-Item -LiteralPath $stagedWrapper -Destination ($Target+'.new') -Force -ErrorAction Stop
  Move-Item -LiteralPath ($Target+'.new') -Destination $Target -Force -ErrorAction Stop
  NodeCheck $Target $node
  [IO.File]::WriteAllText($Manifest,(@{version='TT_EDITORIAL_SAFE_WRAPPER_V1';backup=$backup;sha256=$sha;installed_at=(Get-Date).ToString('o')}|ConvertTo-Json -Compress),$utf8)
  $installed=$true
  Note ('INSTALLED original_sha256='+$sha+' backup='+$backup)
} catch {
  try{Copy-Item -LiteralPath $backup -Destination $Target -Force -ErrorAction Stop;Note 'ROLLBACK AUTOMATIC: original restored after install failure'}catch{Note 'CRITICAL: automatic rollback failed; restore from '+$backup}
  throw
}
# Audit/cleanup is safe to run independently. It does not affect image pins or live conversations.
& $node $Guard --cleanup
if($LASTEXITCODE -ne 0){Note 'CLEANUP_UNVERIFIED; leaving all unknown tabs alone'}
# The upstream controlled recovery validates every surviving 9223 tab and active Node
# runner BEFORE touching any Chrome process. It fails closed on unknown work.
if($SafeRestart){
  $isAdmin=([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if(-not $isAdmin){
    Note 'SAFE_RESTART_BLOCKED: PowerShell no elevado. No se cerró ningún proceso Chrome.'
  } else {
    $controlled=Join-Path $backupDir 'Recover-TT-Chrome9223-Controlled.ps1'
    try {
      $commit=Invoke-RestMethod -Uri 'https://api.github.com/repos/fabricelop/europapress-rss/commits/main' -Headers @{'User-Agent'='TT-Editorial-Rescue-V1';'Accept'='application/vnd.github+json'} -TimeoutSec 15 -ErrorAction Stop
      $ref=[string]$commit.sha
      if($ref -notmatch '^[0-9a-f]{40}$'){throw 'GitHub commit SHA no válido'}
      $recoveryUrl='https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$ref+'/windows/Recover-TT-Chrome9223-Controlled.ps1'
      Invoke-WebRequest -UseBasicParsing -Uri $recoveryUrl -OutFile $controlled -TimeoutSec 30 -ErrorAction Stop
      $recoveryText=Get-Content -LiteralPath $controlled -Raw -Encoding UTF8
      if(-not $recoveryText.Contains('ConfirmRecoverySafe') -or -not $recoveryText.Contains('TT Chrome Auto') -or -not $recoveryText.Contains('TT9223')){throw 'Recuperador remoto inesperado; rechazado'}
      Note ('SAFE_RESTART_REQUEST ref='+$ref+' gate=mandatory and fail_closed')
      & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $controlled
      $restartCode=$LASTEXITCODE
      if($restartCode -ne 0){Note ('SAFE_RESTART_NOT_COMPLETED code='+$restartCode+'; protected tabs were not forced closed')}
      else{Note 'SAFE_RESTART_COMMAND_COMPLETED: checking actual editor next; not evidence of editorial completion'}
    }catch{Note ('SAFE_RESTART_BLOCKED '+$_.Exception.Message)}
  }
}
# Read-only functional probe: opens ONE tab and closes it only if verified empty.
& $node $Guard --probe
$probeOk=($LASTEXITCODE -eq 0)
Note ('EDITOR_PROBE '+$(if($probeOk){'READY'}else{'BLOCKED: no dispatch; verify Chrome login/loading or protected tabs'}))
if($probeOk -and -not $NoDispatch){
  $runTag=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString()
  $jobs=@(
    @{ Project='titulares'; Tag='tt-rescue-'+$runTag; Prompt="TTITTULARES_EDITORIAL_JOB_V2 tt-rescue-$runTag | Ejecuta AHORA la pasada editorial OFICIAL de TTiTTulares. Lee ttittulares/editorial-run-prompt.md, ttittulares/editorial-queue.json, ttittulares/status.json y telegram/editorial-processing.json desde main. Procesa TODOS los PROCESSING y rewrite_pending del más antiguo al más reciente, validando ID y revisión justo antes de cada trabajo. Investiga con fuentes actuales y persiste mediante los outboxes y aplicadores oficiales. No generes imágenes ni publiques sin aprobación. Comprueba READY/Listas en main y no declares cierre por un mero trigger." },
    @{ Project='tendencias'; Tag='tr-rescue-'+$runTag; Prompt="TTENDENCIAS_EDITORIAL_JOB_V2 tr-rescue-$runTag | Ejecuta AHORA la pasada editorial real de TTendencias. Lee trends/editorial-run-prompt.md, trends/editorial-queue.json, trends/requests.json y trends/telegram-manual-explained.json desde main. Procesa TODOS los preparing/update del más antiguo al más reciente y comprueba ID+revisión antes de cada uno. Investiga hechos y fuentes actuales y persiste por outboxes y aplicadores oficiales. NO generes imágenes ni publiques automáticamente. Verifica explained y descenso de cola en main; no confundas trigger con elaboración terminada." }
  )
  foreach($job in $jobs){
    # A task that was already successfully submitted by the user might be running.
    $live=@(RunnerProcesses)
    if($live.Count -gt 0){Note ('DISPATCH_BLOCKED active_launcher_pids='+($live.ProcessId -join ','));break}
    $old=$env:TT_CHAT_MESSAGE_B64
    try {
      $env:TT_CHAT_MESSAGE_B64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$job.Prompt))
      Note ('DISPATCH '+$job.Project+' id='+$job.Tag)
      & $node $Target $job.Project '--enviar'
      $sendExit=$LASTEXITCODE
      Note ('DISPATCH_STATUS '+$job.Project+' code='+$sendExit)
      if($sendExit -ne 0){Note 'DISPATCH_HALTED to prevent duplicate or resource overload';break}
    } finally {if($null -eq $old){Remove-Item Env:TT_CHAT_MESSAGE_B64 -ErrorAction SilentlyContinue}else{$env:TT_CHAT_MESSAGE_B64=$old}}
  }
}
# A queue change is the only accepted remote evidence, never the browser send receipt.
$afterTT=QueueSnapshot 'ttittulares/editorial-queue.json'
$afterTR=QueueSnapshot 'trends/editorial-queue.json'
if(-not $NoDispatch -and $probeOk){
  for($check=0;$check -lt 6;$check++){
    if($beforeTT -and $afterTT -and $beforeTR -and $afterTR -and
       $afterTT.active -lt $beforeTT.active -and $afterTR.active -lt $beforeTR.active){break}
    Start-Sleep -Seconds 15
    $afterTT=QueueSnapshot 'ttittulares/editorial-queue.json'
    $afterTR=QueueSnapshot 'trends/editorial-queue.json'
  }
}
NoteMemory 'after'
Note ('GITHUB AFTER titulares='+$(if($afterTT){$afterTT.active}else{'unavailable'})+' tendencias='+$(if($afterTR){$afterTR.active}else{'unavailable'}))
if($beforeTT -and $afterTT -and $afterTT.active -lt $beforeTT.active){Note 'EVIDENCE: TTiTTulares queue decreased'}else{Note 'NOT_YET_VERIFIED: TTiTTulares queue did not decrease during installer'}
if($beforeTR -and $afterTR -and $afterTR.active -lt $beforeTR.active){Note 'EVIDENCE: TTendencias queue decreased'}else{Note 'NOT_YET_VERIFIED: TTendencias queue did not decrease during installer'}
Note ('LOG '+$Log)
Note 'END. If no queue reduction is shown, PRODUCTION NOT YET CONFIRMED. Run this same installer again for a new audit or rollback with -Rollback.'