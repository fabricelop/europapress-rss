# Install-TTiTTulares-Listener-v50.ps1
# Reparación mínima: slot active huérfano + instancia única TTiTTulares.
# Actualiza listener TTiTTulares y watchdog; NO toca TTendencias, Chrome 9223 ni bridges.

$ErrorActionPreference="Stop"
$BaseDir="C:\TTiTTulares"
$SourceRef="01bd8d224efd74f005e89a11548877bafa45aafa"
$Listener=Join-Path $BaseDir "TTiTTularesDedicatedListener.ps1"
$Watchdog=Join-Path $BaseDir "TT-LocalWatchdog.ps1"
$State=Join-Path $BaseDir "ttittulares-mobile-trigger-state.json"
$Lock=Join-Path $BaseDir "ttittulares-image-bridge.lock.json"
$Log=Join-Path $BaseDir "ttittulares-mobile-trigger.log"
$TmpListener=Join-Path $BaseDir "TTiTTularesDedicatedListener.v50.new.ps1"
$TmpWatchdog=Join-Path $BaseDir "TT-LocalWatchdog.v8.new.ps1"

function Get-TTListeners {
  @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    ($_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe") -and
    [string]$_.CommandLine -like "*TTiTTularesDedicatedListener.ps1*"
  })
}
function Get-Watchdogs {
  @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    ($_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe") -and
    [string]$_.CommandLine -like "*TT-LocalWatchdog.ps1*"
  })
}
function Show-LocalImageState([string]$Label){
  Write-Host ""
  Write-Host ("--- "+$Label+" ---") -ForegroundColor Cyan
  $ls=@(Get-TTListeners)
  if($ls.Count){
    Write-Host ("Listeners: "+(($ls|ForEach-Object{[string]$_.ProcessId}) -join ", "))
  }else{Write-Host "Listeners: ninguno"}
  if(Test-Path -LiteralPath $State){
    try{
      $s=Get-Content -LiteralPath $State -Raw -Encoding UTF8 | ConvertFrom-Json
      Write-Host ("active_image_commands: "+((@($s.active_image_commands)|ForEach-Object{[string]$_}) -join ", "))
      Write-Host ("seen_count: "+@($s.image_commands).Count)
    }catch{Write-Host ("State ERROR: "+$_.Exception.Message)}
  }else{Write-Host "State: no existe"}
  if(Test-Path -LiteralPath $Lock){
    try{
      $l=Get-Content -LiteralPath $Lock -Raw -Encoding UTF8 | ConvertFrom-Json
      $pidValue=[int]$l.pid
      $proc=if($pidValue -gt 0){Get-CimInstance Win32_Process -Filter ("ProcessId="+$pidValue) -ErrorAction SilentlyContinue}else{$null}
      $isBridge=($proc -and [string]$proc.CommandLine -like "*TTiTTularesImageBridge.js*")
      Write-Host ("Lock: command="+[string]$l.command_id+" target="+[string]$l.target_id+" pid="+$pidValue+" live_bridge="+[int][bool]$isBridge+" started_at="+[string]$l.started_at)
    }catch{Write-Host ("Lock ERROR: "+$_.Exception.Message)}
  }else{Write-Host "Lock: no existe"}
}

New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
Show-LocalImageState "ANTES"

$headers=@{
  "User-Agent"="TTiTTulares-v50-installer"
  "Cache-Control"="no-cache, no-store"
  "Pragma"="no-cache"
}
Invoke-WebRequest -Uri ("https://raw.githubusercontent.com/fabricelop/europapress-rss/"+$SourceRef+"/windows/TTiTTularesDedicatedListener.ps1?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -OutFile $TmpListener -UseBasicParsing -Headers $headers -TimeoutSec 30
Invoke-WebRequest -Uri ("https://raw.githubusercontent.com/fabricelop/europapress-rss/"+$SourceRef+"/windows/TT-LocalWatchdog.ps1?t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -OutFile $TmpWatchdog -UseBasicParsing -Headers $headers -TimeoutSec 30

$listenerTxt=Get-Content -LiteralPath $TmpListener -Raw -Encoding UTF8
$watchdogTxt=Get-Content -LiteralPath $TmpWatchdog -Raw -Encoding UTF8
if(-not $listenerTxt.Contains('$WorkerId = "ttittulares-dedicated-v50"')){throw "Listener remoto no es v50"}
if(-not $listenerTxt.Contains('IMAGE ACTIVE ORPHAN CLEARED')){throw "Falta reconciliación de active huérfano"}
if(-not $listenerTxt.Contains('BRIDGE_MODE="capture-only-v28-dead-submit-retry"')){throw "Bridge family esperada no preservada en listener"}
if(-not $watchdogTxt.Contains('watchdog-restart-refresh-v8-ttittulares-no-queue-restart')){throw "Watchdog remoto no es v8"}

foreach($f in @($TmpListener,$TmpWatchdog)){
  $tokens=$null;$errors=$null
  [Management.Automation.Language.Parser]::ParseFile($f,[ref]$tokens,[ref]$errors)|Out-Null
  if($errors.Count -gt 0){throw ("PowerShell invalido en "+$f+": "+(($errors|ForEach-Object{$_.Message}) -join " | "))}
}

# Parar todas las instancias del listener TTiTTulares. No tocar bridges.
@(Get-TTListeners)|ForEach-Object{try{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}catch{}}
Start-Sleep -Milliseconds 700
Move-Item -LiteralPath $TmpListener -Destination $Listener -Force

# Sustituir y reiniciar SOLO el watchdog para impedir nuevos queue-restarts de TTiTTulares.
@(Get-Watchdogs)|ForEach-Object{try{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}catch{}}
Start-Sleep -Milliseconds 500
Move-Item -LiteralPath $TmpWatchdog -Destination $Watchdog -Force

$ps=Get-Command powershell.exe -ErrorAction SilentlyContinue
if(-not $ps){throw "No encuentro powershell.exe"}

$lp=Start-Process -FilePath $ps.Source -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File",$Listener) -WindowStyle Hidden -PassThru
Start-Sleep -Seconds 2
$lp.Refresh()
if($lp.HasExited){throw "Listener v50 termino al arrancar. ExitCode=$($lp.ExitCode)"}

$wp=Start-Process -FilePath $ps.Source -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File",$Watchdog) -WindowStyle Hidden -PassThru
Start-Sleep -Seconds 2
$wp.Refresh()
if($wp.HasExited){throw "Watchdog v8 termino al arrancar. ExitCode=$($wp.ExitCode)"}

# Cierre de carrera: garantizar una sola instancia del listener, conservando la recién lanzada si sigue viva.
$ls=@(Get-TTListeners)
if($ls.Count -gt 1){
  foreach($x in $ls){
    if($x.ProcessId -ne $lp.Id){try{Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue}catch{}}
  }
}
Start-Sleep -Seconds 8

Write-Host ""
Write-Host "TTITTULARES LISTENER v50 INSTALADO" -ForegroundColor Green
Write-Host ("PID listener esperado: "+$lp.Id)
Write-Host ("PID watchdog v8: "+$wp.Id)
Write-Host "TTendencias/Chrome 9223/bridges: sin cambios"
Show-LocalImageState "DESPUES"

Write-Host ""
Write-Host "Ultimas lineas TTiTTulares:"
if(Test-Path -LiteralPath $Log){Get-Content -LiteralPath $Log -Tail 30}
