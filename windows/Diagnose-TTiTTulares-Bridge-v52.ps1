# Diagnose-TTiTTulares-Bridge-v52.ps1
# Solo lectura. No mata, no reinicia, no modifica estado.
$ErrorActionPreference="Continue"
$Base="C:\TTiTTulares"
$State=Join-Path $Base "ttittulares-mobile-trigger-state.json"
$Lock=Join-Path $Base "ttittulares-image-bridge.lock.json"
$MainLog=Join-Path $Base "ttittulares-mobile-trigger.log"

function Section($t){Write-Host "";Write-Host ("=== "+$t+" ===") -ForegroundColor Cyan}

$cmd=""
$target=""
if(Test-Path $State){
  try{
    $s=Get-Content $State -Raw -Encoding UTF8|ConvertFrom-Json
    $cmd=[string](@($s.active_image_commands)|Select-Object -First 1)
    if($cmd -match '^tt-img-auto-(.+?)-r\d+-a\d+-\d+$'){$target=$Matches[1]}
  }catch{}
}
if(-not $target -and (Test-Path $MainLog)){
  try{
    $line=Get-Content $MainLog -Tail 200|Where-Object{$_ -match 'IMAGE BRIDGE STARTED pid=\d+ target=([^ ]+) command=([^ ]+)'}|Select-Object -Last 1
    if($line -match 'target=([^ ]+) command=([^ ]+)'){$target=$Matches[1];$cmd=$Matches[2]}
  }catch{}
}

Section "ACTIVE"
Write-Host ("command="+$cmd)
Write-Host ("target="+$target)
if(Test-Path $Lock){Get-Content $Lock -Raw}else{Write-Host "Lock: no existe"}

Section "NODE BRIDGES"
@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{
  $_.Name -ieq "node.exe" -and ([string]$_.CommandLine -like "*TTiTTularesImageBridge.js*" -or [string]$_.CommandLine -like "*TTendenciasImageBridge.js*")
}|Select-Object ProcessId,CreationDate,CommandLine)|Format-List

Section "LATEST STDOUT"
if($target){
  $out=@(Get-ChildItem $Base -File -ErrorAction SilentlyContinue|Where-Object{
    $_.Name -like ("ttittulares-image-bridge-*"+$target+"*.log") -and $_.Name -notlike "*.err.log"
  }|Sort-Object LastWriteTime -Descending|Select-Object -First 1)
  if($out){
    Write-Host ("FILE="+$out.FullName+" modified="+$out.LastWriteTime)
    Get-Content $out.FullName -Tail 200
  }else{Write-Host "No stdout encontrado"}
}else{Write-Host "Target no determinado"}

Section "LATEST STDERR"
if($target){
  $err=@(Get-ChildItem $Base -File -ErrorAction SilentlyContinue|Where-Object{
    $_.Name -like ("ttittulares-image-bridge-*"+$target+"*.err.log")
  }|Sort-Object LastWriteTime -Descending|Select-Object -First 1)
  if($err){
    Write-Host ("FILE="+$err.FullName+" modified="+$err.LastWriteTime)
    Get-Content $err.FullName -Tail 200
  }else{Write-Host "No stderr encontrado"}
}

Section "LISTENER TAIL"
if(Test-Path $MainLog){Get-Content $MainLog -Tail 80}

Section "WATCHDOG TAIL"
$w=Join-Path $Base "tt-local-watchdog.log"
if(Test-Path $w){Get-Content $w -Tail 50}

Section "UPDATER TAIL"
$u=Join-Path $Base "tt-auto-updater.log"
if(Test-Path $u){Get-Content $u -Tail 50}

Section "END"
Write-Host "SOLO LECTURA COMPLETADO"
