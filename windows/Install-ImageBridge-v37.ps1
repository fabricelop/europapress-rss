# Install-ImageBridge-v37.ps1
# Hotfix minimo: sustituye SOLO los bridges de imagen por v37.
# No toca listeners, watchdog, updater, Ejecutar.js ni logica editorial.

$ErrorActionPreference="Stop"
$BaseDir="C:\TTiTTulares"
$SourceRef="837b69fb4fb2a8f4689f68e276f773c0bd3f28cd"

function Get-PinnedFile([string]$RepoPath,[string]$OutFile){
  $url="https://raw.githubusercontent.com/fabricelop/europapress-rss/"+$SourceRef+"/"+$RepoPath+"?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  Invoke-WebRequest -Uri $url -OutFile $OutFile -UseBasicParsing -Headers @{
    "User-Agent"="TT-image-v37-hotfix"
    "Cache-Control"="no-cache, no-store"
    "Pragma"="no-cache"
  } -TimeoutSec 30
  if(-not (Test-Path -LiteralPath $OutFile) -or (Get-Item -LiteralPath $OutFile).Length -lt 1000){
    throw "Descarga invalida: $RepoPath"
  }
}

function Validate-Node([string]$File,[string]$Needle){
  $node=Get-Command node.exe -ErrorAction SilentlyContinue
  if(-not $node){$node=Get-Command node -ErrorAction SilentlyContinue}
  if(-not $node){throw "No encuentro Node.js"}
  $old=$ErrorActionPreference
  try{
    $ErrorActionPreference="Continue"
    & $node.Source --check $File 1>$null 2>$null
    $code=$LASTEXITCODE
  }finally{$ErrorActionPreference=$old}
  if($code -ne 0){throw "node --check fallo: $File"}
  $txt=Get-Content -LiteralPath $File -Raw -Encoding UTF8
  if(-not $txt.Contains($Needle)){throw "El bridge descargado no es v37: $File"}
  if(-not $txt.Contains('BRIDGE COMMAND SCAN ATTACHED')){throw "Falta escaneo por command_id en $File"}
  if(-not $txt.Contains('BRIDGE REACQUIRE FIXED TAB REJECTED')){throw "Falta rechazo de pestaña fija invalida en $File"}
}

New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null

$tt=Join-Path $BaseDir "TTiTTularesImageBridge.js"
$tr=Join-Path $BaseDir "TTendenciasImageBridge.js"
$ttTmp=Join-Path $BaseDir "TTiTTularesImageBridge.v37.new.js"
$trTmp=Join-Path $BaseDir "TTendenciasImageBridge.v37.new.js"

Get-PinnedFile "windows/TTiTTularesImageBridge.js" $ttTmp
Get-PinnedFile "windows/TTendenciasImageBridge.js" $trTmp
Validate-Node $ttTmp "ttittulares-image-bridge-v37-command-scan"
Validate-Node $trTmp "ttendencias-image-bridge-v37-command-scan"

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

Write-Host "HOTFIX IMAGEN v37 INSTALADO" -ForegroundColor Green
Write-Host "TTiTTulares bridge: v37 command-scan"
Write-Host "TTendencias bridge: v37 command-scan"
Write-Host "Listeners/watchdog/updater: sin cambios"
