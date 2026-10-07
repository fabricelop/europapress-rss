# Install-ImageBridge-ListenerChat.ps1
# Mantiene la logica estable v28/v29 y cambia SOLO el origen del chat:
# usa el chat abierto por el listener en vez de una pestaña CDP dedicada.
$ErrorActionPreference="Stop"
$BaseDir="C:\TTiTTulares"
$SourceRef="4dfe6648a51208af8e35201b0fd582653c5de2e9"

function Get-Pinned([string]$RepoPath,[string]$OutFile){
  $url="https://raw.githubusercontent.com/fabricelop/europapress-rss/"+$SourceRef+"/"+$RepoPath+"?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  Invoke-WebRequest -Uri $url -OutFile $OutFile -UseBasicParsing -Headers @{
    "User-Agent"="TT-image-listener-chat"
    "Cache-Control"="no-cache, no-store"
    "Pragma"="no-cache"
  } -TimeoutSec 30
  if(-not (Test-Path -LiteralPath $OutFile) -or (Get-Item -LiteralPath $OutFile).Length -lt 1000){
    throw "Descarga invalida: $RepoPath"
  }
}
function Validate([string]$File,[string]$Label){
  $node=Get-Command node.exe -ErrorAction SilentlyContinue
  if(-not $node){$node=Get-Command node -ErrorAction SilentlyContinue}
  if(-not $node){throw "No encuentro Node.js"}
  & $node.Source --check $File 1>$null 2>$null
  if($LASTEXITCODE -ne 0){throw "node --check fallo: $Label"}
  $txt=Get-Content -LiteralPath $File -Raw -Encoding UTF8
  if(-not $txt.Contains('BRIDGE_MODE="capture-only-v28-dead-submit-retry"')){throw "$Label no conserva v28"}
  if(-not $txt.Contains('BRIDGE LISTENER CHAT ATTACHED')){throw "$Label no contiene listener-chat"}
}
New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
$tt=Join-Path $BaseDir "TTiTTularesImageBridge.js"
$tr=Join-Path $BaseDir "TTendenciasImageBridge.js"
$ttTmp=Join-Path $BaseDir "TTiTTularesImageBridge.listenerchat.new.js"
$trTmp=Join-Path $BaseDir "TTendenciasImageBridge.listenerchat.new.js"
Get-Pinned "windows/TTiTTularesImageBridge.js" $ttTmp
Get-Pinned "windows/TTendenciasImageBridge.js" $trTmp
Validate $ttTmp "TTiTTulares"
Validate $trTmp "TTendencias"

# Detener SOLO bridges de imagen actuales. Los listeners siguen vivos.
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

Write-Host "BRIDGES ESTABLES INSTALADOS EN MODO LISTENER-CHAT" -ForegroundColor Green
Write-Host "TTiTTulares: v28/v29 + chat del listener"
Write-Host "TTendencias: v28 + chat del listener"
Write-Host "Listeners/watchdog/updater: sin cambios"
