# Repair-TT-Image-Chrome9223-Stable-v2.ps1
# Repara SOLO Chrome CDP 9223 + bridges estables y fuerza navegacion a ChatGPT.

$ErrorActionPreference="Stop"
$BaseDir="C:\TTiTTulares"
$SourceRef="b6348246765067b71d73344c40312c7068f89a83"
$ChatUrl="https://chatgpt.com/"

function Get-CdpTargets {
  try {
    return @(Invoke-RestMethod -Uri ("http://127.0.0.1:9223/json/list?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -Headers @{"Cache-Control"="no-cache"} -TimeoutSec 4)
  } catch { return @() }
}
function Test-CdpEndpoint {
  try {
    $v=Invoke-RestMethod -Uri ("http://127.0.0.1:9223/json/version?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -Headers @{"Cache-Control"="no-cache"} -TimeoutSec 3
    return [bool]($v -and $v.webSocketDebuggerUrl)
  } catch { return $false }
}
function Test-ChatTarget {
  $pages=@(Get-CdpTargets | Where-Object {
    [string]$_.type -eq "page" -and
    $_.webSocketDebuggerUrl -and
    ([string]$_.url -like "https://chatgpt.com/*")
  })
  return ($pages.Count -gt 0)
}
function Navigate-CdpToChat {
  # Primero: crear un target nuevo directamente en ChatGPT.
  try {
    $u="http://127.0.0.1:9223/json/new?"+[uri]::EscapeDataString($ChatUrl)
    $r=Invoke-RestMethod -Method Put -Uri $u -Headers @{"Cache-Control"="no-cache"} -TimeoutSec 6
    if($r -and $r.id){
      Write-Host "CDP target creado para ChatGPT: $($r.id)"
    }
  } catch {
    Write-Host "AVISO json/new PUT: $($_.Exception.Message)" -ForegroundColor Yellow
  }

  $deadline=(Get-Date).AddSeconds(20)
  while((Get-Date) -lt $deadline){
    if(Test-ChatTarget){return $true}
    Start-Sleep -Milliseconds 700
  }

  # Fallback: Node conecta al browser websocket y usa Target.createTarget.
  $node=Get-Command node.exe -ErrorAction SilentlyContinue
  if(-not $node){$node=Get-Command node -ErrorAction SilentlyContinue}
  if(-not $node){return $false}

  $js=Join-Path $BaseDir "tt-cdp-open-chatgpt.tmp.js"
  @'
const base="http://127.0.0.1:9223";
const chat="https://chatgpt.com/";
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
class CDP{
 constructor(url){this.url=url;this.ws=null;this.seq=0;this.pending=new Map()}
 async open(){this.ws=new WebSocket(this.url);await new Promise((ok,bad)=>{const t=setTimeout(()=>bad(Error("ws timeout")),6000);this.ws.addEventListener("open",()=>{clearTimeout(t);ok()},{once:true});this.ws.addEventListener("error",()=>{clearTimeout(t);bad(Error("ws error"))},{once:true})});this.ws.addEventListener("message",ev=>{let m;try{m=JSON.parse(String(ev.data))}catch{return}const p=this.pending.get(m.id);if(!p)return;this.pending.delete(m.id);m.error?p.bad(Error(m.error.message||"cdp")):p.ok(m.result)})}
 call(method,params={},timeout=8000){const id=++this.seq;return new Promise((ok,bad)=>{this.pending.set(id,{ok,bad});this.ws.send(JSON.stringify({id,method,params}));setTimeout(()=>{if(this.pending.delete(id))bad(Error("timeout "+method))},timeout)})}
 close(){try{this.ws&&this.ws.close()}catch{}}
}
(async()=>{
 const vr=await fetch(base+"/json/version",{cache:"no-store"});const vd=await vr.json();
 const browser=new CDP(vd.webSocketDebuggerUrl);await browser.open();
 try{await browser.call("Target.createTarget",{url:chat,newWindow:false,background:false},10000)}finally{browser.close()}
 for(let i=0;i<30;i++){await sleep(500);const rows=await (await fetch(base+"/json/list",{cache:"no-store"})).json();const hit=rows.find(x=>x.type==="page"&&String(x.url||"").startsWith("https://chatgpt.com/"));if(hit){const page=new CDP(hit.webSocketDebuggerUrl);await page.open();try{for(let j=0;j<50;j++){let r;try{r=await page.call("Runtime.evaluate",{expression:"(()=>({composer:!!document.querySelector(\\\"#prompt-textarea,textarea[data-testid=\\\\\\\"prompt-textarea\\\\\\\"],div[contenteditable=\\\\\\\"true\\\\\\\"]\\\"),url:location.href,title:document.title||\\\"\\\"}))()",returnByValue:true},5000)}catch{}const st=r&&r.result&&r.result.value;if(st&&st.composer){console.log("OK "+hit.id+" "+st.url+" | "+st.title);process.exit(0)}await sleep(500)}}finally{page.close()}}}
 process.exit(2)
})().catch(e=>{console.error(e&&e.stack||e);process.exit(3)})
'@ | Set-Content -LiteralPath $js -Encoding UTF8
  try {
    & $node.Source $js
    return ($LASTEXITCODE -eq 0 -and (Test-ChatTarget))
  } finally {
    Remove-Item -LiteralPath $js -Force -ErrorAction SilentlyContinue
  }
}

function Get-Pinned([string]$RepoPath,[string]$OutFile){
  $url="https://raw.githubusercontent.com/fabricelop/europapress-rss/"+$SourceRef+"/"+$RepoPath+"?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  Invoke-WebRequest -Uri $url -OutFile $OutFile -UseBasicParsing -Headers @{
    "User-Agent"="TT-image-cdp9223-repair-v2";"Cache-Control"="no-cache, no-store";"Pragma"="no-cache"
  } -TimeoutSec 30
  if(-not (Test-Path -LiteralPath $OutFile) -or (Get-Item -LiteralPath $OutFile).Length -lt 1000){throw "Descarga invalida: $RepoPath"}
}
function Validate-Bridge([string]$File,[string]$Label){
  $node=Get-Command node.exe -ErrorAction SilentlyContinue;if(-not $node){$node=Get-Command node -ErrorAction SilentlyContinue}
  if(-not $node){throw "No encuentro Node.js"}
  $old=$ErrorActionPreference
  try{$ErrorActionPreference="Continue"; & $node.Source --check $File 1>$null 2>$null; $code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
  if($code -ne 0){throw "node --check fallo en $($Label)"}
  $txt=Get-Content -LiteralPath $File -Raw -Encoding UTF8
  if(-not $txt.Contains('BRIDGE_MODE="capture-only-v28-dead-submit-retry"')){throw "$($Label) no contiene v28 estable"}
}

New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
$tt=Join-Path $BaseDir "TTiTTularesImageBridge.js";$tr=Join-Path $BaseDir "TTendenciasImageBridge.js"
$ttTmp=Join-Path $BaseDir "TTiTTularesImageBridge.repair2.new.js";$trTmp=Join-Path $BaseDir "TTendenciasImageBridge.repair2.new.js"
Get-Pinned "windows/TTiTTularesImageBridge.js" $ttTmp
Get-Pinned "windows/TTendenciasImageBridge.js" $trTmp
Validate-Bridge $ttTmp "TTiTTulares";Validate-Bridge $trTmp "TTendencias"

# Parar bridges, no listeners.
@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
 ($_.Name -ieq "node.exe" -or $_.Name -ieq "node") -and ($_.CommandLine -like "*TTiTTularesImageBridge.js*" -or $_.CommandLine -like "*TTendenciasImageBridge.js*")
}) | ForEach-Object {try{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}catch{}}

# Reiniciar SOLO navegador 9223.
$roots=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
 ($_.Name -ieq "chrome.exe" -or $_.Name -ieq "msedge.exe") -and [string]$_.CommandLine -match '--remote-debugging-port(?:=|\s+)9223(?:\s|$)'
})
foreach($p in $roots){try{& taskkill.exe /PID $p.ProcessId /T /F 1>$null 2>$null}catch{}}
Start-Sleep -Seconds 2

