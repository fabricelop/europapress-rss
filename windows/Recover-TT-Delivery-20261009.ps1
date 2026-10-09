# Recover-TT-Delivery-20261009.ps1
# Recupera ambos listeners, los puentes de imagen y Chrome dedicado 9223.
# Conserva las colas remotas, los estados locales y Ejecutar.js. No despliega apps.
$ErrorActionPreference = "Stop"
$Root = "C:\TTiTTulares"
$BaseUrl = "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/windows/"
New-Item -ItemType Directory -Path $Root -Force | Out-Null

function Say([string]$Text) { Write-Host ("[TT RECOVERY] " + $Text) }
function Download-Current([string]$Name, [string]$Kind) {
  $dest = Join-Path $Root $Name
  $tmp = $dest + ".recovery-new." + $Kind
  $url = $BaseUrl + $Name + "?ts=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 30 -Headers @{"Cache-Control"="no-cache";"User-Agent"="TT-Delivery-Recovery-20261009"}
  if ((Get-Item $tmp).Length -lt 1000) { throw "Descarga incompleta: $Name" }
  if ($Kind -eq "ps") {
    $t=$null; $e=$null
    [void][Management.Automation.Language.Parser]::ParseFile($tmp,[ref]$t,[ref]$e)
    if ($e.Count -gt 0) { throw ("Sintaxis PowerShell incorrecta: " + $Name + " " + $e[0].Message) }
  } else {
    $node = Get-Command node.exe -ErrorAction Stop
    & $node.Source --check $tmp
    if ($LASTEXITCODE -ne 0) { throw ("Sintaxis JavaScript incorrecta: " + $Name) }
  }
  return [pscustomobject]@{Name=$Name;Source=$tmp;Destination=$dest}
}

Say "Descargando y comprobando versiones de main"
$files = @(
  (Download-Current "TTiTTularesDedicatedListener.ps1" "ps"),
  (Download-Current "TTendenciasDedicatedListener.ps1" "ps"),
  (Download-Current "TTiTTularesImageBridge.js" "js"),
  (Download-Current "TTendenciasImageBridge.js" "js"),
  (Download-Current "TT-LocalWatchdog.ps1" "ps"),
  (Download-Current "TT-AutoUpdater.ps1" "ps")
)
if (-not (Test-Path (Join-Path $Root "Ejecutar.js"))) { throw "Falta el lanzador existente C:\TTiTTulares\Ejecutar.js; no se modifica" }

Say "Deteniendo solo componentes TT dedicados (sin tocar Chrome personal)"
$patterns = @(
  "*TTiTTularesDedicatedListener.ps1*", "*TTendenciasDedicatedListener.ps1*",
  "*TTiTTularesImageBridge.js*", "*TTendenciasImageBridge.js*",
  "*TT-LocalWatchdog.ps1*", "*TT-AutoUpdater.ps1*"
)
$processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
  $_.Name -in @("powershell.exe","pwsh.exe","node.exe") -and $_.ProcessId -ne $PID
})
foreach ($p in $processes) {
  foreach ($pattern in $patterns) {
    if ([string]$p.CommandLine -like $pattern) {
      try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch { Say ("AVISO stop pid=" + $p.ProcessId + " " + $_.Exception.Message) }
      break
    }
  }
}
Start-Sleep -Seconds 1
foreach ($f in $files) { Move-Item -LiteralPath $f.Source -Destination $f.Destination -Force }
Say "Listeners y bridges actualizados; Ejecutar.js intacto"

