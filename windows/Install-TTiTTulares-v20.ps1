# Install-TTiTTulares-v20.ps1
# Actualiza SOLO TTiTTulares al listener v20 + bridge v24 de pestaña fija,
# y deja el auto-updater usando raw.githubusercontent.com (sin GitHub API).

$ErrorActionPreference="Stop"
$BaseDir="C:\TTiTTulares"
$Listener=Join-Path $BaseDir "TTiTTularesDedicatedListener.ps1"
$Bridge=Join-Path $BaseDir "TTiTTularesImageBridge.js"
$Updater=Join-Path $BaseDir "TT-AutoUpdater.ps1"
$Runner=Join-Path $BaseDir "Ejecutar.js"
$StartupDir=[Environment]::GetFolderPath("Startup")
$ListenerStartup=Join-Path $StartupDir "TTiTTulares Mobile Trigger Listener.cmd"
$UpdaterStartup=Join-Path $StartupDir "TT Auto Updater.cmd"

function Raw([string]$path){
  $url="https://raw.githubusercontent.com/fabricelop/europapress-rss/main/"+$path+"?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $wc=New-Object System.Net.WebClient
  try{
    $wc.Headers["User-Agent"]="TTiTTulares-v20-installer"
    $wc.Headers["Cache-Control"]="no-cache"
    $b=$wc.DownloadData($url)
    if(-not $b -or $b.Length -lt 100){throw "Descarga vacia/corta: $path"}
    return $b
  }finally{$wc.Dispose()}
}
function PutRaw([string]$path,[string]$dest){
  $tmp=$dest+".new"
  [IO.File]::WriteAllBytes($tmp,(Raw $path))
  Move-Item -LiteralPath $tmp -Destination $dest -Force
}
function ValidatePs([string]$f){
  $t=$null;$e=$null
  [Management.Automation.Language.Parser]::ParseFile($f,[ref]$t,[ref]$e)|Out-Null
  if($e.Count -gt 0){throw "PowerShell invalido: "+$e[0].Message}
}
function ValidateJs([string]$f){
  $node=Get-Command node.exe -ErrorAction SilentlyContinue
  if(-not $node){$node=Get-Command node -ErrorAction SilentlyContinue}
  if(-not $node){throw "Node no disponible"}
  & $node.Source --check $f 1>$null 2>$null
  if($LASTEXITCODE -ne 0){throw "JS invalido: $f"}
}
function Procs([string]$pattern){
  @(Get-CimInstance Win32_Process|Where-Object{
    ($_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe") -and $_.CommandLine -like $pattern
  })
}
function StopPattern([string]$pattern){
  Procs $pattern|ForEach-Object{try{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}catch{}}
}

New-Item -ItemType Directory -Path $BaseDir -Force|Out-Null
PutRaw "windows/TTiTTularesDedicatedListener.ps1" $Listener
PutRaw "windows/TTiTTularesImageBridge.js" $Bridge
PutRaw "windows/TT-AutoUpdater.ps1" $Updater

ValidatePs $Listener
ValidatePs $Updater
ValidateJs $Bridge

$lt=Get-Content -LiteralPath $Listener -Raw -Encoding UTF8
foreach($needle in @(
  '$WorkerId = "ttittulares-dedicated-v20"',
  'TTITTULARES_IMAGE_JOB_V4',
  'BRIDGE_MODE="capture-only-v27-submit-evidence"',
  'IMAGE FIXED TAB BRIDGE STARTED'
)){
  if(-not $lt.Contains($needle)){throw "Listener v20 sin garantia: $needle"}
}
$bt=Get-Content -LiteralPath $Bridge -Raw -Encoding UTF8
foreach($needle in @(
  'BRIDGE_MODE="capture-only-v27-submit-evidence"',
  'FIXED_TAB_STATE',
  'Target.createTarget',
  'openFreshDedicatedConversation',
  'ttittulares-image-bridge-v27-submit-evidence'
)){
  if(-not $bt.Contains($needle)){throw "Bridge v24 sin garantia: $needle"}
}
if(-not (Test-Path -LiteralPath $Runner)){throw "No existe C:\TTiTTulares\Ejecutar.js"}

# Inicio con Windows.
Set-Content -LiteralPath $ListenerStartup -Encoding ASCII -Value ('@echo off'+[Environment]::NewLine+'start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$Listener+'"')
Set-Content -LiteralPath $UpdaterStartup -Encoding ASCII -Value ('@echo off'+[Environment]::NewLine+'start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$Updater+'"')

# Parar solo listener TTiTTulares y updater; TTendencias queda intacto.
StopPattern "*TTiTTularesDedicatedListener.ps1*"
StopPattern "*TTiTTularesMobileChatTriggerListener.ps1*"
StopPattern "*TT-AutoUpdater.ps1*"
Start-Sleep -Milliseconds 700

$lo=Join-Path $BaseDir "ttittulares-dedicated-stdout.log"
$le=Join-Path $BaseDir "ttittulares-dedicated-stderr.log"
$uo=Join-Path $BaseDir "tt-auto-updater-stdout.log"
$ue=Join-Path $BaseDir "tt-auto-updater-stderr.log"
Remove-Item $lo,$le,$uo,$ue -Force -ErrorAction SilentlyContinue

$lp=Start-Process powershell.exe -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$Listener) -WindowStyle Hidden -RedirectStandardOutput $lo -RedirectStandardError $le -PassThru
$up=Start-Process powershell.exe -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$Updater) -WindowStyle Hidden -RedirectStandardOutput $uo -RedirectStandardError $ue -PassThru
Start-Sleep -Seconds 3
$lp.Refresh();$up.Refresh()
if($lp.HasExited){if(Test-Path $le){Get-Content $le -Tail 50};throw "Listener v20 no quedo activo"}
if($up.HasExited){if(Test-Path $ue){Get-Content $ue -Tail 50};throw "Auto-updater raw-v3 no quedo activo"}

$live=@(Procs "*TTiTTularesDedicatedListener.ps1*")
if($live.Count -ne 1){throw "Se esperaban 1 listener TTiTTulares; activos: "+($live.ProcessId -join ",")}

Write-Host "TTITTULARES V20 ACTIVO" -ForegroundColor Green
Write-Host ("Listener PID: "+$lp.Id)
Write-Host ("Updater PID: "+$up.Id)
Write-Host "Bridge: v27 pestaña fija + evidencia de envío + raster limpio" -ForegroundColor Green
Write-Host "Auto-updater: raw.githubusercontent.com, sin GitHub API" -ForegroundColor Green
Write-Host "TTendencias: NO MODIFICADO" -ForegroundColor Green
