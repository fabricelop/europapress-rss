# Install-TT-RestartSafe.ps1
# Instalacion unificada para TTiTTulares + TTendencias resistente a reinicios/caidas.
$InstallerVersion="restart-safe-v6-raw-bootstrap"
$ErrorActionPreference="Stop"
$BaseDir="C:\TTiTTulares"
$Startup=[Environment]::GetFolderPath("Startup")
New-Item -ItemType Directory -Path $BaseDir -Force|Out-Null

$files=@(
  @{Remote="windows/TTiTTularesDedicatedListener.ps1";Local="TTiTTularesDedicatedListener.ps1";Kind="ps"},
  @{Remote="windows/TTendenciasDedicatedListener.ps1";Local="TTendenciasDedicatedListener.ps1";Kind="ps"},
  @{Remote="windows/TTiTTularesImageBridge.js";Local="TTiTTularesImageBridge.js";Kind="js"},
  @{Remote="windows/TTendenciasImageBridge.js";Local="TTendenciasImageBridge.js";Kind="js"},
  @{Remote="windows/TT-AutoUpdater.ps1";Local="TT-AutoUpdater.ps1";Kind="ps"},
  @{Remote="windows/TT-LocalWatchdog.ps1";Local="TT-LocalWatchdog.ps1";Kind="ps"}
)

function Raw([string]$path){
  $url="https://raw.githubusercontent.com/fabricelop/europapress-rss/main/"+$path+"?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $wc=New-Object System.Net.WebClient
  try{
    $wc.Headers["User-Agent"]="TT-restart-safe-installer-v6"
    $wc.Headers["Cache-Control"]="no-cache"
    $b=$wc.DownloadData($url)
  }finally{$wc.Dispose()}
  if(-not $b -or $b.Length -lt 100){throw "RAW vacio/corto: $path"}
  return $b
}
function ValidatePs([string]$f){
  $t=$null;$e=$null
  [Management.Automation.Language.Parser]::ParseFile($f,[ref]$t,[ref]$e)|Out-Null
  if($e.Count -gt 0){throw "PowerShell invalido $f :: "+$e[0].Message}
}
function ValidateJs([string]$f){
  $node=Get-Command node.exe -ErrorAction SilentlyContinue
  if(-not $node){$node=Get-Command node -ErrorAction SilentlyContinue}
  if(-not $node){throw "Node no disponible"}
  $src=Get-Content -LiteralPath $f -Raw -Encoding UTF8
  $oldPref=$ErrorActionPreference
  try{
    $ErrorActionPreference="Continue"
    $src | & $node.Source --check - 1>$null 2>$null
    $code=$LASTEXITCODE
  }finally{
    $ErrorActionPreference=$oldPref
  }
  if($code -ne 0){throw "JS invalido: $f"}
}
foreach($f in $files){
  $dest=Join-Path $BaseDir $f.Local
  $tmp=$dest+$(if($f.Kind -eq "js"){".restartsafe.new.js"}else{".restartsafe.new.ps1"})
  [IO.File]::WriteAllBytes($tmp,(Raw $f.Remote))
  if($f.Kind -eq "ps"){ValidatePs $tmp}else{ValidateJs $tmp}
  Move-Item -LiteralPath $tmp -Destination $dest -Force
}

if(-not (Test-Path (Join-Path $BaseDir "Ejecutar.js"))){throw "Falta C:\TTiTTulares\Ejecutar.js"}
if(-not (Test-Path (Join-Path $BaseDir "LanzarOculto.vbs"))){throw "Falta C:\TTiTTulares\LanzarOculto.vbs"}

$startupMap=@{
 "TTiTTulares Mobile Trigger Listener.cmd"="TTiTTularesDedicatedListener.ps1"
 "TTendencias Mobile Trigger Listener.cmd"="TTendenciasDedicatedListener.ps1"
 "TT Auto Updater.cmd"="TT-AutoUpdater.ps1"
 "TT Automation Watchdog.cmd"="TT-LocalWatchdog.ps1"
}
foreach($name in $startupMap.Keys){
  $script=Join-Path $BaseDir $startupMap[$name]
  $content='@echo off'+[Environment]::NewLine+'start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$script+'"'
  Set-Content -LiteralPath (Join-Path $Startup $name) -Value $content -Encoding ASCII
}

