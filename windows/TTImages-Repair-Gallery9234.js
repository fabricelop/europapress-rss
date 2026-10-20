'use strict';
// TTImages gallery 9234 safe recovery. Node 20+.
// Does not change any tab without --apply. Never touches Chrome 9223,
// existing original images, Telegram history, dedupe baseline, or capture code.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),cp=require('node:child_process');
const BASE='http://127.0.0.1:9234';
const APPLY=process.argv.includes('--apply');
const DATA=path.join(process.env.LOCALAPPDATA||os.tmpdir(),'TTImageRelay');
const REPORT=path.join(DATA,'informe-captura-v2.json');
const OUTPUT=path.join(process.env.LOCALAPPDATA||os.tmpdir(),'TT_Recuperacion');
fs.mkdirSync(OUTPUT,{recursive:true});
const LOG=path.join(OUTPUT,'ttimages-recover-gallery-'+new Date().toISOString().replace(/[:.]/g,'-')+'.log');
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const galleryUrl=u=>/^https:\/\/chatgpt\.com\/images(?:[/?#]|$)/i.test(String(u||''));
const validId=s=>/^[a-f0-9]{16,80}$/i.test(String(s||''));
function note(message){const row=new Date().toISOString()+' TTIMAGES9234 '+message;console.log(row);fs.appendFileSync(LOG,row+'\n','utf8')}
async function requestJson(url,method='GET',timeout=8500){
  const r=await fetch(url,{method,signal:AbortSignal.timeout(timeout),cache:'no-store'});
  if(!r.ok)throw Error('Chrome CDP HTTP '+r.status);
  return r.json();
}
async function targets(){const t=await requestJson(BASE+'/json/list');if(!Array.isArray(t))throw Error('Invalid CDP target list');return t}
const inspectExpression='(()=>{const b=document.body;return {route:location.pathname,ready:document.readyState,bodyChildren:b?.childElementCount||0,main:!!document.querySelector("main"),next:!!document.querySelector("#__next"),root:!!document.querySelector("#root"),testIds:document.querySelectorAll("[data-testid]").length,images:document.querySelectorAll("img").length,challenge:!!document.querySelector("input[type=password]")||[...document.querySelectorAll("iframe")].some(e=>String(e.getAttribute("src")||"").includes("cloudflare"))}})()';
async function probe(t,deadline=8000){
  return new Promise(resolve=>{
    if(!t?.webSocketDebuggerUrl||typeof WebSocket!=='function')return resolve({state:'NO_WEBSOCKET'});
    let ws,ended=false,stage='connect';
    const begin=Date.now();
    const timer=setTimeout(()=>end({state:'TIMEOUT',stage}),deadline);
    function end(data){
      if(ended)return;ended=true;clearTimeout(timer);try{ws?.close()}catch{}
      const result={...data,ms:Date.now()-begin};
      if(result.state==='OK')result.mounted=result.route==='/images'&&result.ready==='complete'&&result.bodyChildren>0&&
        (result.main||result.next||result.root||result.testIds>0||result.images>0);
      resolve(result)
    }
    try{
      ws=new WebSocket(t.webSocketDebuggerUrl);
      ws.addEventListener('open',()=>{
        stage='Runtime.evaluate';
        try{ws.send(JSON.stringify({id:9234,method:'Runtime.evaluate',params:{expression:inspectExpression,returnByValue:true,awaitPromise:false}}))}
        catch{end({state:'SEND_ERROR',stage})}
      },{once:true});
      ws.addEventListener('message',event=>{
        try{
          const msg=JSON.parse(String(event.data));
          if(msg.id!==9234)return;
          if(msg.error||msg.result?.exceptionDetails)return end({state:'CDP_EVALUATE_ERROR',stage});
          const v=msg.result?.result?.value;
          if(!v)return end({state:'NO_VALUE',stage});
          end({state:'OK',...v})
        }catch{end({state:'BAD_CDP_REPLY',stage})}
      });
      ws.addEventListener('error',()=>end({state:'WEBSOCKET_ERROR',stage}),{once:true});
      ws.addEventListener('close',()=>end({state:'WEBSOCKET_CLOSED',stage}),{once:true})
    }catch{end({state:'WEBSOCKET_CONNECT_ERROR',stage})}
  })
}
function powershell(command){
  const r=cp.spawnSync('powershell.exe',['-NoProfile','-NonInteractive','-Command',command],{encoding:'utf8',timeout:22000,windowsHide:true});
  return {ok:!r.error&&r.status===0,out:String(r.stdout||'').trim(),err:String(r.stderr||r.error?.message||'').trim()}
}
const busyScript='$ErrorActionPreference="Stop";$t=Get-ScheduledTask -TaskName "TT Image Relay - Telegram v2" -ErrorAction Stop;if([string]$t.State -ne "Ready"){Write-Output "TASK_BUSY";exit 3};$processes=@(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object{$_.Name -eq "node.exe" -and [string]$_.CommandLine -match "relay-captura|TTImageRelay.*captura|TTImageRelay.*capture"});if($processes.Count){Write-Output "CAPTURE_RUNNING";exit 4};Write-Output "IDLE"';
function requireIdle(){const r=powershell(busyScript);if(!r.ok||r.out!=='IDLE')throw Error('Capture not provably idle: '+(r.out||r.err||'unknown').slice(0,130))}
function recentFailure(){
  if(!fs.existsSync(REPORT))throw Error('Capture report missing');
  const age=(Date.now()-fs.statSync(REPORT).mtimeMs)/60000;
  let obj;try{obj=JSON.parse(fs.readFileSync(REPORT,'utf8'))}catch{throw Error('Capture report not valid JSON')}
  const match=/Galeria sin montar|pagina_no_lista|Timeout Runtime\.evaluate/i.test(String(obj.error||''));
  note('CAPTURE_REPORT age_min='+Math.round(age)+' matching_failure='+match);
  return age>=0&&age<=20&&match
}
async function closeTarget(id){
  if(!validId(id))throw Error('Invalid Chrome target ID');
  const r=await fetch(BASE+'/json/close/'+encodeURIComponent(id),{signal:AbortSignal.timeout(8000)});
  if(!r.ok)throw Error('Chrome refused target close HTTP '+r.status)
}
async function startCapture(){
  const script='$ErrorActionPreference="Stop";$t=Get-ScheduledTask -TaskName "TT Image Relay - Telegram v2" -ErrorAction Stop;if([string]$t.State -ne "Ready"){throw "Task busy"};$p=@(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object{$_.Name -eq "node.exe" -and [string]$_.CommandLine -match "relay-captura|TTImageRelay.*captura|TTImageRelay.*capture"});if($p.Count){throw "Capture already running"};Start-ScheduledTask -TaskName "TT Image Relay - Telegram v2" -ErrorAction Stop;Write-Output "CAPTURE_REQUESTED"';
  const r=powershell(script);
  note(r.ok&&r.out.includes('CAPTURE_REQUESTED')?'CAPTURE_REQUESTED via_existing_scheduled_task':'CAPTURE_NOT_REQUESTED will_retry_on_normal_five_minute_schedule')
}
// Diagnostic mode: metadata-only fresh gallery in Chrome9234.
// Inspect the new page and close only its newly-created target. Do not
// replace the existing gallery or run the capture task.
async function inspectFreshGallery(old){
  requireIdle();
  const initial=await targets();
  if(initial.filter(t=>t.type==='page').length!==1 ||
     initial.filter(t=>t.type==='page'&&galleryUrl(t.url)).length!==1)
     throw Error('Temporary probe deferred: ambiguous gallery state');
  const made=await requestJson(BASE+'/json/new?'+encodeURIComponent('https://chatgpt.com/images'),'PUT',15000);
  const id=String(made.id||'');
  if(!validId(id)||id===old.id)throw Error('Temporary probe could not verify new target');
  note('DIAG_TEMP_CREATED id_prefix='+id.slice(0,12));
  try{
    for(let k=0;k<5;k++){
      await pause(k===0?1800:k===1?2200:k===2?3300:4300);
      const all=await targets();
      const target=all.find(t=>t.type==='page'&&t.id===id);
      if(!target){note('DIAG_TEMP_GONE');break}
      const p=await probe(target,6500);
      const route=typeof p.route==='string'?p.route.slice(0,75):'?';
      note('DIAG_TEMP_'+(k+1)+' state='+p.state+
        ' route='+route+' cdptarget_image='+galleryUrl(target.url)+
        ' ready='+(p.ready||'?')+' children='+(p.bodyChildren??'?')+
        ' main='+!!p.main+' next='+!!p.next+' root='+!!p.root+
        ' testIds='+(p.testIds??'?')+' images='+(p.images??'?')+
        ' challenge='+!!p.challenge+' mounted='+!!p.mounted+' ms='+p.ms);
    }
  }finally{
    try{
      requireIdle();
      const all=await targets();
      const temp=all.find(t=>t.type==='page'&&t.id===id);
      const original=all.find(t=>t.type==='page'&&t.id===old.id&&galleryUrl(t.url));
      if(!temp)note('DIAG_TEMP_ALREADY_GONE');
      else if(!original||!galleryUrl(temp.url))note('DIAG_TEMP_PRESERVED target_changed_or_original_missing');
      else{await closeTarget(id);note('DIAG_TEMP_CLOSED exact_owned_target original_preserved=true')}
    }catch(e){note('DIAG_TEMP_CLEANUP_DEFERRED '+String(e.message||e).slice(0,140))}
  }
  note('DIAG_COMPLETE no_originals_or_telegram_changed');
}
async function run(){
  note('BEGIN apply='+APPLY);
  const version=await requestJson(BASE+'/json/version');
  if(!/^Chrome\//.test(String(version.Browser||'')))throw Error('Chrome 9234 not identified');
  const all=await targets(),pages=all.filter(t=>t.type==='page'),gallery=pages.filter(t=>galleryUrl(t.url));
  note('CHROME version='+version.Browser+' pages='+pages.length+' galleries='+gallery.length);
  if(pages.length!==1||gallery.length!==1||!validId(gallery[0].id))throw Error('Multiple/missing gallery pages, no changes');
  if(process.argv.includes('--inspect-fresh')){
    note('MODE inspect-fresh no existing gallery replaced');
    await inspectFreshGallery(gallery[0]);
    return;
  }
  const old=gallery[0],first=await probe(old);
  await pause(700);
  const second=await probe(old);
  note('EXISTING_PROBE first='+first.state+' mounted='+!!first.mounted+' ms='+first.ms+
    ' second='+second.state+' mounted='+!!second.mounted+' ms='+second.ms+
    ' ready='+(second.ready||'?')+' body='+String(second.bodyChildren??'?')+
    ' challenge='+!!second.challenge);
  if(first.mounted&&second.mounted&&!first.challenge&&!second.challenge){
    note('VIEWER_RESPONDS no_change=true capture_v2_3_evaluation_suspect=true');
    return
  }
  const failed=recentFailure();
  if(!APPLY){note('DIAG_ONLY no tabs changed');return}
  if(!failed)throw Error('No recent matching capture failure; refusing changes');
  requireIdle();
  const current=await targets(),currentPages=current.filter(t=>t.type==='page'),currentGallery=currentPages.filter(t=>galleryUrl(t.url));
  if(currentPages.length!==1||currentGallery.length!==1||currentGallery[0].id!==old.id)throw Error('Viewer changed during preflight');
  let newId='',newCreated=false,oldClosed=false;
  try{
    const made=await requestJson(BASE+'/json/new?'+encodeURIComponent('https://chatgpt.com/images'),'PUT',15000);
    newId=String(made.id||'');
    if(!validId(newId)||newId===old.id)throw Error('Chrome did not create distinct target');
    newCreated=true;note('NEW_GALLERY_CREATED id_prefix='+newId.slice(0,12));
    let mounted=false;
    for(let n=1;n<=15;n++){
      await pause(1600);
      const now=await targets();
      const fresh=now.find(t=>t.type==='page'&&t.id===newId&&galleryUrl(t.url));
      const original=now.find(t=>t.type==='page'&&t.id===old.id&&galleryUrl(t.url));
      if(!fresh||!original)throw Error('Original or new gallery disappeared during verification');
      const p=await probe(fresh,6500);
      if(n===1||n%3===0||p.mounted)note('NEW_PROBE pass='+n+' state='+p.state+' mounted='+!!p.mounted+' challenge='+!!p.challenge);
      if(p.mounted&&!p.challenge){
        await pause(600);
        const again=await probe(fresh,6500);
        if(again.mounted&&!again.challenge){mounted=true;break}
      }
    }
    if(!mounted)throw Error('Replacement gallery did not mount; original preserved');
    note('NEW_GALLERY_VALIDATED twice=true');
    requireIdle();
    const before=await targets(),a=before.find(t=>t.type==='page'&&t.id===old.id&&galleryUrl(t.url)),b=before.find(t=>t.type==='page'&&t.id===newId&&galleryUrl(t.url));
    if(!a||!b)throw Error('Gallery changed before old closure');
    const confirmed=await probe(b,6500);
    if(!confirmed.mounted||confirmed.challenge)throw Error('Replacement failed last mount check');
    await closeTarget(old.id);
    oldClosed=true;note('OLD_GALLERY_CLOSED old_id_prefix='+old.id.slice(0,12));
    const final=(await targets()).filter(t=>t.type==='page'&&galleryUrl(t.url));
    if(final.length!==1||final[0].id!==newId)throw Error('Unique replacement gallery not confirmed');
    note('RECOVERY_OK unique_gallery=1 chrome9223_untouched=true originals_untouched=true');
    await startCapture()
  }catch(err){
    note('RECOVERY_INCOMPLETE '+String(err.message||err).slice(0,180));
    if(newCreated&&!oldClosed){
      try{
        requireIdle();
        const now=await targets();
        const original=now.find(t=>t.type==='page'&&t.id===old.id&&galleryUrl(t.url));
        const temporary=now.find(t=>t.type==='page'&&t.id===newId&&galleryUrl(t.url));
        if(original&&temporary){await closeTarget(newId);note('ROLLBACK new_tab_closed original_preserved=true')}
        else note('ROLLBACK_SKIPPED changed_targets=true')
      }catch(e){note('ROLLBACK_SKIPPED '+String(e.message||e).slice(0,100))}
    }
    process.exitCode=1
  }
}
run().catch(e=>{note('STOPPED '+String(e.message||e).slice(0,200));process.exitCode=1}).finally(()=>note('REPORT '+LOG));
