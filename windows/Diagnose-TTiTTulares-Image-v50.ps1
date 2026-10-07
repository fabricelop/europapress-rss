# Diagnose-TTiTTulares-Image-v50.ps1
# Solo lectura. No mata procesos, no borra locks, no reinicia Chrome ni listeners.
$ErrorActionPreference="Continue"
$Base="C:\TTiTTulares"
$Lock=Join-Path $Base "ttittulares-image-bridge.lock.json"
$State=Join-Path $Base "ttittulares-mobile-trigger-state.json"
$Tab=Join-Path $Base "ttittulares-image-tab.json"
$Fixed=Join-Path $Base "ttittulares-image-fixed-tab.json"

function Section($t){Write-Host "";Write-Host ("=== "+$t+" ===") -ForegroundColor Cyan}
function PsRows($pat){
  @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    [string]$_.CommandLine -like $pat
  } | Select-Object ProcessId,Name,CreationDate,CommandLine)
}

Section "LOCK"
$lockObj=$null
if(Test-Path $Lock){
  Get-Content $Lock -Raw
  try{$lockObj=Get-Content $Lock -Raw|ConvertFrom-Json}catch{}
}else{Write-Host "NO LOCK"}

Section "STATE ACTIVE"
if(Test-Path $State){
  try{
    $s=Get-Content $State -Raw|ConvertFrom-Json
    [pscustomobject]@{
      active_image_commands=(@($s.active_image_commands)-join ",")
      seen_count=@($s.image_commands).Count
      last_command_id=$s.last_command_id
    }|Format-List
  }catch{Write-Host $_.Exception.Message}
}

Section "BRIDGE PROCESS"
if($lockObj -and [int]$lockObj.pid -gt 0){
  $pidv=[int]$lockObj.pid
  Get-CimInstance Win32_Process -Filter ("ProcessId="+$pidv) -ErrorAction SilentlyContinue |
    Select-Object ProcessId,Name,CreationDate,CommandLine | Format-List
}else{Write-Host "Sin PID de lock"}

Section "BRIDGE STDOUT/STDERR"
if($lockObj){
  $tid=[string]$lockObj.target_id
  $outs=@(Get-ChildItem $Base -Filter ("ttittulares-image-bridge-*"+$tid+"*.log") -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
  $errs=@(Get-ChildItem $Base -Filter ("ttittulares-image-bridge-*"+$tid+"*.err.log") -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
  if($outs.Count){
    Write-Host ("STDOUT FILE: "+$outs[0].FullName+" modified="+$outs[0].LastWriteTime)
    Get-Content $outs[0].FullName -Tail 120
  }else{Write-Host "No stdout log encontrado"}
  if($errs.Count){
    Write-Host ("STDERR FILE: "+$errs[0].FullName+" modified="+$errs[0].LastWriteTime)
    Get-Content $errs[0].FullName -Tail 120
  }else{Write-Host "No stderr log encontrado"}
}

Section "FIXED TAB FILES"
foreach($p in @($Fixed,$Tab)){
  Write-Host ("-- "+$p)
  if(Test-Path $p){Get-Content $p -Raw}else{Write-Host "NO EXISTE"}
}

Section "CHROME 9223 JSON LIST"
try{
  $j=Invoke-RestMethod "http://127.0.0.1:9223/json/list" -TimeoutSec 5
  @($j)|Select-Object id,type,title,url,webSocketDebuggerUrl|Format-Table -AutoSize -Wrap
}catch{Write-Host ("CDP ERROR: "+$_.Exception.Message)}

Section "TTITTULARES LISTENERS"
PsRows "*TTiTTularesDedicatedListener.ps1*"|Format-List

Section "WATCHDOGS"
PsRows "*TT-LocalWatchdog.ps1*"|Format-List

Section "AUTO UPDATER"
PsRows "*TT-AutoUpdater.ps1*"|Format-List
$aul=Join-Path $Base "tt-auto-updater.log"
if(Test-Path $aul){Write-Host "-- tail updater";Get-Content $aul -Tail 40}

Section "WATCHDOG LOG"
$wl=Join-Path $Base "tt-local-watchdog.log"
if(Test-Path $wl){Get-Content $wl -Tail 60}

Section "REMOTE CURRENT JOB"
if($lockObj -and $lockObj.target_id){
  try{
    $u="https://europapress-rss.vercel.app/api/ttittulares-run-status?view=image-job&strong=1&id="+[uri]::EscapeDataString([string]$lockObj.target_id)+"&t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Invoke-RestMethod $u -TimeoutSec 15 | ConvertTo-Json -Depth 8
  }catch{Write-Host ("REMOTE ERROR: "+$_.Exception.Message)}
}

Section "END"
Write-Host "DIAGNOSTICO SOLO LECTURA COMPLETADO"
