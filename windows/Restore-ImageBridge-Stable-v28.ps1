# Restore-ImageBridge-Stable-v28.ps1
# Restaura EXACTAMENTE los bridges que dieron DONE reales el 6-Oct-2026.
# TTendencias source snapshot: 586bfeb9f24a20759b88274cc9cac988d874e06c
# TTiTTulares source snapshot: 14971ad19b296b9cf3d86caa0f863234149d357d

$ErrorActionPreference="Stop"
$BaseDir="C:\TTiTTulares"
$MainRef="1e6149480230c480775c9d0df6452938d12306a1"

function Get-Pinned([string]$RepoPath,[string]$OutFile){
  $url="https://raw.githubusercontent.com/fabricelop/europapress-rss/"+$MainRef+"/"+$RepoPath+"?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  Invoke-WebRequest -Uri $url -OutFile $OutFile -UseBasicParsing -Headers @{
    "User-Agent"="TT-image-stable-v28-restore"
    "Cache-Control"="no-cache, no-store"
    "Pragma"="no-cache"
  } -TimeoutSec 30
  if(-not (Test-Path -LiteralPath $OutFile) -or (Get-Item -LiteralPath $OutFile).Length -lt 1000){
    throw "Descarga invalida: $RepoPath"
  }
}

function Validate-Bridge([string]$File,[string]$Kind){
  $node=Get-Command node.exe -ErrorAction SilentlyContinue
  if(-not $node){$node=Get-Command node -ErrorAction SilentlyContinue}
  if(-not $node){throw "No encuentro Node.js"}
  & $node.Source --check $File 1>$null 2>$null
  if($LASTEXITCODE -ne 0){throw "node --check fallo: $File"}
  $txt=Get-Content -LiteralPath $File -Raw -Encoding UTF8
  if(-not $txt.Contains('BRIDGE_MODE="capture-only-v28-dead-submit-retry"')){
    throw "$Kind no contiene el bridge v28 estable"
  }
  if(-not $txt.Contains('view=image-job&strong=1&id=')){
    throw "$Kind no contiene lectura fuerte del job"
  }
  if(-not $txt.Contains('BRIDGE SUBMIT VERIFY WARNING')){
    throw "$Kind no contiene validacion de envio esperada"
  }
  if($Kind -eq "TTiTTulares" -and -not $txt.Contains('BRIDGE_FEATURES="v29-visible-composer-trusted-click-dom-fallback"')){
    throw "TTiTTulares no contiene funciones v29 estables"
  }
}

New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null

$tt=Join-Path $BaseDir "TTiTTularesImageBridge.js"
$tr=Join-Path $BaseDir "TTendenciasImageBridge.js"
$ttTmp=Join-Path $BaseDir "TTiTTularesImageBridge.stable.new.js"
$trTmp=Join-Path $BaseDir "TTendenciasImageBridge.stable.new.js"

Get-Pinned "windows/TTiTTularesImageBridge.js" $ttTmp
Get-Pinned "windows/TTendenciasImageBridge.js" $trTmp
Validate-Bridge $ttTmp "TTiTTulares"
Validate-Bridge $trTmp "TTendencias"

# Matar SOLO bridges de imagen actuales/orfanados.
@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
  ($_.Name -ieq "node.exe" -or $_.Name -ieq "node") -and
  ($_.CommandLine -like "*TTiTTularesImageBridge.js*" -or $_.CommandLine -like "*TTendenciasImageBridge.js*")
}) | ForEach-Object {
  try{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}catch{}
}
Start-Sleep -Milliseconds 500

Move-Item -LiteralPath $ttTmp -Destination $tt -Force
Move-Item -LiteralPath $trTmp -Destination $tr -Force

Remove-Item -LiteralPath (Join-Path $BaseDir "ttittulares-image-bridge.lock.json") -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $BaseDir "ttendencias-image-bridge.lock.json") -Force -ErrorAction SilentlyContinue

Write-Host "IMAGENES RESTAURADAS A VERSION ESTABLE PROBADA" -ForegroundColor Green
Write-Host "TTiTTulares: v28/v29 estable (DONE reales 06-Oct 19:10 y 19:28)"
Write-Host "TTendencias: v28 estable (5 DONE consecutivos 06-Oct 18:26-18:33)"
Write-Host "Listeners/watchdog/updater: sin cambios"