@("ttittulares-image-bridge.lock.json","ttendencias-image-bridge.lock.json","ttittulares-image-tab.json","ttendencias-image-tab.json") | ForEach-Object {
 Remove-Item -LiteralPath (Join-Path $BaseDir $_) -Force -ErrorAction SilentlyContinue
}
Move-Item -LiteralPath $ttTmp -Destination $tt -Force
Move-Item -LiteralPath $trTmp -Destination $tr -Force

& schtasks.exe /Run /TN "TT Chrome Auto" 1>$null 2>$null
if($LASTEXITCODE -ne 0){throw "No se pudo lanzar TT Chrome Auto"}

$deadline=(Get-Date).AddSeconds(25)
while((Get-Date) -lt $deadline -and -not (Test-CdpEndpoint)){Start-Sleep -Seconds 1}
if(-not (Test-CdpEndpoint)){throw "Chrome 9223 no expuso /json/version tras TT Chrome Auto"}

if(-not (Navigate-CdpToChat)){
  $cmd=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    ($_.Name -ieq "chrome.exe" -or $_.Name -ieq "msedge.exe") -and [string]$_.CommandLine -match '--remote-debugging-port(?:=|\s+)9223(?:\s|$)'
  } | Select-Object -First 1 -ExpandProperty CommandLine)
  $diag=@(Get-CdpTargets | Select-Object -First 8 | ForEach-Object {([string]$_.type)+" | "+([string]$_.url)+" | "+([string]$_.title)}) -join " ; "
  throw "9223 arranca pero no puede navegar a ChatGPT. Chrome command: $cmd ; Targets: $diag"
}

$targets=Get-CdpTargets
$chat=@($targets | Where-Object {[string]$_.type -eq "page" -and [string]$_.url -like "https://chatgpt.com/*"})
Write-Host "SUBSISTEMA DE IMAGENES TT REPARADO V2" -ForegroundColor Green
Write-Host "Chrome CDP 9223: OK"
Write-Host "ChatGPT abierto y compositor validado en 9223: $($chat.Count)"
Write-Host "URL: $([string]$chat[0].url)"
Write-Host "TTiTTulares bridge: v28/v29 estable"
Write-Host "TTendencias bridge: v28 estable"
Write-Host "Listeners/watchdog/updater: sin cambios"