$chromeRoots = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
  $_.Name -in @("chrome.exe","msedge.exe") -and
  [string]$_.CommandLine -match '--remote-debugging-port(?:=|\s+)9223(?:\s|$)'
})
foreach ($p in $chromeRoots) {
  try { & taskkill.exe /PID $p.ProcessId /T /F 1>$null 2>$null } catch {}
}
foreach ($name in @("ttittulares-image-tab.json","ttendencias-image-tab.json","ttittulares-image-bridge.lock.json","ttendencias-image-bridge.lock.json")) {
  Remove-Item -LiteralPath (Join-Path $Root $name) -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 2
Say "Iniciando Chrome dedicado mediante TT Chrome Auto"
& schtasks.exe /Run /TN "TT Chrome Auto" | Out-Host
if ($LASTEXITCODE -ne 0) { throw "No ha arrancado la tarea TT Chrome Auto" }
$deadline = (Get-Date).AddSeconds(35)
$cdpOk = $false
while ((Get-Date) -lt $deadline) {
  try {
    $v=Invoke-RestMethod -Uri "http://127.0.0.1:9223/json/version" -TimeoutSec 3
    if ($v.webSocketDebuggerUrl) { $cdpOk=$true; break }
  } catch {}
  Start-Sleep -Seconds 1
}
if (-not $cdpOk) { Say "AVISO: Chrome 9223 no devuelve websocket de CDP" }

# El test real incluye navegacion y compositor, no solo que el puerto este abierto.
$checkPath = Join-Path $env:TEMP "tt-check-chatgpt-cdp-20261009.js"
@'
const BASE="http://127.0.0.1:9223";
const CHAT="https://chatgpt.com/";
const pause=ms=>new Promise(r=>setTimeout(r,ms));
class Cdp {
  constructor(url){this.url=url;this.ws=null;this.i=0;this.pending=new Map();}
  async open(){
    this.ws=new WebSocket(this.url);
    await new Promise((ok,bad)=>{
      const t=setTimeout(()=>bad(Error("CDP websocket timeout")),7000);
      this.ws.addEventListener("open",()=>{clearTimeout(t);ok()}, {once:true});
      this.ws.addEventListener("error",()=>{clearTimeout(t);bad(Error("CDP websocket error"))},{once:true});
    });
    this.ws.addEventListener("message", ev=>{
      let data;try{data=JSON.parse(String(ev.data));}catch{return;}
      const p=this.pending.get(data.id);if(!p)return;
      this.pending.delete(data.id);
      data.error?p.bad(Error(data.error.message||"CDP error")):p.ok(data.result);
    });
  }
  call(method,params={},timeout=12000){
    const id=++this.i;
    return new Promise((ok,bad)=>{
      const timer=setTimeout(()=>{if(this.pending.delete(id))bad(Error("CDP timeout "+method));},timeout);
      this.pending.set(id,{ok:x=>{clearTimeout(timer);ok(x);},bad:e=>{clearTimeout(timer);bad(e);}});
      try{this.ws.send(JSON.stringify({id,method,params}));}catch(e){clearTimeout(timer);this.pending.delete(id);bad(e);}
    });
  }
  close(){try{this.ws?.close();}catch{}}
}
async function run(){
  const r=await fetch(BASE+"/json/version",{signal:AbortSignal.timeout(6000)});
  const version=await r.json();
  if(!version.webSocketDebuggerUrl)throw Error("Chrome sin browser websocket");
  const b=new Cdp(version.webSocketDebuggerUrl);
  await b.open();
  let created;
  try{created=await b.call("Target.createTarget",{url:CHAT,newWindow:false,background:false});}
  finally{b.close();}
  const id=String(created?.targetId||"");
  if(!id)throw Error("No se pudo abrir la pestaña ChatGPT con CDP");
  console.log("CDP_NEW_TARGET "+id);
  let last={url:"",title:"",composer:false};
  for(let i=0;i<45;i++){
    await pause(750);
    let rows;
    try{rows=await (await fetch(BASE+"/json/list",{signal:AbortSignal.timeout(4000)})).json();}
    catch{continue;}
    const tab=rows.find(x=>x.id===id && x.type==="page" && x.webSocketDebuggerUrl);
    if(!tab)continue;
    const c=new Cdp(tab.webSocketDebuggerUrl);
    try{
      await c.open();
      const result=await c.call("Runtime.evaluate",{
        expression:"(()=>({url:location.href,title:document.title||'',composer:!!document.querySelector('#prompt-textarea,[data-testid=\"prompt-textarea\"],textarea,div[contenteditable=\"true\"]'),state:document.readyState}))()",
        returnByValue:true
      },5000);
      last=result?.result?.value||last;
      if(String(last.url).startsWith(CHAT) && last.composer){
        console.log("CHATGPT_COMPOSER_OK "+last.url);
        return;
      }
    }catch{}
    finally{c.close();}
  }
  console.error("CHATGPT_COMPOSER_NOT_READY "+JSON.stringify(last));
  process.exitCode=2;
}
run().catch(e=>{console.error("CDP_CHECK_ERROR "+String(e.stack||e));process.exitCode=3;});
'@ | Set-Content -LiteralPath $checkPath -Encoding ASCII
$chatOk = $false
if ($cdpOk) {
  Say "Comprobando navegación a ChatGPT y compositor"
  & node.exe $checkPath
  $chatOk = ($LASTEXITCODE -eq 0)
}
Remove-Item -LiteralPath $checkPath -Force -ErrorAction SilentlyContinue

function Start-Listener([string]$Script, [string]$Tag) {
  $file=Join-Path $Root $Script
  $out=Join-Path $Root ($Tag+".recovery.out.log")
  $err=Join-Path $Root ($Tag+".recovery.err.log")
  $proc=Start-Process powershell.exe -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$file) -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
  Start-Sleep -Milliseconds 900
  $proc.Refresh()
  if ($proc.HasExited) { Say ("ERROR: "+$Script+" terminó. Ver "+$err) }
  else { Say ("ACTIVO "+$Script+" PID "+$proc.Id) }
}
Say "Restableciendo updater, watchdog y listeners"
Start-Listener "TT-AutoUpdater.ps1" "tt-updater"
Start-Listener "TTiTTularesDedicatedListener.ps1" "ttittulares"
Start-Listener "TTendenciasDedicatedListener.ps1" "ttendencias"
Start-Listener "TT-LocalWatchdog.ps1" "tt-watchdog"
Write-Host ""
Write-Host ("CHROME_9223_CDP=" + $cdpOk)
Write-Host ("CHATGPT_COMPOSER=" + $chatOk)
Write-Host "COLAS_GITHUB=CONSERVADAS"
Write-Host "EJECUTAR_JS=NO_MODIFICADO"
Write-Host "LOG_TT=C:\TTiTTulares\ttittulares-mobile-trigger.log"
Write-Host "LOG_TR=C:\TTiTTulares\ttendencias-mobile-trigger.log"
if (-not $chatOk) {
  Write-Host "ATENCION: Chrome responde, pero el compositor de ChatGPT no se ha verificado. Abre la ventana dedicada de Chrome y comprueba que ChatGPT haya cargado y siga autenticado." -ForegroundColor Yellow
} else {
  Write-Host "Recuperación local lanzada. Los trabajos REQUESTED siguen en cola para su recogida." -ForegroundColor Green
}