$patterns=@(
 "*TTiTTularesDedicatedListener.ps1*",
 "*TTendenciasDedicatedListener.ps1*",
 "*TT-AutoUpdater.ps1*",
 "*TT-LocalWatchdog.ps1*"
)
foreach($pat in $patterns){
 @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{
   ($_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe") -and $_.CommandLine -like $pat
 })|ForEach-Object{try{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}catch{}}
}
Start-Sleep -Milliseconds 800

function StartPs([string]$name,[string]$tag){
 $script=Join-Path $BaseDir $name
 $out=Join-Path $BaseDir ($tag+"-restartsafe.out.log")
 $err=Join-Path $BaseDir ($tag+"-restartsafe.err.log")
 $p=Start-Process powershell.exe -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$script) -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
 Start-Sleep -Milliseconds 900
 $p.Refresh()
 if($p.HasExited){if(Test-Path $err){Get-Content $err -Tail 30};throw "$tag no quedo activo"}
 return $p
}
$up=StartPs "TT-AutoUpdater.ps1" "tt-auto-updater"
$tt=StartPs "TTiTTularesDedicatedListener.ps1" "ttittulares-listener"
$tr=StartPs "TTendenciasDedicatedListener.ps1" "ttendencias-listener"
$wd=StartPs "TT-LocalWatchdog.ps1" "tt-watchdog"

foreach($taskName in @(
 "TT Chrome Auto","TTiTTulares Local","TTendencias Local",
 "SeLoRecordamos-Telegram","SeLoRecordamos-Search","SeLoRecordamos-Published","SeLoRecordamos-Watchdog"
)){
 try{
   $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
   if($task -and $task.State -eq "Disabled"){Enable-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue|Out-Null}
 }catch{}
}
try{& schtasks.exe /Run /TN "TT Chrome Auto" 1>$null 2>$null}catch{}
try{
 $slr=Get-ScheduledTask -TaskName "SeLoRecordamos-Telegram" -ErrorAction SilentlyContinue
 if($slr -and $slr.State -ne "Running"){Start-ScheduledTask -TaskName "SeLoRecordamos-Telegram" -ErrorAction SilentlyContinue}
}catch{}
try{
 $slrWd=Get-ScheduledTask -TaskName "SeLoRecordamos-Watchdog" -ErrorAction SilentlyContinue
 if($slrWd){Start-ScheduledTask -TaskName "SeLoRecordamos-Watchdog" -ErrorAction SilentlyContinue}
}catch{}
Start-Sleep -Seconds 4

function CountProc([string]$pat){
 @((Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)|Where-Object{
  ($_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe") -and $_.CommandLine -like $pat
 }).Count
}
$checks=[ordered]@{
 TTiTTularesListener=(CountProc "*TTiTTularesDedicatedListener.ps1*")
 TTendenciasListener=(CountProc "*TTendenciasDedicatedListener.ps1*")
 AutoUpdater=(CountProc "*TT-AutoUpdater.ps1*")
 Watchdog=(CountProc "*TT-LocalWatchdog.ps1*")
}
$cdp=$false
try{$v=Invoke-RestMethod -Uri "http://127.0.0.1:9223/json/version" -TimeoutSec 4;$cdp=[bool]$v.webSocketDebuggerUrl}catch{}

Write-Host ("TT RESTART-SAFE ACTIVO · "+$InstallerVersion) -ForegroundColor Green
$checks.GetEnumerator()|ForEach-Object{Write-Host ($_.Key+": "+$_.Value)}
Write-Host ("Chrome CDP: "+$cdp)
foreach($n in @("SeLoRecordamos-Telegram","SeLoRecordamos-Search","SeLoRecordamos-Published","SeLoRecordamos-Watchdog")){
 try{
   $t=Get-ScheduledTask -TaskName $n -ErrorAction Stop
   $i=Get-ScheduledTaskInfo -TaskName $n -ErrorAction Stop
   Write-Host ($n+": "+$t.State+" | LastResult="+$i.LastTaskResult)
 }catch{Write-Host ($n+": MISSING")}
}
Write-Host "Inicio automatico instalado para listeners, updater y watchdog."
Write-Host "El watchdog mantiene el PC despierto y relanza componentes caidos."
Write-Host "Tras reiniciar: basta con que exista una sesion de Windows iniciada." -ForegroundColor Green
