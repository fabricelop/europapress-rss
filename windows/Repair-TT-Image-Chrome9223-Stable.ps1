# Repair-TT-Image-Chrome9223-Stable.ps1
# Repara SOLO el subsistema de imagenes TT:
# - Chrome/Edge dedicado CDP 9223
# - bridges probados v28/v29
# - locks y target_id persistidos
# No toca listeners, watchdog, updater, editorial ni apps.

$ErrorActionPreference="Stop"
$BaseDir="C:\TTiTTulares"
$SourceRef="b6348246765067b71d73344c40312c7068f89a83"

function Test-ImageChromeHealthy {
  try {
    $stamp=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $v=Invoke-RestMethod -Uri ("http://127.0.0.1:9223/json/version?t="+$stamp) -Headers @{"Cache-Control"="no-cache"} -TimeoutSec 3
    if(-not $v -or -not $v.webSocketDebuggerUrl){return $false}
    $targets=Invoke-RestMethod -Uri ("http://127.0.0.1:9223/json/list?t="+$stamp) -Headers @{"Cache-Control"="no-cache"} -TimeoutSec 4
    $chat=@($targets | Where-Object {
      [string]$_.type -eq "page" -and
      $_.webSocketDebuggerUrl -and
      (([string]$_.url -like "https://chatgpt.com/*") -or ([string]$_.url -eq "https://chatgpt.com/"))
    })
    return ($chat.Count -gt 0)
  } catch { return $false }
}

function Get-Pinned([string]$RepoPath,[string]$OutFile){
  $url="https://raw.githubusercontent.com/fabricelop/europapress-rss/"+$SourceRef+"/"+$RepoPath+"?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  Invoke-WebRequest -Uri $url -OutFile $OutFile -UseBasicParsing -Headers @{
    "User-Agent"="TT-image-cdp9223-repair"
    "Cache-Control"="no-cache, no-store"
    "Pragma"="no-cache"
  } -TimeoutSec 30
  if(-not (Test-Path -LiteralPath $OutFile) -or (Get-Item -LiteralPath $OutFile).Length -lt 1000){
    throw "Descarga invalida: $RepoPath"
  }
}

function Validate-Bridge([string]$File,[string]$Label){
  $node=Get-Command node.exe -ErrorAction SilentlyContinue
  if(-not $node){$node=Get-Command node -ErrorAction SilentlyContinue}
  if(-not $node){throw "No encuentro Node.js"}
  $old=$ErrorActionPreference
  try{
    $ErrorActionPreference="Continue"
    & $node.Source --check $File 1>$null 2>$null
    $code=$LASTEXITCODE
  }finally{$ErrorActionPreference=$old}
  if($code -ne 0){throw "node --check fallo en $($Label)"}
  $txt=Get-Content -LiteralPath $File -Raw -Encoding UTF8
  if(-not $txt.Contains('BRIDGE_MODE="capture-only-v28-dead-submit-retry"')){throw "$($Label) no contiene v28 estable"}
  if(-not $txt.Contains('view=image-job&strong=1&id=')){throw "$($Label) no contiene lectura fuerte del job"}
}

New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null

$tt=Join-Path $BaseDir "TTiTTularesImageBridge.js"
$tr=Join-Path $BaseDir "TTendenciasImageBridge.js"
$ttTmp=Join-Path $BaseDir "TTiTTularesImageBridge.repair.new.js"
$trTmp=Join-Path $BaseDir "TTendenciasImageBridge.repair.new.js"

Get-Pinned "windows/TTiTTularesImageBridge.js" $ttTmp
Get-Pinned "windows/TTendenciasImageBridge.js" $trTmp
Validate-Bridge $ttTmp "TTiTTulares"
Validate-Bridge $trTmp "TTendencias"

@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
  ($_.Name -ieq "node.exe" -or $_.Name -ieq "node") -and
  ($_.CommandLine -like "*TTiTTularesImageBridge.js*" -or $_.CommandLine -like "*TTendenciasImageBridge.js*")
}) | ForEach-Object {
  try{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}catch{}
}
Start-Sleep -Milliseconds 500

$roots=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
  ($_.Name -ieq "chrome.exe" -or $_.Name -ieq "msedge.exe") -and
  [string]$_.CommandLine -match '--remote-debugging-port(?:=|\s+)9223(?:\s|$)'
})
foreach($p in $roots){
  try{& taskkill.exe /PID $p.ProcessId /T /F 1>$null 2>$null}catch{}
}
Start-Sleep -Seconds 2

@(
  "ttittulares-image-bridge.lock.json",
  "ttendencias-image-bridge.lock.json",
  "ttittulares-image-tab.json",
  "ttendencias-image-tab.json"
) | ForEach-Object {
  Remove-Item -LiteralPath (Join-Path $BaseDir $_) -Force -ErrorAction SilentlyContinue
}

Move-Item -LiteralPath $ttTmp -Destination $tt -Force
Move-Item -LiteralPath $trTmp -Destination $tr -Force

$task = & schtasks.exe /Query /TN "TT Chrome Auto" 2>&1
if($LASTEXITCODE -ne 0){throw "No existe o no se puede consultar la tarea TT Chrome Auto"}
& schtasks.exe /Run /TN "TT Chrome Auto" 1>$null 2>$null
if($LASTEXITCODE -ne 0){throw "No se pudo lanzar la tarea TT Chrome Auto"}

$deadline=(Get-Date).AddSeconds(35)
$healthy=$false
while((Get-Date) -lt $deadline){
  if(Test-ImageChromeHealthy){$healthy=$true;break}
  Start-Sleep -Seconds 1
}
if(-not $healthy){
  $diag=""
  try{
    $targets=Invoke-RestMethod -Uri ("http://127.0.0.1:9223/json/list?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -TimeoutSec 3
    $diag=(@($targets | Select-Object -First 8 | ForEach-Object {([string]$_.type)+" | "+([string]$_.url)+" | "+([string]$_.title)}) -join " ; ")
  }catch{$diag=$_.Exception.Message}
  throw "Chrome CDP 9223 no quedo saludable tras TT Chrome Auto. Targets: $diag"
}

$targets=Invoke-RestMethod -Uri ("http://127.0.0.1:9223/json/list?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -TimeoutSec 4
$chat=@($targets | Where-Object {
  [string]$_.type -eq "page" -and
  (([string]$_.url -like "https://chatgpt.com/*") -or ([string]$_.url -eq "https://chatgpt.com/"))
})

Write-Host "SUBSISTEMA DE IMAGENES TT REPARADO" -ForegroundColor Green
Write-Host "Chrome CDP 9223: OK"
Write-Host "Paginas ChatGPT visibles en 9223: $($chat.Count)"
Write-Host "TTiTTulares bridge: v28/v29 estable"
Write-Host "TTendencias bridge: v28 estable"
Write-Host "Targets/locks antiguos: limpiados"
Write-Host "Listeners/watchdog/updater: sin cambios"
