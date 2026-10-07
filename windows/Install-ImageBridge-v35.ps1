# Install-ImageBridge-v35.ps1
# Hotfix minimo: sustituye SOLO los bridges de imagen por v35.
# No toca listeners, watchdog, updater, Ejecutar.js ni logica editorial.

$ErrorActionPreference="Stop"
$BaseDir="C:\TTiTTulares"
$SourceRef="6c73e4dd67acc2d0e45a83085f25a6b4e0021297"

function Get-PinnedFile([string]$RepoPath,[string]$OutFile){
  $url="https://raw.githubusercontent.com/fabricelop/europapress-rss/"+$SourceRef+"/"+$RepoPath+"?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  Invoke-WebRequest -Uri $url -OutFile $OutFile -UseBasicParsing -Headers @{
    "User-Agent"="TT-image-v35-hotfix"
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
  if(-not $txt.Contains($Needle)){throw "El bridge descargado no es v35: $File"}
  if(-not $txt.Contains('generation-started')){throw "Falta prueba de transicion generating en $File"}
}

New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null

$tt=Join-Path $BaseDir "TTiTTularesImageBridge.js"
$tr=Join-Path $BaseDir "TTendenciasImageBridge.js"
$ttTmp=Join-Path $BaseDir "TTiTTularesImageBridge.v35.new.js"
$trTmp=Join-Path $BaseDir "TTendenciasImageBridge.v35.new.js"

Get-PinnedFile "windows/TTiTTularesImageBridge.js" $ttTmp
Get-PinnedFile "windows/TTendenciasImageBridge.js" $trTmp
Validate-Node $ttTmp "ttittulares-image-bridge-v35-generating-proof"
Validate-Node $trTmp "ttendencias-image-bridge-v35-generating-proof"

# Detener solo bridges antiguos; no tocar listeners.
@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
  ($_.Name -ieq "node.exe" -or $_.Name -ieq "node") -and
  ($_.CommandLine -like "*TTiTTularesImageBridge.js*" -or $_.CommandLine -like "*TTendenciasImageBridge.js*")
}) | ForEach-Object {
  try{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}catch{}
}
Start-Sleep -Milliseconds 500

Move-Item -LiteralPath $ttTmp -Destination $tt -Force
Move-Item -LiteralPath $trTmp -Destination $tr -Force

# Los locks pertenecian a procesos que acabamos de detener.
Remove-Item -LiteralPath (Join-Path $BaseDir "ttittulares-image-bridge.lock.json") -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $BaseDir "ttendencias-image-bridge.lock.json") -Force -ErrorAction SilentlyContinue

Write-Host "HOTFIX IMAGEN v35 INSTALADO" -ForegroundColor Green
Write-Host "TTiTTulares bridge: v35 generating-proof"
Write-Host "TTendencias bridge: v35 generating-proof"
Write-Host "Listeners/watchdog/updater: sin cambios"
